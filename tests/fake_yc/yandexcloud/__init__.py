"""Заглушка официального SDK `yandexcloud` — только чтобы плагин импортировался.

Никаких сетевых вызовов: SDK.client() отдаёт объект с методом List(),
который возвращает заранее заготовленные ВМ. Поддерживает page_token,
чтобы можно было проверить постраничную выдачу.

Сценарий выбирается переменной FAKE_YC_SCENARIO (неизвестное имя — ошибка,
иначе опечатка в тесте молча проверяла бы сценарий по умолчанию).
С какими аргументами позвали SDK, печатается в stderr при
FAKE_YC_ECHO_AUTH=1: иначе проверить приоритет способов аутентификации
невозможно — внутри заглушки проверять нечего.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import fake_data  # noqa: E402

PAGE = 100

SCENARIOS = {
    "default": fake_data.DEFAULT,
    "no_nic": fake_data.NO_NIC,
    "nic_no_v4": fake_data.NIC_NO_V4,
    "nic_empty_v4": fake_data.NIC_EMPTY_V4,
    "collide": fake_data.COLLIDE,
    "inject": fake_data.INJECT,
    "whitelist": fake_data.WHITELIST,
    "paged": fake_data.PAGED,
    "case_labels": fake_data.CASE_LABELS,
}


class _FakeInstanceClient:
    def List(self, request):
        name = os.environ.get("FAKE_YC_SCENARIO", "default")
        if name not in SCENARIOS:
            raise RuntimeError(
                f"FAKE_YC_SCENARIO={name!r} неизвестен; есть: {', '.join(sorted(SCENARIOS))}"
            )
        instances = SCENARIOS[name]

        # Эмулируем реальный API: отдаём не больше page_size и next_page_token.
        page_size = request.page_size or 100
        start = int(request.page_token or 0)
        chunk = instances[start:start + min(page_size, PAGE)]
        next_token = ""
        if start + len(chunk) < len(instances):
            next_token = str(start + len(chunk))
        return type(
            "ListInstancesResponse",
            (),
            {"instances": chunk, "next_page_token": next_token},
        )()


class SDK:
    def __init__(self, **kwargs):
        # Запоминаем, с чем нас позвали: тест проверяет способ аутентификации.
        self.init_kwargs = kwargs
        if os.environ.get("FAKE_YC_ECHO_AUTH") == "1":
            key = kwargs.get("service_account_key")
            print(
                "FAKE_YC_AUTH service_account_key=%s iam_token=%s"
                % (
                    key.get("id", "?") if isinstance(key, dict) else "no",
                    "yes" if kwargs.get("iam_token") else "no",
                ),
                file=sys.stderr,
            )

    def client(self, stub_ctor):
        name = getattr(stub_ctor, "__name__", "")
        if name == "InstanceServiceStub":
            return _FakeInstanceClient()
        raise RuntimeError(f"заглушка не знает стаб {name!r}")
