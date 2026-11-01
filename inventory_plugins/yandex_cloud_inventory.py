from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.errors import AnsibleError, AnsibleParserError
from ansible.utils.display import Display

import os
import json
from yandexcloud import SDK
from yandex.cloud.compute.v1.instance_service_pb2 import ListInstancesRequest
from yandex.cloud.compute.v1.instance_service_pb2_grpc import InstanceServiceStub


DOCUMENTATION = r'''
    name: yandex_cloud_inventory
    plugin_type: inventory
    short_description: Yandex.Cloud dynamic inventory using service account key or IAM token
    description:
        - Fetches hosts from Yandex.Cloud Compute using a service account JSON key file or an existing IAM token.
        - Hosts are grouped by availability zone (dashes replaced with underscores) and by the C(ansible_group) label; the I(group) option adds every host to one more group.
        - Host variables are C(ansible_host) (public IPv4 address if the VM has one, otherwise the internal one), C(ipv4) (public IPv4 address or null), C(private_ipv4) (internal IPv4 address) and C(yc_name) (VM name in Yandex.Cloud).
        - Every VM label becomes the host variable C(yc_label_<key>); dashes in the key are replaced with underscores, values are kept as is. Labels never override the service variables above.
        - The only labels applied as service variables as well are C(ansible_user) and C(ansible_port). Any other C(ansible_*) label is kept as C(yc_label_<key>) and reported with a warning, because labels are writable by anyone who can edit the folder and could otherwise inject connection settings (for example C(ansible_ssh_common_args) with a C(ProxyCommand) executed on the controller).
        - Two labels are directives rather than variables. C(ansible) with the value C(false) (case-insensitive) removes the VM from the inventory, C(ansible_group) adds the VM to the named group.
    options:
        plugin:
            description: Name of this plugin
            required: true
            choices: ['yandex_cloud_inventory']
        service_account_key_file:
            description: Path to the service account JSON key file. Takes priority over I(iam_token).
            required: false
            type: str
        iam_token:
            description:
                - IAM token for authentication.
                - Used only when I(service_account_key_file) is not set, the service account key has priority. If neither is set, the token is read from the C(YC_IAM_TOKEN) environment variable.
            required: false
            type: str
        folder_id:
            description: Yandex.Cloud folder ID
            required: true
            type: str
        group:
            description: Group name to add all hosts to
            required: false
            type: str
'''

display = Display()

# local patch: метки ВМ — недоверенный ввод: их может поставить любой, у кого есть
# доступ к каталогу. Писать их в переменные хоста «как есть» нельзя — метка
# ansible_host подменяет адрес подключения, а ansible_ssh_common_args с
# ProxyCommand выполнит команду на контроллере. Поэтому все метки уходят под
# префикс yc_label_, а служебными переменными становятся только эти ключи.
ALLOWED_ANSIBLE_LABELS = frozenset({'ansible_user', 'ansible_port'})


class InventoryModule(BaseInventoryPlugin):
    NAME = 'yandex_cloud_inventory'

    # local patch: плагин объявляет своим только файл вида yc_inventory.yml или
    # <что-то>_yc_inventory.yml (и .yaml). В upstream здесь был
    # `path.endswith(('yml', 'yaml'))`, из-за чего плагин забирал себе ЛЮБОЙ
    # yaml-inventory и падал на нём с "Incorrect plugin name".
    # Разделитель `_` обязателен: без него перехватывался `myyc_inventory.yml`.
    def verify_file(self, path):
        if not super().verify_file(path):
            return False
        name = os.path.basename(path)
        return any(
            name == f'yc_inventory.{ext}' or name.endswith(f'_yc_inventory.{ext}')
            for ext in ('yml', 'yaml')
        )

    def parse(self, inventory, loader, path, cache=True):
        super().parse(inventory, loader, path)
        self._read_config_data(path)

        sa_key_file = self.get_option('service_account_key_file')
        iam_token = self.get_option('iam_token')
        folder_id = self.get_option('folder_id')
        group = self.get_option('group')

        # Проверяем входные параметры
        if not folder_id:
            raise AnsibleParserError("Option 'folder_id' is required")

        # Проверяем наличие файла сервисного аккаунта
        if sa_key_file and not os.path.isfile(sa_key_file):
            raise AnsibleError(f"Service account key file not found: {sa_key_file}")

        # Если нет IAM токена в конфигурации, берем из переменной окружения
        if not iam_token:
            iam_token = os.getenv('YC_IAM_TOKEN')

        # Проверяем, что есть хотя бы один способ аутентификации
        if not sa_key_file and not iam_token:
            raise AnsibleParserError("Either 'service_account_key_file', 'iam_token', or 'YC_IAM_TOKEN' environment variable must be provided")

        # Инициализируем SDK с приоритетом: service_account_key_file > iam_token
        try:
            if sa_key_file:
                # Приоритет 1: Сервисный аккаунт
                with open(sa_key_file, 'r') as infile:
                    sa_key = json.load(infile)
                sdk = SDK(service_account_key=sa_key)
            elif iam_token:
                # Приоритет 2: IAM токен
                sdk = SDK(iam_token=iam_token)
            else:
                raise AnsibleError("No authentication method provided")

            instance_client = sdk.client(InstanceServiceStub)
        except Exception as e:
            raise AnsibleError(f"Failed to initialize Yandex SDK: {e}")

        # local patch: в upstream запрашивалась только первая страница (по умолчанию
        # 100 ВМ), остальные молча терялись. Теперь идём по next_page_token.
        instances = []
        page_token = None
        while True:
            response = instance_client.List(
                ListInstancesRequest(folder_id=folder_id, page_size=1000, page_token=page_token)
            )
            instances.extend(response.instances)
            page_token = getattr(response, 'next_page_token', None)
            if not page_token:
                break

        # Создаем основную группу, если указана
        if group:
            self.inventory.add_group(group)

        # local patch: имя хоста — это имя ВМ с заменой дефисов; `web-1` и `web_1`
        # давали один хост, и одна из ВМ молча пропадала. Теперь предупреждаем.
        host_sources = {}

        for instance in instances:
            # local patch: ВМ без сетевых интерфейсов роняла плагин с
            # IndexError, а Ansible после этого молча отдавал пустой inventory.
            if not instance.network_interfaces:
                display.warning(
                    f"yandex_cloud_inventory: у ВМ '{instance.name}' нет сетевых "
                    f"интерфейсов, пропускаю"
                )
                continue

            primary_v4 = instance.network_interfaces[0].primary_v4_address

            # local patch: интерфейс без IPv4-адреса ронял плагин на
            # `primary_v4.one_to_one_nat` с AttributeError (upstream), а первая
            # версия фикса добавляла хост с ansible_host == "" — потому что
            # проверяла `is None`. Реальный protobuf для незаполненного поля
            # возвращает не None, а пустое сообщение с address == ""
            # (проверено на yandexcloud 0.412.0), поэтому проверяем значение:
            # это покрывает и None (заглушки, старые SDK), и пустую строку.
            internal_ip = getattr(primary_v4, 'address', None) or None
            if internal_ip is None:
                display.warning(
                    f"yandex_cloud_inventory: у ВМ '{instance.name}' на первом "
                    f"интерфейсе нет IPv4-адреса, пропускаю"
                )
                continue

            # Пустой address у NAT означает «публичного адреса нет»: нормализуем
            # в None, чтобы ipv4 был null, а не "", как обещает документация.
            external_ip = getattr(primary_v4.one_to_one_nat, 'address', None) or None

            # Директивы читаем из сырых меток: это настройки плагина, а не
            # переменные хоста, поэтому нормализация ключей их не касается.
            raw_labels = instance.labels

            # Фильтрация: если label ansible == false (local patch: без учёта регистра)
            if str(raw_labels.get('ansible', '')).lower() == 'false':
                continue

            host_name = instance.name.replace("-", "_")
            zone = instance.zone_id.replace("-", "_")

            if host_name in host_sources:
                display.warning(
                    f"yandex_cloud_inventory: у ВМ '{host_sources[host_name]}' и "
                    f"'{instance.name}' совпадает имя хоста '{host_name}', "
                    f"в inventory останется последняя"
                )
            host_sources[host_name] = instance.name

            # local patch: в upstream значения меток тоже портились (web-app -> web_app),
            # что незаметно меняло данные. Чистим только ключи: они становятся именами
            # переменных, а значения переменных можно оставить как есть.
            labels = {}
            label_sources = {}
            for key, value in raw_labels.items():
                normalized = key.replace("-", "_")
                # local patch: `a-b` и `a_b` дают одну переменную — вторая молча
                # затирала первую, теперь об этом предупреждаем.
                if normalized in labels:
                    display.warning(
                        f"yandex_cloud_inventory: у ВМ '{instance.name}' метки "
                        f"'{label_sources[normalized]}' и '{key}' дают одну "
                        f"переменную '{normalized}', значение '{key}' затирает "
                        f"предыдущее"
                    )
                labels[normalized] = value
                label_sources[normalized] = key

            # local patch: в upstream предпочитался внутренний IP, из-за чего
            # запуск с машины вне облака не подключался к ВМ. Публичный адрес —
            # рабочий по умолчанию, внутренний остаётся в private_ipv4.
            # Пустых значений здесь уже нет: отсутствие внутреннего адреса
            # отсеяно выше, значит ansible_ip всегда непустой.
            ansible_ip = external_ip if external_ip else internal_ip

            # Добавляем хост. local patch: если имя уже занято другой ВМ, прежний
            # хост снимаем целиком (remove_host убирает его из всех групп), иначе
            # он остаётся в группе зоны предыдущей ВМ — хост «жил» сразу в двух
            # зонах. Снимаем только перед реальным добавлением: ВМ, пропущенная
            # выше по continue, не должна стирать уже добавленный хост.
            if self.inventory.get_host(host_name):
                self.inventory.remove_host(self.inventory.get_host(host_name))
            self.inventory.add_host(host_name)

            # Служебные переменные. Переопределить их метками нельзя по
            # построению: все метки пишутся с префиксом yc_label_ (цикл ниже),
            # поэтому порядок установки переменных роли не играет.
            self.inventory.set_variable(host_name, 'ansible_host', ansible_ip)
            # local patch: имя `name` — зарезервированное, Ansible на него ругался
            # предупреждением "Found variable using reserved name 'name'".
            self.inventory.set_variable(host_name, 'yc_name', instance.name)
            self.inventory.set_variable(host_name, 'ipv4', external_ip)
            self.inventory.set_variable(host_name, 'private_ipv4', internal_ip)

            # local patch: метки — недоверенные данные, поэтому «как есть» они не
            # применяются. Под безопасным префиксом данные сохраняются целиком.
            for key, value in labels.items():
                self.inventory.set_variable(host_name, f'yc_label_{key}', value)
                if key in ALLOWED_ANSIBLE_LABELS:
                    self.inventory.set_variable(host_name, key, value)
                elif key.startswith('ansible_') and key != 'ansible_group':
                    display.warning(
                        f"yandex_cloud_inventory: у ВМ '{instance.name}' метка "
                        f"'{key}' не применяется как служебная переменная "
                        f"(осталась как yc_label_{key})"
                    )

            # Добавляем в группы
            self.inventory.add_group(zone)
            self.inventory.add_host(host_name, group=zone)

            group_name = raw_labels.get('ansible_group')
            if group_name:
                self.inventory.add_group(group_name)
                self.inventory.add_host(host_name, group=group_name)

            # Добавляем в основную группу, если указана
            if group:
                self.inventory.add_host(host_name, group=group)
