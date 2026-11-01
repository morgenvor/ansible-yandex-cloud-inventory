"""Данные-заглушки вместо ответов Yandex Cloud Compute API.

Нужны, чтобы прогнать настоящий плагин через настоящий `ansible-inventory`
без доступа к облаку. Повторяют структуру ответа ListInstances:
instance.name / .zone_id / .labels / .network_interfaces[0].primary_v4_address
с полями .address и .one_to_one_nat.
"""

from types import SimpleNamespace as NS


def _iface(internal, external=None):
    # Реальный protobuf НЕ возвращает None для незаполненных сообщений: он
    # отдаёт пустое сообщение с address == "". Проверено на yandexcloud 0.412.0
    # (NetworkInterface().primary_v4_address.address == ''), поэтому заглушка
    # повторяет именно это: иначе стенд проверяет сценарий, которого в облаке
    # не бывает, и пропускает тот, который бывает.
    nat = NS(address=external or "")
    return NS(primary_v4_address=NS(address=internal or "", one_to_one_nat=nat))


def _vm(name, zone, labels, internal, external=None, interfaces=None):
    if interfaces is None:
        interfaces = [_iface(internal, external)]
    return NS(name=name, zone_id=zone, labels=labels, network_interfaces=interfaces)


# Сценарий по умолчанию: 2 обычные ВМ + 1 исключённая меткой ansible=false.
DEFAULT = [
    _vm(
        "docker-server",
        "ru-central1-a",
        {"ansible_group": "docker", "env": "prod", "role": "web-app", "owner-team": "platform"},
        internal="10.0.0.5",
        external="178.154.248.236",
    ),
    _vm(
        "nexus_server",
        "ru-central1-a",
        {"ansible_group": "nexus_server"},
        internal="10.0.0.6",
    ),
    _vm(
        "old-test-vm",
        "ru-central1-b",
        {"ansible": "false"},
        internal="10.0.1.7",
        external="84.201.0.1",
    ),
]

# Отдельный сценарий: одна ВМ вообще без сетевых интерфейсов + одна нормальная.
NO_NIC = [
    _vm("broken-vm", "ru-central1-a", {}, internal=None, interfaces=[]),
    _vm(
        "healthy-vm",
        "ru-central1-a",
        {"ansible_group": "docker"},
        internal="10.0.0.9",
        external="178.154.248.99",
    ),
]

# Сценарий NIC без адреса в том виде, в каком его отдаёт реальный API:
# primary_v4_address — пустое сообщение, address == "". Плагин раньше падал
# на этом с AttributeError и отдавал пустой inventory, а после первой правки
# добавлял хост с ansible_host == "" (guard проверял `is None`).
NIC_EMPTY_V4 = [
    _vm(
        "nov4-vm",
        "ru-central1-a",
        {},
        internal=None,
        interfaces=[NS(primary_v4_address=NS(address="", one_to_one_nat=NS(address="")))],
    ),
    _vm(
        "healthy-vm",
        "ru-central1-a",
        {"ansible_group": "docker"},
        internal="10.0.4.9",
        external="178.154.248.99",
    ),
]

# Защитный вариант: primary_v4_address = None. Реальный protobuf так не делает,
# но так ведут себя заглушки и старые SDK — плагин обязан пережить и это.
NIC_NO_V4 = [
    _vm("nov4-vm", "ru-central1-a", {}, internal=None, interfaces=[NS(primary_v4_address=None)]),
    _vm(
        "healthy-vm",
        "ru-central1-a",
        {"ansible_group": "docker"},
        internal="10.0.4.9",
        external="178.154.248.99",
    ),
]

# Сценарий с дефисами в именах ВМ: `web-1` и `web_1` — ДВЕ разные ВМ.
# До 3.0 дефис заменялся на `_`, оба имени давали один хост `web_1`, и одна
# ВМ молча исчезала. Зоны разные специально: так видно, что каждый хост
# остаётся в своей зоне, а не «живёт» сразу в двух.
DASHES = [
    _vm("web-1", "ru-central1-a", {}, internal="10.0.7.1"),
    _vm("web_1", "ru-central1-b", {}, internal="10.0.7.2"),
]

# Сценарий дубля в ответе API: две записи с одним именем. Имена ВМ в каталоге
# уникальны, поэтому так API отвечать не должен — но молчаливой перезаписи быть
# не должно: плагин предупреждает, а не выдаёт один хост без объяснений.
DUP = [
    _vm("dup-vm", "ru-central1-a", {}, internal="10.0.8.1"),
    _vm("dup-vm", "ru-central1-b", {}, internal="10.0.8.2"),
]

# Сценарий инъекции через метки: ВМ пытается подменить адрес подключения и
# подсунуть команду контроллеру. Метки — недоверенные данные: применяться
# должны только yc_label_* и белый список (ansible_user).
INJECT = [
    _vm(
        "inject-vm",
        "ru-central1-a",
        {
            "ansible_host": "203.0.113.99",
            "ansible_ssh_common_args": "-o ProxyCommand=touch /tmp/pwned",
            "ansible_user": "deploy",
        },
        internal="10.0.5.1",
        external="178.154.248.50",
    ),
    _vm(
        "control-vm",
        "ru-central1-a",
        {"env": "prod"},
        internal="10.0.5.2",
        external="178.154.248.51",
    ),
]

# Сценарий белого списка: ansible_user/ansible_port применяются как служебные
# переменные, прочие ansible_* — только как yc_label_*.
WHITELIST = [
    _vm(
        "wl-vm",
        "ru-central1-a",
        {"ansible_user": "deploy", "ansible_port": "2222", "ansible_bad_arg": "x"},
        internal="10.0.6.1",
    ),
    # Недопустимые значения белого списка: порт не число, в логине пробел.
    # Метка недоверенная, а значение уходит в командную строку ssh
    # (`-o Port=...`, `-o User="..."`), поэтому такое не применяется —
    # но и не теряется: остаётся в yc_label_*.
    _vm(
        "wl-bad-vm",
        "ru-central1-a",
        {"ansible_user": "bad user", "ansible_port": "not-a-port"},
        internal="10.0.6.2",
    ),
]

# Сценарий для проверки постраничной выдачи: 150 ВМ, две страницы.
PAGED = [
    _vm(
        f"vm-{i:03d}",
        "ru-central1-a",
        {"ansible_group": "docker"},
        internal=f"10.0.2.{i % 250}",
        external=f"178.154.{i // 250}.{i % 250}",
    )
    for i in range(150)
]

# Сценарий недопустимых значений метки ansible_group. Значения меток, в отличие
# от имён ВМ, Yandex Cloud не ограничивает: поставить можно что угодно, а имя
# группы уходит в путь group_vars/<имя>. Поэтому группа создаётся только как
# yc_<значение> и только из букв, цифр и `_`; остальное — предупреждение и
# отсутствие группы, но хост в inventory остаётся.
BAD_GROUP = [
    _vm("slash-vm", "ru-central1-a", {"ansible_group": "../../evil"}, internal="10.0.9.1"),
    _vm("dot-vm", "ru-central1-a", {"ansible_group": "web.dev"}, internal="10.0.9.2"),
    _vm("blank-vm", "ru-central1-a", {"ansible_group": "   "}, internal="10.0.9.3"),
    _vm("web-app-vm", "ru-central1-a", {"ansible_group": "web-app"}, internal="10.0.9.4"),
    _vm("ok-group-vm", "ru-central1-a", {"ansible_group": "web_servers"}, internal="10.0.9.5"),
    # Значение уже с префиксом: префикс не «умничает», получается yc_yc_docker,
    # а миграционная ловушка видна предупреждением в логе.
    _vm("prefixed-vm", "ru-central1-a", {"ansible_group": "yc_docker"}, internal="10.0.9.6"),
]

# Сценарий директив, записанных через дефис. `ansible-group` и `ansible_group`
# дают одну и ту же переменную `yc_label_ansible_group`, поэтому директивой они
# должны считаться одинаково: раньше директивы читались из сырых ключей, и
# `ansible-group: docker` молча не создавал группу `yc_docker`.
# Фильтр `ansible: false` живёт в том же сценарии: после перехода на
# нормализованные ключи он обязан работать как раньше.
DASH_DIRECTIVE = [
    _vm("dash-group-vm", "ru-central1-a", {"ansible-group": "docker"}, internal="10.0.10.1"),
    _vm("dash-off-vm", "ru-central1-a", {"ansible": "false"}, internal="10.0.10.2"),
    _vm("plain-vm", "ru-central1-a", {"env": "prod"}, internal="10.0.10.3"),
]

# Сценарий для проверки фильтра по метке ansible: проверяем, что сравнение не зависит
# от регистра значения (фикс №7). Контрольная ВМ с ansible=true должна остаться.
CASE_LABELS = [
    _vm("stay-vm", "ru-central1-a", {"ansible": "true"}, internal="10.0.3.1"),
    _vm("skip-lower", "ru-central1-a", {"ansible": "false"}, internal="10.0.3.2"),
    _vm("skip-upper", "ru-central1-a", {"ansible": "FALSE"}, internal="10.0.3.3"),
    _vm("skip-title", "ru-central1-a", {"ansible": "False"}, internal="10.0.3.4"),
    _vm("stay-nolabel", "ru-central1-a", {"env": "prod"}, internal="10.0.3.5"),
]
