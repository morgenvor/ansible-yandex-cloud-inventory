"""Данные-заглушки вместо ответов Yandex Cloud Compute API.

Нужны, чтобы прогнать настоящий плагин через настоящий `ansible-inventory`
без доступа к облаку. Повторяют структуру ответа ListInstances:
instance.name / .zone_id / .labels / .network_interfaces[0].primary_v4_address
с полями .address и .one_to_one_nat.
"""

from types import SimpleNamespace as NS


def _iface(internal, external=None):
    nat = NS(address=external) if external else None
    return NS(primary_v4_address=NS(address=internal, one_to_one_nat=nat))


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

# Сценарий NIC без адреса: интерфейс есть, primary_v4_address = None.
# Плагин раньше падал на этом с AttributeError и отдавал пустой inventory.
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

# Сценарий коллизии имён хостов: `web-1` и `web_1` дают один и тот же хост
# `web_1`, раньше вторая ВМ молча вытесняла первую. Зоны разные специально:
# без этого не видно, что прежний хост остаётся в группе зоны другой ВМ.
COLLIDE = [
    _vm("web-1", "ru-central1-a", {}, internal="10.0.7.1"),
    _vm("web_1", "ru-central1-b", {}, internal="10.0.7.2"),
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

# Сценарий фильтра по метке ansible: проверяем, что сравнение не зависит
# от регистра значения (фикс №7). Контрольная ВМ с ansible=true должна остаться.
CASE_LABELS = [
    _vm("stay-vm", "ru-central1-a", {"ansible": "true"}, internal="10.0.3.1"),
    _vm("skip_lower", "ru-central1-a", {"ansible": "false"}, internal="10.0.3.2"),
    _vm("skip_upper", "ru-central1-a", {"ansible": "FALSE"}, internal="10.0.3.3"),
    _vm("skip_title", "ru-central1-a", {"ansible": "False"}, internal="10.0.3.4"),
    _vm("stay_nolabel", "ru-central1-a", {"env": "prod"}, internal="10.0.3.5"),
]
