from ansible.plugins.inventory import BaseInventoryPlugin
from ansible.errors import AnsibleError, AnsibleParserError
from ansible.utils.display import Display

import os
import re
import json
from yandexcloud import SDK
from yandex.cloud.compute.v1.instance_service_pb2 import ListInstancesRequest
from yandex.cloud.compute.v1.instance_service_pb2_grpc import InstanceServiceStub


DOCUMENTATION = r'''
    name: yandex_cloud_inventory
    short_description: Yandex.Cloud dynamic inventory using service account key or IAM token
    author:
        - Maksim Zatolokin (upstream)
        - morgenvor (fork)
    description:
        - Fetches hosts from Yandex.Cloud Compute using a service account JSON key file or an existing IAM token.
        - The host name is the VM name exactly as it is in Yandex.Cloud, dashes included; Ansible accepts them in host names and warns only about group names.
        - Hosts are grouped by availability zone (dashes replaced with underscores, because Ansible warns about invalid characters in group names) and by the C(ansible_group) label, which creates C(yc_<value>) with dashes replaced with underscores; the I(group) option adds every host to one more group and is used as is.
        - The C(yc_) prefix is mandatory and cannot be disabled. A label is writable by anyone who can edit the folder, and without the prefix it could put a VM into a group that has its own C(group_vars) (with secrets or C(ansible_connection)) or into a path like C(group_vars/../../outside). If the value already starts with C(yc_), the result is C(yc_yc_<value>) and a warning is shown. The rest of the name must match C(^[A-Za-z0-9][A-Za-z0-9_]*$) — an invalid value is reported with a warning and no group is created, while the host stays in the inventory. The raw value is still available as C(yc_label_ansible_group).
        - Host variables are C(ansible_host) (public IPv4 address if the VM has one, otherwise the internal one), C(ipv4) (public IPv4 address or null), C(private_ipv4) (internal IPv4 address) and C(yc_name) (VM name in Yandex.Cloud).
        - Every VM label becomes the host variable C(yc_label_<key>); dashes in the key are replaced with underscores, values are kept as is. Labels never override the service variables above.
        - The only labels applied as service variables as well are C(ansible_user) and C(ansible_port). Any other C(ansible_*) label is kept as C(yc_label_<key>) and reported with a warning, because labels are writable by anyone who can edit the folder and could otherwise inject connection settings (for example C(ansible_ssh_common_args) with a C(ProxyCommand) executed on the controller).
        - The values of the two allowed labels are validated — C(ansible_port) must be a number from 1 to 65535, C(ansible_user) must not be empty and must not contain spaces, quotes or backslashes (they are passed to C(ssh) as C(-o Port=...) and C(-o User="...")). An unusable value is reported with a warning, is not applied as a service variable, and stays available as C(yc_label_<key>).
        - Because C(ansible_user) is a host variable, it takes precedence over C(remote_user) in a play and over C(-u) on the command line, so set this label deliberately.
        - Two labels are directives rather than variables. C(ansible) with the value C(false) (case-insensitive) removes the VM from the inventory, C(ansible_group) adds the VM to the C(yc_<value>) group described above. Both are read after key normalization, so a label spelled C(ansible-group) works exactly like C(ansible_group).
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

# local patch: группа из метки ansible_group создаётся только в пространстве
# имён yc_<значение>. Причин две:
#   а) метка не должна вступать в группы, которыми управляет владелец
#      репозитория: Ansible применил бы к хосту их group_vars, а там бывают
#      секреты и ansible_connection: local (выполнение на контроллере);
#   б) имя группы уходит в путь group_vars/<имя>, а метки пишет любой, у кого
#      есть доступ к каталогу: свободные символы в имени (`../../outside/evil`,
#      `web.dev`) позволяют читать файлы за пределами group_vars, поэтому
#      после префикса разрешены только буквы, цифры и `_`.
LABEL_GROUP_PREFIX = 'yc_'
LABEL_GROUP_RE = re.compile(r'^yc_[A-Za-z0-9][A-Za-z0-9_]{0,62}$')


def _invalid_whitelist_reason(key, value):
    """Почему значение метки из белого списка нельзя применять.

    Пустая строка — значение пригодно. Проверяем именно значение: ключ попал в
    белый список потому, что не выполняет код на контроллере, но значение
    уходит в командную строку ssh (`-o Port=...`, `-o User="..."`), и мусор в
    нём даёт отказ подключения с непонятной причиной вместо понятного
    предупреждения от плагина.
    """
    text = str(value)
    if key == 'ansible_port':
        try:
            port = int(text.strip())
        except (TypeError, ValueError):
            return f"ожидается номер порта, получено {text!r}"
        if not 1 <= port <= 65535:
            return f"порт вне диапазона 1-65535: {text!r}"
        return ''
    if not text.strip():
        return "логин пустой"
    if any(ch.isspace() or ch in '"\'\\' for ch in text):
        return f"логин содержит пробел, кавычку или обратную косую черту: {text!r}"
    return ''


class InventoryModule(BaseInventoryPlugin):
    NAME = 'yandex_cloud_inventory'

    # local patch: плагин объявляет своим только файл вида yc_inventory.yml или
    # <непустой-префикс>_yc_inventory.yml (и .yaml). В upstream здесь был
    # `path.endswith(('yml', 'yaml'))`, из-за чего плагин забирал себе ЛЮБОЙ
    # yaml-inventory и падал на нём с "Incorrect plugin name".
    # Разделитель `_` обязателен: без него перехватывался `myyc_inventory.yml`.
    # Префикс перед `_` тоже обязателен: `_yc_inventory.yml` — это не «имя с
    # разделителем», а файл без имени, и забирать его плагин не должен.
    INVENTORY_FILE_RE = re.compile(r'^(?:[^/]+_)?yc_inventory\.(?:yml|yaml)$')

    def verify_file(self, path):
        if not super().verify_file(path):
            return False
        return bool(self.INVENTORY_FILE_RE.match(os.path.basename(path)))

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
            raise AnsibleParserError(f"Service account key file not found: {sa_key_file}")

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
            else:
                # Приоритет 2: IAM токен. Пустой токен сюда не доходит: выше
                # есть проверка, что способ аутентификации вообще задан.
                sdk = SDK(iam_token=iam_token)

            instance_client = sdk.client(InstanceServiceStub)
        except Exception as e:
            raise AnsibleError(f"Failed to initialize Yandex SDK: {e}")

        # local patch: в upstream запрашивалась только первая страница (по умолчанию
        # 100 ВМ), остальные молча терялись. Теперь идём по next_page_token.
        instances = []
        page_token = None
        while True:
            # local patch: отказ API показываем как ошибку плагина с подсказкой.
            # Раньше наружу летело исключение SDK, и Ansible печатал его текст
            # как есть: при истёкшем IAM-токене (живёт 12 часов) это
            # «Unauthenticated» без намёка на причину. Ansible после ошибки
            # разбора источника продолжает работу с пустым inventory, поэтому
            # внятное сообщение — единственный сигнал владельцу.
            try:
                response = instance_client.List(
                    ListInstancesRequest(folder_id=folder_id, page_size=1000, page_token=page_token)
                )
            except Exception as e:
                raise AnsibleError(
                    "yandex_cloud_inventory: не удалось получить список ВМ каталога "
                    f"'{folder_id}' — {e}. Проверьте права учётной записи (для чтения "
                    "достаточно роли viewer) и срок жизни IAM-токена (12 часов, "
                    "обновить: yc iam create-token)"
                )
            instances.extend(response.instances)
            next_token = getattr(response, 'next_page_token', None)
            # local patch: если API вернёт тот же токен, цикл был бы вечным —
            # inventory висел бы вместо ошибки.
            if not next_token or next_token == page_token:
                break
            page_token = next_token

        # Создаем основную группу, если указана
        if group:
            self.inventory.add_group(group)

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

            # local patch: в upstream значения меток тоже портились (web-app -> web_app),
            # что незаметно меняло данные. Чистим только ключи: они становятся именами
            # переменных, а значения переменных можно оставить как есть.
            raw_labels = instance.labels
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

            # local patch: директивы читаем из нормализованных ключей, как и всё
            # остальное. Раньше они брались из сырых, и метка `ansible-group: docker`
            # давала переменную `yc_label_ansible_group`, но группы `yc_docker` не
            # создавала и предупреждения не печатала — то есть вела себя иначе,
            # чем её же нормализованное имя. Нормализация ключа и чтение директивы
            # должны совпадать, иначе одно и то же имя метки работает по-разному
            # в зависимости от того, как его записали.

            # Фильтрация: если label ansible == false (local patch: без учёта регистра)
            if str(labels.get('ansible', '')).lower() == 'false':
                continue

            # local patch: имя хоста — это имя ВМ как есть, дефисы сохраняются.
            # Ansible дефис в имени хоста принимает (предупреждает он только про
            # имена групп), а имена ВМ в каталоге уникальны. Раньше здесь стояла
            # замена `-` на `_`: `web-1` и `web_1` давали один хост, одна из ВМ
            # молча пропадала, а `ansible web-1` не находил хост.
            host_name = instance.name
            # Зону нормализуем намеренно: Ansible предупреждает о недопустимых
            # символах в имени группы, а `force_valid_group_names` по умолчанию
            # `never` — значит, без замены поведение зависело бы от чужого
            # ansible.cfg и каждый запуск сыпал бы предупреждением.
            zone = instance.zone_id.replace("-", "_")

            # local patch: в upstream предпочитался внутренний IP, из-за чего
            # запуск с машины вне облака не подключался к ВМ. Публичный адрес —
            # рабочий по умолчанию, внутренний остаётся в private_ipv4.
            # Пустых значений здесь уже нет: отсутствие внутреннего адреса
            # отсеяно выше, значит ansible_ip всегда непустой.
            ansible_ip = external_ip if external_ip else internal_ip

            # Имена ВМ в каталоге уникальны, поэтому совпадение имени хоста
            # означает дубль в ответе API, а не коллизию после нормализации.
            # Молчаливой перезаписи быть не должно — предупреждаем.
            if self.inventory.get_host(host_name):
                display.warning(
                    f"yandex_cloud_inventory: хост '{host_name}' уже добавлен "
                    f"другой ВМ, переменные перезаписаны"
                )
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
                if key not in ALLOWED_ANSIBLE_LABELS:
                    if key.startswith('ansible_') and key != 'ansible_group':
                        display.warning(
                            f"yandex_cloud_inventory: у ВМ '{instance.name}' метка "
                            f"'{key}' не применяется как служебная переменная "
                            f"(осталась как yc_label_{key})"
                        )
                    continue
                # local patch: белый список — это две переменные, которые не
                # выполняют код на контроллере, но значение у них тоже
                # недоверенное. Порт из метки «not-a-port» доезжал до ssh как
                # `Port=not-a-port` и давал непонятный отказ подключения, а логин
                # с пробелом или кавычкой ломал разбор `-o User="..."` в
                # ansible-core. Такое значение отбрасываем с предупреждением,
                # сырая метка остаётся в yc_label_*.
                reason = _invalid_whitelist_reason(key, value)
                if reason:
                    display.warning(
                        f"yandex_cloud_inventory: у ВМ '{instance.name}' метка "
                        f"'{key}' со значением '{value}' не применена как "
                        f"служебная переменная: {reason} "
                        f"(осталась как yc_label_{key})"
                    )
                    continue
                if key == 'ansible_port':
                    self.inventory.set_variable(host_name, key, int(str(value).strip()))
                else:
                    self.inventory.set_variable(host_name, key, value)

            # Добавляем в группы
            self.inventory.add_group(zone)
            self.inventory.add_host(host_name, group=zone)

            # local patch: группа из метки создаётся только как yc_<значение>.
            # Метка недоверенная, поэтому в группы владельца репозитория
            # (dbservers, prod, ...) она попасть не может, а имя группы не
            # выходит за пределы пространства yc_, пригодного для пути
            # group_vars/<имя> (см. LABEL_GROUP_RE). Ключ берём из
            # нормализованных меток: `ansible-group` и `ansible_group` — одна метка.
            group_value = str(labels.get('ansible_group') or '').strip()
            if group_value:
                suffix = group_value.replace('-', '_')
                if suffix.startswith(LABEL_GROUP_PREFIX):
                    display.warning(
                        f"yandex_cloud_inventory: у ВМ '{instance.name}' метка "
                        f"'ansible_group' уже начинается с '{LABEL_GROUP_PREFIX}', "
                        f"группа будет '{LABEL_GROUP_PREFIX}{suffix}'"
                    )
                group_name = LABEL_GROUP_PREFIX + suffix
                if LABEL_GROUP_RE.match(group_name):
                    self.inventory.add_group(group_name)
                    self.inventory.add_host(host_name, group=group_name)
                else:
                    display.warning(
                        f"yandex_cloud_inventory: у ВМ '{instance.name}' имя группы "
                        f"'{group_value}' недопустимо (разрешены буквы, цифры, '_' и '-' "
                        f"после префикса '{LABEL_GROUP_PREFIX}'), группа не создана"
                    )

            # Добавляем в основную группу, если указана
            if group:
                self.inventory.add_host(host_name, group=group)
