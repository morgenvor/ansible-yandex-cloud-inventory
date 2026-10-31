# Ansible Yandex Cloud Dynamic Inventory Plugin (fork + fixes)

Динамический inventory-плагин Ansible для Yandex Cloud: получает Compute-инстансы
и строит inventory по зонам и меткам.

> **Это форк.** Оригинал — [mzatolokin/ansible-yandex-cloud-inventory](https://github.com/mzatolokin/ansible-yandex-cloud-inventory)
> (upstream `main`, коммит `d2ad1ab`, автор Maksim Zatolokin, лицензия MIT).
> Upstream не обновлялся около года, поэтому исправления выпускаются из форка
> `morgenvor/ansible-yandex-cloud-inventory` в ветке `local-patches`.
> Код upstream не присваивается: в этом репозитории он плюс фиксы.
> Полный список отличий и порядок миграции — в
> [`docs/upstream-differences.md`](docs/upstream-differences.md).

## Что исправлено относительно upstream

1. `ansible_host` берётся из **публичного** IP; внутренний остаётся в `private_ipv4`.
   Раньше предпочитался внутренний адрес, и подключение с машины вне облака не работало.
2. `verify_file` принимает только файлы `*yc_inventory.yml` / `*yc_inventory.yaml`.
   Раньше плагин забирал любой yaml-inventory и падал с «Incorrect plugin name».
3. `ListInstances` читается постранично (`page_size=1000` + `next_page_token`).
   Раньше терялись все ВМ после первой страницы (по умолчанию 100).
4. ВМ без сетевых интерфейсов пропускается с предупреждением, а не роняет плагин
   с `IndexError` (после которого Ansible молча отдавал пустой inventory).
5. Значения меток не портятся (`web-app` остаётся `web-app`); нормализуется (`-` → `_`)
   только ключ, потому что он становится именем переменной.
6. Переменная `name` переименована в `yc_name`: `name` зарезервировано в Ansible.
7. `ansible: false` сравнивается без учёта регистра (`False`, `FALSE` тоже работают).
8. Метки больше не могут переопределить служебные переменные: все они
   экспортируются как `yc_label_*`, а `ansible_*`-метки применяются только из
   белого списка (`ansible_user`, `ansible_port`). Иначе метка `ansible_host`
   подменяла адрес подключения, а `ansible_ssh_common_args` с `ProxyCommand`
   выполняла произвольную команду на контроллере. Подробности и миграция —
   [`docs/upstream-differences.md`](docs/upstream-differences.md).

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
# (запускать не из корня репозитория: иначе Python найдёт локальный каталог
# inventory_plugins/ и покажет путь к исходникам, а не к установленному пакету)
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

`ansible.cfg` в корне репозитория — конфиг офлайн-стенда: в нём только путь к
плагину и список `enable_plugins`, SSH стенду не нужен. Как образец для боевого
конфига он годится, но проверьте остальные настройки сами: например
`host_key_checking` здесь сознательно не выставлен, а отключать проверку ключей
хоста на рабочей машине — отдельное решение, а не «настройка по умолчанию».

## Группировка инстансов

Плагин создаёт группы на основе:

1. **Зон** — например, `ru_central1_a` (дефисы заменяются на `_`);
2. **Метки `ansible_group`** — инстанс попадает в указанную группу;
3. **Параметра `group`** — если задан, все хосты добавляются в эту группу.

### Метки

Метки ВМ — недоверенные данные: поставить их может любой, у кого есть доступ к
каталогу. Поэтому «как есть» они в переменные хоста не попадают:

- любая метка экспортируется как `yc_label_<ключ>` (`-` в ключе заменяется на
  `_`, значение остаётся прежним): `role: web-app` → `yc_label_role = web-app`;
- служебными переменными становятся только `ansible_user` и `ansible_port`
  (белый список): они применяются и как есть, и дублируются как `yc_label_*`;
- прочие метки, начинающиеся на `ansible_`, не применяются — плагин печатает
  предупреждение с именем ВМ и ключом. Причина: метка `ansible_host` подменила
  бы адрес подключения, а `ansible_ssh_common_args` с `ProxyCommand` выполнила
  бы команду на контроллере;
- две метки — директивы, а не переменные:
  - `ansible: false` — исключить инстанс из inventory (регистр не важен);
  - `ansible_group: имя_группы` — добавить инстанс в группу.

Плагин также предупреждает, если у ВМ нет IPv4-адреса, если две ВМ дают
одинаковое имя хоста (`web-1` и `web_1`) и если два ключа меток совпали после
нормализации (`a-b` и `a_b`).

### Переменные хоста

| Переменная | Значение |
|---|---|
| `ansible_host` | публичный IP, если он есть, иначе внутренний |
| `ipv4` | публичный IP (может быть пустым) |
| `private_ipv4` | внутренний IP |
| `yc_name` | имя инстанса в Yandex Cloud |
| `yc_label_<ключ>` | метка ВМ (например, `role: web-app` → `yc_label_role`) |

Служебные переменные из таблицы метками не переопределяются: все метки попадают
только в `yc_label_*`. Исключение — белый список `ansible_user`/`ansible_port`
(см. «Метки»).

### Миграция 1.x → 2.0

В 2.0 метки больше не становятся переменными хоста напрямую. Что поменять в
плейбуках, ролях и `group_vars`:

| Было (1.x) | Стало (2.0) |
|---|---|
| `role` (метка `role`) | `yc_label_role` |
| `env` (метка `env`) | `yc_label_env` |
| `ansible_user`, `ansible_port` | без изменений (белый список) |
| `ansible_group` | без изменений (директива группировки) |
| `ansible: false` | без изменений (фильтр) |

Если переписывать обращения не хочется, перенесите значения в `group_vars/`
(или `host_vars/` по `yc_name`), а метки оставьте только для группировки.
Остальные отличия и ограничения — в
[`docs/upstream-differences.md`](docs/upstream-differences.md).

### Ограничения

- Параметр `cache` у `parse()` принимается для совместимости с интерфейсом
  Ansible, но не используется: inventory каждый раз запрашивается у API.
- Учитывается только первый сетевой интерфейс ВМ; мультиинтерфейсные ВМ
  получают адрес первого интерфейса.
- Имя хоста — это имя ВМ, в котором дефисы заменены на `_`. Поэтому ВМ
  `web-1` в inventory называется `web_1`, и `ansible web-1 -m ping` не найдёт
  хост («Could not match supplied host pattern»); обращайтесь по `web_1`.
- Если у ВМ нет метки `ansible_user`, Ansible подключается от имени локального
  пользователя контроллера, а не от пользователя образа. Для ВМ, созданных
  через CLI, это обычно `yc-user`, для образов Ubuntu — `ubuntu`: имя нужно
  задавать явно меткой `ansible_user` (она в белом списке).

## Требования

- Python 3.11+
- Ansible 2.18.6+
- yandexcloud >= 0.99.0

Проверенные версии для стенда зафиксированы в `requirements-test.txt`
(`ansible-core==2.19.14`, `yandexcloud==0.412.0`).

## Проверка без облака

Стенд подменяет SDK заглушкой (`tests/fake_yc/`) и гоняет настоящий
`ansible-inventory` по десяти сценариям: каталог с метками и IP, ВМ без NIC,
NIC без IPv4, коллизия имён хостов, инъекция метками (`ansible_host`,
`ansible_ssh_common_args`), белый список `ansible_user`/`ansible_port`,
пагинация 150 ВМ, `verify_file`, регистр `ansible: false`, способы
аутентификации и тексты ошибок. Всего 55 проверок; при регрессе скрипт падает
с ненулевым кодом.

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
