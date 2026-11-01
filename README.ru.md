# Ansible Yandex Cloud Dynamic Inventory Plugin (fork + fixes)

**Русский** | [English](README.md)

[![tests](https://github.com/morgenvor/ansible-yandex-cloud-inventory/actions/workflows/tests.yml/badge.svg)](https://github.com/morgenvor/ansible-yandex-cloud-inventory/actions/workflows/tests.yml)

Динамический inventory-плагин Ansible для Yandex Cloud: получает Compute-инстансы
и строит inventory по зонам и меткам.

> **Это форк.** Оригинал — [mzatolokin/ansible-yandex-cloud-inventory](https://github.com/mzatolokin/ansible-yandex-cloud-inventory)
> (upstream `main`, коммит `d2ad1ab`, автор Maksim Zatolokin, лицензия MIT).
> Upstream не обновлялся около года, поэтому исправления выпускаются из форка
> `morgenvor/ansible-yandex-cloud-inventory` (ветка по умолчанию `local-patches`).
> Код upstream не присваивается: в этом репозитории он плюс фиксы.
> Что именно исправлено, что изменилось в контракте меток и как перейти со
> старой версии — в [`docs/upstream-differences.md`](docs/upstream-differences.md)
> (этот документ пока только на русском).

## Возможности

- Получает Compute-инстансы из Yandex Cloud
- Аутентификация через IAM-токен или ключ сервисного аккаунта
- Группы по зонам и пользовательским меткам
- `ansible_host` — публичный IP (внутренний остаётся в `private_ipv4`), так что
  подключение работает и с машины вне облака
- Имя хоста — имя ВМ как есть, вместе с дефисами: `ansible web-1 -m ping` находит
  именно `web-1`, а `web-1` и `web_1` остаются двумя разными хостами
- Постраничное чтение `ListInstances`, поэтому ВМ не теряются после первой
  страницы
- Исключение инстанса меткой `ansible: false` (регистр значения не важен)
- Метки ВМ экспортируются как `yc_label_<ключ>`, служебными переменными
  становятся только `ansible_user` и `ansible_port` (белый список): метка не
  может подменить адрес подключения или выполнить команду на контроллере
- Дополнительные группы через метку `ansible_group` — только с префиксом `yc_`:
  `ansible_group: docker` → группа `yc_docker`
- Понятная ошибка вместо трейсбека, если не установлен SDK `yandexcloud`

## Установка

### Из исходного кода

1. Клонируйте форк. Ветка по умолчанию `local-patches` — это код форка с
   исправлениями; `main` в форке указывает на чистый upstream и нужен только как
   точка синхронизации:
```bash
git clone https://github.com/morgenvor/ansible-yandex-cloud-inventory.git
cd ansible-yandex-cloud-inventory
```

2. Поставьте зависимости и сам плагин — единственный источник зависимостей
это `pyproject.toml`:
```bash
pip install -e .
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
загружает inventory-плагины только из каталогов плагинов и коллекций.
`entry_points` для плагинов Ansible не читает вовсе — такого механизма в
ansible-core нет (entry points там только у `console_scripts` и у ролей).
Поэтому после установки укажите Ansible на каталог плагина внутри окружения:

```bash
# путь внутри venv/site-packages, где лежит установленный inventory_plugins/
# (запускать не из корня репозитория: иначе Python найдёт локальный каталог
# inventory_plugins/ и покажет путь к исходникам, а не к установленному пакету)
export ANSIBLE_INVENTORY_PLUGINS="$(python -c 'import inventory_plugins, os; print(os.path.dirname(inventory_plugins.__file__))')"
```

Проще всего — работать из исходников и держать `inventory_plugins = ./inventory_plugins`
в `[defaults]` своего `ansible.cfg` (так устроен этот репозиторий).

Учтите: `pip install .` — это ещё и шаг, который ставит SDK `yandexcloud`. Если
вы копируете каталог плагина руками, поставьте SDK сами (`pip install
yandexcloud`), иначе плагин остановится с явной ошибкой ровно об этом.

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

**Имя файла важно.** Плагин объявляет своим только файл `yc_inventory.yml`
(`.yaml`) или `<префикс>_yc_inventory.yml` — разделитель `_` и непустой префикс
обязательны, поэтому `inventory.yml` и `_yc_inventory.yml` он проигнорирует: так
задумано, чтобы не перехватывать чужие inventory. Готовый пример —
[`examples/yc_inventory.yml`](examples/yc_inventory.yml):

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

### Подключение и `ansible_user`

Плагин не задаёт пользователя подключения: если `ansible_user` не задан нигде,
Ansible подключается от имени локального пользователя контроллера, а не от
пользователя образа. Для ВМ, созданных через CLI, это обычно `yc-user`, для
образов Ubuntu — `ubuntu`. Это поведение Ansible, а не дефект плагина: имя
задаётся в плейбуке (`remote_user`), ключом `-u` или в `group_vars`.

Порядок приоритета стоит держать в голове: метка `ansible_user` — это
переменная хоста, поэтому она **перебивает** и `remote_user`, и `-u`
(`play_context.set_task_and_variable_override()`: сначала применяются атрибуты
задачи, затем magic-переменные из инвентаря).

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
2. **Метки `ansible_group`** — инстанс попадает в группу `yc_<значение>`
   (значение `docker` даёт группу `yc_docker`, дефисы заменяются на `_`);
3. **Параметра `group`** — если задан, все хосты добавляются в эту группу.

### Метки

Метки ВМ — недоверенные данные: поставить их может любой, у кого есть доступ к
каталогу. Поэтому «как есть» они в переменные хоста не попадают:

- любая метка экспортируется как `yc_label_<ключ>` (`-` в ключе заменяется на
  `_`, значение остаётся прежним): `role: web-app` → `yc_label_role = web-app`;
- служебными переменными становятся только `ansible_user` и `ansible_port`
  (белый список): они применяются и как есть, и дублируются как `yc_label_*`.
  Учтите: `ansible_user` — это переменная хоста, поэтому она **перебивает**
  `remote_user` плейбука и `-u` в командной строке. Метку с этим ключом ставьте
  осознанно, иначе «почему подключились не тем пользователем» ищется долго;
- значения из белого списка проверяются: `ansible_port` должен быть числом
  1–65535, `ansible_user` — непустым и без пробелов, кавычек, обратной косой
  черты и непечатаемых символов (оба уходят в командную строку `ssh`, а
  управляющая последовательность из метки ещё и попала бы в терминал оператора
  и в лог CI). Непригодное значение отбрасывается с предупреждением и остаётся
  доступным как `yc_label_*`;
- прочие метки, начинающиеся на `ansible_`, не применяются — плагин печатает
  предупреждение с именем ВМ и ключом. Причина: метка `ansible_host` подменила
  бы адрес подключения, а `ansible_ssh_common_args` с `ProxyCommand` выполнила
  бы команду на контроллере;
- две метки — директивы, а не переменные. Ключи нормализуются так же, как у
  переменных, поэтому `ansible-group` и `ansible_group` — одна и та же метка:
  - `ansible: false` — исключить инстанс из inventory (регистр не важен);
  - `ansible_group: docker` — добавить инстанс в группу `yc_docker`.
    Префикс `yc_` **обязателен и не настраивается**: без него метка вступала
    бы в группы, которыми управляете вы (`dbservers`, `prod`), и к хосту
    применялись бы их `group_vars` — с секретами или с `ansible_connection:
    local`, то есть выполнением команд на контроллере. Вдобавок имя группы
    уходит в путь `group_vars/<имя>`, а метку может поставить любой, у кого
    есть доступ к каталогу: значение `../../outside/evil` читало файл за
    пределами `group_vars`. Поэтому:
    - `-` в значении заменяется на `_` (`web-app` → `yc_web_app`);
    - остальное должно быть буквами, цифрами и `_` (длина — до 63 символов):
      иначе плагин печатает предупреждение с именем ВМ и значением, группу
      **не создаёт**, а хост остаётся в inventory (зона и `group`-опция не
      страдают);
    - если значение уже начинается с `yc_`, второго префикса не угадываем:
      `ansible_group: yc_docker` даёт `yc_yc_docker` и предупреждение в логе;
    - сырое значение остаётся видимым в `yc_label_ansible_group`.

Плагин также предупреждает, если у ВМ нет IPv4-адреса и если два ключа меток
совпали после нормализации (`a-b` и `a_b`). Отдельно есть страховка от дубля
имени хоста в ответе API: по правилам Yandex Cloud имена ВМ в каталоге
уникальны, поэтому предупреждение рассчитано на сбой API, а не на штатный
сценарий (стендом не проверяется — воспроизвести нельзя, см.
[`docs/upstream-differences.md`](docs/upstream-differences.md), раздел 7).

### Переменные хоста

Имя хоста — это имя ВМ в Yandex Cloud как есть, вместе с дефисами: ВМ `web-1`
в inventory называется `web-1`, и `ansible web-1 -m ping` её находит. Через
точку такие переменные не читаются (Jinja разберёт `web-1` как вычитание) —
используйте `hostvars['web-1']`.

| Переменная | Значение |
|---|---|
| `ansible_host` | публичный IP, если он есть, иначе внутренний |
| `ipv4` | публичный IP или `null`, если публичного адреса нет |
| `private_ipv4` | внутренний IP |
| `yc_name` | имя инстанса в Yandex Cloud |
| `yc_label_<ключ>` | метка ВМ (например, `role: web-app` → `yc_label_role`) |

Служебные переменные из таблицы метками не переопределяются: все метки попадают
только в `yc_label_*`. Исключение — белый список `ansible_user`/`ansible_port`
(см. «Метки»).

## Переход со старой версии

В 2.0 метки перестали быть переменными хоста напрямую (`role` → `yc_label_role`),
в 3.0 имя хоста перестало нормализоваться (`web_1` → `web-1`), а группы из метки
получили обязательный префикс `yc_`. Таблицы «было → стало» и порядок перехода —
в [`docs/upstream-differences.md`](docs/upstream-differences.md), разделы 5 и 6.

## Ограничения

- Параметр `cache` у `parse()` принимается для совместимости с интерфейсом
  Ansible, но не используется: inventory каждый раз запрашивается у API.
- Учитывается только первый сетевой интерфейс ВМ.
- Плагин не смотрит на состояние ВМ: остановленная или вытесненная машина
  остаётся в inventory, пока существует как ресурс.
- Если API отказал (истёк IAM-токен, не хватает прав), Ansible выводит
  предупреждение и продолжает работу с **пустым** inventory — так устроен разбор
  источников. Плагин печатает причину и подсказку, но код возврата успешный;
  в автоматике проверяйте, что inventory не пуст.
- Группы `yc_*` — пространство меток, а не ваше: их создаёт `ansible_group`, и
  чужие группы (например `dbservers`) меткой недостижимы. Обратная сторона: не
  держите секреты в `group_vars/yc_*` — такую группу может создать любая ВМ
  каталога и получить эти переменные.

Полный список осознанных ограничений — в
[`docs/upstream-differences.md`](docs/upstream-differences.md), раздел 7.

## Требования

- Python 3.11+
- ansible-core 2.18.18+ (2.18.18 — первый патч ветки без CVE-2026-11332)
- yandexcloud >= 0.99.0, < 1.0 (проверено на 0.99…0.412)

Проверенные версии для стенда зафиксированы в `requirements-test.txt`
(`ansible-core==2.19.14`, `yandexcloud==0.412.0`).

## Проверка без облака

Стенд подменяет SDK заглушкой (`tests/fake_yc/`) и гоняет настоящий
`ansible-inventory` по восемнадцати сценариям — от меток и адресов до
постраничной выдачи, `verify_file`, отказа API, инъекции метками и отсутствия
самого SDK. Всего 127 проверок: при регрессе скрипт падает с ненулевым кодом и
печатает, какое утверждение не выполнено. Что именно покрыто — в
[`docs/upstream-differences.md`](docs/upstream-differences.md), раздел 8.

```bash
./bootstrap.sh        # соберёт локальный .venv
./tests/run-tests.sh  # прогон сценариев
```

Стенд входит в sdist: плагин можно проверить по собранному архиву, без доступа
к облаку и без клонирования репозитория.

Те же команды прогоняет CI (GitHub Actions, [`.github/workflows/tests.yml`](.github/workflows/tests.yml)):
на Python 3.11, 3.12 и 3.13 и отдельной задачей — из распакованного sdist, чтобы
пропажа файла из `MANIFEST.in` не осталась незамеченной.

## Проверено на реальном облаке

Кроме стенда, поведение проверено на живом каталоге Yandex Cloud (метки, приоритет
`ansible_user`, имена с дефисами, `group_vars`); детали — в
[`docs/upstream-differences.md`](docs/upstream-differences.md), раздел 8.

Свой каталог проверяет [`tests/live-check.sh`](tests/live-check.sh) — он только
читает облако: `LIVE_INVENTORY=secrets/live_yc_inventory.yml ./tests/live-check.sh`.

## Лицензия

MIT — см. [LICENSE](LICENSE). Автор upstream-кода — Maksim Zatolokin;
фиксы и упаковка форка — [morgenvor](https://github.com/morgenvor).

## Поддержка

Проблемы форка — в issue репозитория `morgenvor/ansible-yandex-cloud-inventory`.
Проблемы исходного плагина — в issue upstream.