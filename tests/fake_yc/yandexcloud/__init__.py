"""Заглушка официального SDK `yandexcloud` — только чтобы плагин импортировался.

Никаких сетевых вызовов: SDK.client() отдаёт объект с методом List(),
который возвращает заранее заготовленные ВМ. Поддерживает page_token,
чтобы можно было проверить постраничную выдачу.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import fake_data  # noqa: E402

PAGE = 100


class _FakeInstanceClient:
    def List(self, request):
        scenario = os.environ.get("FAKE_YC_SCENARIO", "default")
        if scenario == "no_nic":
            instances = fake_data.NO_NIC
        elif scenario == "paged":
            instances = fake_data.PAGED
        elif scenario == "case_labels":
            instances = fake_data.CASE_LABELS
        else:
            instances = fake_data.DEFAULT

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


class _FakeZoneClient:
    def List(self, request):
        return type("ListZonesResponse", (), {"zones": []})()


class SDK:
    def __init__(self, **kwargs):
        # Запоминаем, с чем нас позвали: тест проверяет способ аутентификации.
        self.init_kwargs = kwargs

    def client(self, stub_ctor):
        name = getattr(stub_ctor, "__name__", "")
        if name == "InstanceServiceStub":
            return _FakeInstanceClient()
        return _FakeZoneClient()
