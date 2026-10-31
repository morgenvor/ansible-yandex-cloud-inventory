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


# Сценарий по умолчанию: 3 обычные ВМ + 1 исключённая меткой ansible=false.
DEFAULT = [
    _vm(
        "docker-server",
        "ru-central1-a",
        {"ansible_group": "docker", "env": "prod", "role": "web-app"},
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
