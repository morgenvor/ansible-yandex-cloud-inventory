"""Заглушка «SDK yandexcloud не установлен».

Существует как модуль, но падает при импорте — ровно то, что видит пользователь,
который поставил плагин каталогом (как советует README), но не поставил
зависимость. Каталог tests/fake_nosdk кладётся в PYTHONPATH ПЕРЕД tests/fake_yc
только в одном сценарии tests/run-tests.sh: плагин обязан ответить понятной
ошибкой с подсказкой `pip install yandexcloud`, а не трейсбеком
«Unexpected Exception, this is probably a bug».
"""

raise ImportError("No module named 'yandexcloud'")