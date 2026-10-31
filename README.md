# Ansible Yandex Cloud Dynamic Inventory Plugin (fork + fixes)

Динамический inventory-плагин Ansible для Yandex Cloud: получает Compute-инстансы
и строит inventory по зонам и меткам.

> **Это форк.** Оригинал — [mzatolokin/ansible-yandex-cloud-inventory](https://github.com/mzatolokin/ansible-yandex-cloud-inventory)
> (upstream `main`, коммит `d2ad1ab`, автор Maksim Zatolokin, лицензия MIT).
> Upstream не обновлялся около года, поэтому исправления выпускаются из форка
> `morgenvor/ansible-yandex-cloud-inventory` в ветке `local-patches`.
> Код upstream не присваивается: в этом репозитории он плюс 7 фиксов.

## Что исправлено относительно upstream

1. `ansible_host` берётся из **публичного** IP; внутренний остаётся в `private_ipv4`.
   Раньше предпочитался внутренний адрес, и подключение с машины вне облака не работало.
2. `verify_file` принимает только файлы `*yc_inventory.yml` / `*yc_inventory.yaml`.
   Раньше плагин забирал любой yaml-inventory и падал с «Incorrect plugin name».
3. `ListInstances` читается постранично (`page_size=1000` + `next_page_token`).
   Раньше терялись все ВМ после первой страницы (по умолчанию 100).
4. ВМ без сетевых интерфейсов пропускается с предупреждением, а не роняет плагин
   с `IndexError` (после которого Ansible молча отдавал пустой inventory).
5. Значения меток не портятся (`web-app` остаётся `web-app`); чистятся только ключи,
   потому что они становятся именами переменных.
6. Переменная `name` переименована в `yc_name`: `name` зарезервировано в Ansible.
7. `ansible: false` сравнивается без учёта регистра (`False`, `FALSE` тоже работают).

## Возможности

- Получает Compute-инстансы из Yandex Cloud
- Аутентификация через IAM-токен или ключ сервисного аккаунта
- Группы по зонам и пользовательским меткам
- Исключение инстанса меткой `ansible: false`
- Назначение дополнительных групп через метку `ansible_group`

## Установка

### Из исходного кода

1. Клонируйте форк:
```bash
git clone https://github.com/morgenvor/ansible-yandex-cloud-inventory.git
cd ansible-yandex-cloud-inventory
git checkout local-patches
```

2. Установите зависимости:
```bash
pip install -r requirements.txt
```

3. Сделайте плагин доступным для Ansible — вариант через `ansible.cfg`
(см. раздел «Использование с ansible.cfg») или переменную окружения:
```bash
export ANSIBLE_INVENTORY_PLUGINS=./inventory_plugins
```

### Через `pip install` (и почему одного этого мало)

```bash
pip install .
```

Пакет встанет в `site-packages` и будет виден как Python-модуль, но
**Ansible не найдёт плагин автоматически**: ansible-core (проверено на 2.19)
загружает inventory-плагины только из каталогов плагинов и коллекций, а запись
`entry_points` из `pyproject.toml` не читает. Поэтому после установки укажите
Ansible на каталог плагина внутри окружения:

```bash
# путь внутри venv/site-packages, где лежит установленный inventory_plugins/
export ANSIBLE_INVENTORY_PLUGINS="$(python -c 'import inventory_plugins, os; print(os.path.dirname(inventory_plugins.__file__))')"
```

Проще всего — работать из исходников и держать `inventory_plugins = ./inventory_plugins`
в `[defaults]` своего `ansible.cfg` (так устроен этот репозиторий).

## Конфигурация

### Аутентификация

Плагин поддерживает два метода.

#### Ключ сервисного аккаунта (рекомендуется)

```yaml
plugin: yandex_cloud_inventory
folder_id: ваш-folder-id
service_account_key_file: /путь/к/файлу/ключа/сервисного/аккаунта.json
```

#### IAM-токен (удобно для разовых проверок)

**⚠️ Важно:** IAM-токен живёт 12 часов и требует обновления.

```yaml
plugin: yandex_cloud_inventory
folder_id: ваш-folder-id
iam_token: ваш-iam-токен
```

Токен можно не писать в файл, а взять из переменной окружения `YC_IAM_TOKEN`:

```yaml
plugin: yandex_cloud_inventory
folder_id: ваш-folder-id
# iam_token будет автоматически взят из переменной окружения YC_IAM_TOKEN
```

Обновление токена:

```bash
yc iam create-token
```

### Параметры

| Параметр | Обязательный | Описание |
|----------|--------------|----------|
| `plugin` | Да | Должен быть `yandex_cloud_inventory` |
| `folder_id` | Да | ID папки Yandex Cloud |
| `iam_token` | Нет* | IAM-токен для аутентификации |
| `service_account_key_file` | Нет* | Путь к JSON-файлу ключа сервисного аккаунта |
| `group` | Нет | Имя группы, куда добавляются все хосты |

\*Нужен либо `iam_token`, либо `service_account_key_file` (приоритет у ключа).

### Пример конфигурации

**Имя файла важно.** Плагин объявляет своим только файл, имя которого
заканчивается на `yc_inventory.yml` (или `yc_inventory.yaml`). Файл
`inventory.yml` он проигнорирует — так задумано, чтобы не перехватывать чужие
inventory. Готовый пример — [`examples/yc_inventory.yml`](examples/yc_inventory.yml):

```yaml
plugin: yandex_cloud_inventory
folder_id: <YOUR_FOLDER_ID>
group: ycloud_group
service_account_key_file: <YOUR_SERVICE_ACCOUNT_KEY_FILE>
```

Или с токеном из окружения:

```bash
export YC_IAM_TOKEN="ваш-iam-токен"
```

```yaml
plugin: yandex_cloud_inventory
folder_id: <YOUR_FOLDER_ID>
group: ycloud_group
```

## Использование

### Проверка inventory

```bash
ansible-inventory -i yc_inventory.yml --list
ansible-inventory -i yc_inventory.yml --graph --vars
```

### С плейбуками

```bash
ansible-playbook -i yc_inventory.yml playbook.yml
```

### С `ansible.cfg`

```ini
[defaults]
# Путь к плагину — именно в [defaults]; в [inventory] Ansible этот ключ не читает.
inventory_plugins = ./inventory_plugins

[inventory]
# yaml обязателен: без него штатный static-inventory не парсится.
enable_plugins = yandex_cloud_inventory, yaml, ini, script, host_list
```

Рабочий `ansible.cfg` лежит в корне репозитория — можно взять его за основу.

## Группировка инстансов

Плагин создаёт группы на основе:

1. **Зон** — например, `ru_central1_a` (дефисы заменяются на `_`);
2. **Метки `ansible_group`** — инстанс попадает в указанную группу;
3. **Параметра `group`** — если задан, все хосты добавляются в эту группу.

### Метки

- `ansible: false` — исключить инстанс из inventory (регистр не важен);
- `ansible_group: имя_группы` — добавить инстанс в группу;
- любые другие метки становятся переменными хоста (`-` в ключе → `_`,
  значения не меняются).

### Переменные хоста

| Переменная | Значение |
|---|---|
| `ansible_host` | публичный IP, если он есть, иначе внутренний |
| `ipv4` | публичный IP (может быть пустым) |
| `private_ipv4` | внутренний IP |
| `yc_name` | имя инстанса в Yandex Cloud |

## Требования

- Python 3.8+
- Ansible 2.18.6+
- yandexcloud >= 0.99.0

Проверенные версии для стенда зафиксированы в `requirements-test.txt`
(`ansible-core==2.19.14`, `yandexcloud==0.412.0`).

## Проверка без облака

Стенд подменяет SDK заглушкой (`tests/fake_yc/`) и гоняет настоящий
`ansible-inventory` по четырём сценариям: граф с IP/метками, ВМ без NIC,
пагинация 150 ВМ, чужой yaml-inventory не перехватывается.

```bash
./bootstrap.sh        # соберёт локальный .venv
./tests/run-tests.sh  # прогон сценариев
```

## Лицензия

MIT — см. [LICENSE](LICENSE). Автор upstream-кода — Maksim Zatolokin;
фиксы и упаковка форка — [morgenvor](https://github.com/morgenvor).

## Поддержка

Проблемы форка — в issue репозитория `morgenvor/ansible-yandex-cloud-inventory`.
Проблемы исходного плагина — в issue upstream.
