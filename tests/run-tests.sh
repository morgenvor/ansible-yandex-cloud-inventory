#!/usr/bin/env bash
# Проверка плагина inventory БЕЗ доступа к облаку.
#
# Подменяет SDK yandexcloud заглушкой (tests/fake_yc) и прогоняет настоящий
# ansible-inventory по сценариям. Нужен только .venv проекта (./bootstrap.sh).
#
# Каждый сценарий содержит утверждения (assert): при регрессе скрипт падает
# с ненулевым кодом и печатает, чего не хватало, — глазами сравнивать не нужно.
# Сейчас: 15 сценариев, 87 проверок.
#
# Запуск:  ./tests/run-tests.sh
set -euo pipefail

cd "$(dirname "$0")/.."

export PYTHONPATH="$PWD/tests/fake_yc"
# Плагин для проверки берём из этого репо, окружение — локальный .venv.
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
export ANSIBLE_HOME="$PWD/.ansible-home"
export ANSIBLE_LOCAL_TEMP="$ANSIBLE_HOME/tmp"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
# Сценарий «нет способа аутентификации» должен видеть именно пустое окружение,
# а не токен, случайно оставленный в оболочке.
unset YC_IAM_TOKEN

AI="${ANSIBLE_INVENTORY_BIN:-$PWD/.venv/bin/ansible-inventory}"
INV="$PWD/tests/yc_inventory.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$AI" ] || { echo "Нет $AI — создайте окружение: ./bootstrap.sh"; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    ok: %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL: %s\n' "$*" >&2; }

# expect_in <подстрока> <текст> — подстрока должна присутствовать.
expect_in() {
    if printf '%s' "$2" | grep -qF -- "$1"; then ok "есть '$1'"; else bad "нет '$1'"; fi
}
# expect_not_in <подстрока> <текст> — подстроки быть не должно.
expect_not_in() {
    if printf '%s' "$2" | grep -qF -- "$1"; then bad "не должно быть '$1'"; else ok "нет '$1'"; fi
}
# expect_line <строка> <текст> — точное совпадение строки (для счётчиков и
# проверки, что переменная называется ровно так, а не с префиксом).
expect_line() {
    if printf '%s\n' "$2" | grep -qxF -- "$1"; then ok "'$1'"; else bad "'$1' (получено: '$2')"; fi
}
# expect_no_line <строка> <текст> — точной строки быть не должно. Отличается от
# expect_not_in: `role = web-app` — это подстрока `yc_label_role = web-app`.
expect_no_line() {
    if printf '%s\n' "$2" | grep -qxF -- "$1"; then bad "не должно быть строки '$1'"; else ok "нет строки '$1'"; fi
}
# Значения переменных Ansible помечает unsafe и в JSON отдаёт как
# {"__ansible_unsafe": ...}: для проверок разворачиваем их обратно.

# hostvars <json> <host> — строки «host key = value», отсортированные.
hostvars() {
    printf '%s' "$1" | python3 -c '
import json, sys
host = sys.argv[1]
data = json.load(sys.stdin)["_meta"]["hostvars"].get(host, {})
for key in sorted(data):
    value = data[key]
    if isinstance(value, dict) and "__ansible_unsafe" in value:
        value = value["__ansible_unsafe"]
    print(f"{host} {key} = {value}")
' "$2"
}
# hostkeys <json> — строки «host key» по всем хостам (проверка отсутствия переменной).
hostkeys() {
    printf '%s' "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)["_meta"]["hostvars"]
for host in sorted(data):
    for key in sorted(data[host]):
        print(f"{host} {key}")
'
}
# hostgroups <json> — строки «group host» по всем группам (проверка зон).
hostgroups() {
    printf '%s' "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for group in sorted(data):
    if group.startswith("_"):
        continue
    for host in sorted(data[group].get("hosts", [])):
        print(f"{group} {host}")
'
}
# hostcount <json> — сколько хостов попало в inventory.
hostcount() {
    printf '%s' "$1" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["_meta"]["hostvars"]))
'
}

echo "=== 1. Каталог по умолчанию: yc_label_*, IP, группы, фильтр ansible=false ==="
ERRF="$TMP/default.err"
JSON="$("$AI" -i "$INV" --list 2>"$ERRF")"
VARS="$(hostvars "$JSON" docker-server)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
# Метка уходит под безопасный префикс, значение с дефисом не портится (фикс №5).
expect_line "docker-server yc_label_role = web-app" "$VARS"
# Голой переменной role больше нет: метки не переопределяют переменные хоста.
expect_no_line "docker-server role = web-app" "$VARS"
# Дефис в ключе метки заменяется на подчёркивание.
expect_line "docker-server yc_label_owner_team = platform" "$VARS"
expect_line "docker-server yc_label_env = prod" "$VARS"
# ansible_host — публичный IP (фикс №1); внутренний остаётся в private_ipv4.
expect_line "docker-server ansible_host = 178.154.248.236" "$VARS"
expect_line "docker-server private_ipv4 = 10.0.0.5" "$VARS"
# ВМ без публичного IP живёт на внутреннем.
expect_line "nexus_server ansible_host = 10.0.0.6" "$(hostvars "$JSON" nexus_server)"
# Публичного адреса нет → ipv4 = None, а не пустая строка: реальный API отдаёт
# "" (protobuf-дефолт), плагин нормализует его в null, как обещано в README.
expect_line "nexus_server ipv4 = None" "$(hostvars "$JSON" nexus_server)"
expect_no_line "nexus_server ipv4 = " "$(hostvars "$JSON" nexus_server)"
# Фикс №6: имя хоста не в зарезервированной переменной name.
expect_line "docker-server yc_name = docker-server" "$VARS"
# Фикс №7: ВМ с меткой ansible=false в inventory не попадает.
expect_not_in "old-test-vm" "$KEYS"
# Группировка: зона + метка ansible_group. Группа из метки создаётся только
# как yc_<значение>, чтобы метка не достала до групп владельца репозитория.
GRAPH="$("$AI" -i "$INV" --graph 2>/dev/null)"
expect_in "@ru_central1_a:" "$GRAPH"
expect_in "@yc_docker:" "$GRAPH"
expect_in "@yc_nexus_server:" "$GRAPH"

echo
echo "=== 1b. Метка ansible_group: недопустимое имя группу не создаёт ==="
ERRF="$TMP/bad_group.err"
JSON="$(FAKE_YC_SCENARIO=bad_group "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
HOSTGROUPS="$(hostgroups "$JSON")"
printf '%s\n' "$ERR"
printf '%s\n' "$HOSTGROUPS"
# Значения меток Yandex Cloud не ограничивает, поэтому мусор в метке — не повод
# терять хост: все ВМ остаются в inventory, пропадает только группа.
expect_line "6" "$(hostcount "$JSON")"
expect_in "'../../evil' недопустимо" "$ERR"
expect_in "'web.dev' недопустимо" "$ERR"
# Имя группы уходит в путь group_vars/<имя>: обход каталога и точки запрещены.
expect_not_in "evil" "$HOSTGROUPS"
expect_not_in "web.dev" "$HOSTGROUPS"
# Дефис нормализуется в `_`, как у зон и ключей меток.
expect_line "yc_web_app web-app-vm" "$HOSTGROUPS"
expect_line "yc_web_servers ok-group-vm" "$HOSTGROUPS"
# Данные не теряются: сырое значение видно в yc_label_ansible_group.
expect_line "slash-vm yc_label_ansible_group = ../../evil" "$(hostvars "$JSON" slash-vm)"
# Значение с готовым префиксом не «умничаем»: получается yc_yc_docker + warning.
expect_in "уже начинается с 'yc_', группа будет 'yc_yc_docker'" "$ERR"
expect_line "yc_yc_docker prefixed-vm" "$HOSTGROUPS"
# Пустое после strip() значение пропускается молча: у ВМ только группа зоны.
expect_line "1" "$(printf '%s\n' "$HOSTGROUPS" | grep -c ' blank-vm$' || true)"

echo
echo "=== 1c. Группа из метки не достаёт до group_vars без префикса ==="
# Свойство безопасности целиком: метка ansible_group: docker больше не приводит
# к применению group_vars/docker.yml (там могли быть секреты или
# ansible_connection: local), а group_vars/yc_docker.yml работает как обычно.
GRP="$TMP/grpvars"
mkdir -p "$GRP/group_vars"
{
    echo "plugin: yandex_cloud_inventory"
    echo "folder_id: b1gfakefolder00000000"
    echo "service_account_key_file: $PWD/tests/fake_sa_key.json"
} >"$GRP/yc_inventory.yml"
printf 'from_yc_group: "yes"\n' >"$GRP/group_vars/yc_docker.yml"
printf 'from_plain_group: "yes"\n' >"$GRP/group_vars/docker.yml"
JSON="$("$AI" -i "$GRP/yc_inventory.yml" --list 2>/dev/null)"
VARS="$(hostvars "$JSON" docker-server)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
expect_line "docker-server from_yc_group = yes" "$VARS"
expect_no_line "docker-server from_plain_group = yes" "$VARS"
expect_not_in "from_plain_group" "$KEYS"

echo
echo "=== 2. ВМ без сетевых интерфейсов: предупреждение, остальные на месте ==="
ERRF="$TMP/no_nic.err"
JSON="$(FAKE_YC_SCENARIO=no_nic "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "нет сетевых интерфейсов" "$ERR"
expect_in "'broken-vm'" "$ERR"
expect_not_in "broken-vm" "$(hostkeys "$JSON")"
expect_line "healthy-vm ansible_host = 178.154.248.99" "$(hostvars "$JSON" healthy-vm)"

echo
echo "=== 3. NIC без IPv4: предупреждение, остальные хосты на месте ==="
ERRF="$TMP/nic_no_v4.err"
JSON="$(FAKE_YC_SCENARIO=nic_no_v4 "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "на первом интерфейсе нет IPv4-адреса" "$ERR"
expect_not_in "nov4-vm" "$(hostkeys "$JSON")"
expect_line "healthy-vm ansible_host = 178.154.248.99" "$(hostvars "$JSON" healthy-vm)"

echo
echo "=== 3b. NIC без адреса в том виде, как его отдаёт реальный API (address='') ==="
ERRF="$TMP/nic_empty_v4.err"
JSON="$(FAKE_YC_SCENARIO=nic_empty_v4 "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "на первом интерфейсе нет IPv4-адреса" "$ERR"
# Главное: хост НЕ должен попасть в inventory с пустым ansible_host.
expect_not_in "nov4-vm" "$(hostkeys "$JSON")"
expect_line "healthy-vm ansible_host = 178.154.248.99" "$(hostvars "$JSON" healthy-vm)"

echo
echo "=== 4. Дефисы в имени ВМ: web-1 и web_1 — два разных хоста ==="
ERRF="$TMP/dashes.err"
JSON="$(FAKE_YC_SCENARIO=dashes "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
# До 3.0 дефис заменялся на `_`, оба имени давали один хост, и одна ВМ
# молча исчезала. Теперь имя хоста — имя ВМ как есть.
expect_line "2" "$(hostcount "$JSON")"
expect_line "web-1 ansible_host = 10.0.7.1" "$(hostvars "$JSON" web-1)"
expect_line "web_1 ansible_host = 10.0.7.2" "$(hostvars "$JSON" web_1)"
expect_line "web-1 yc_name = web-1" "$(hostvars "$JSON" web-1)"
expect_line "web_1 yc_name = web_1" "$(hostvars "$JSON" web_1)"
# Нормализации больше нет: у web_1 не должно быть адреса первой ВМ.
expect_no_line "web_1 ansible_host = 10.0.7.1" "$(hostvars "$JSON" web_1)"
# Никаких предупреждений о коллизии имён быть не должно.
expect_not_in "совпадает имя хоста" "$ERR"
expect_not_in "уже добавлен другой ВМ" "$ERR"
# Каждый хост остаётся в зоне своей ВМ. Зона нормализуется (дефис → `_`).
HOSTGROUPS="$(hostgroups "$JSON")"
printf '%s\n' "$HOSTGROUPS"
expect_line "ru_central1_a web-1" "$HOSTGROUPS"
expect_line "ru_central1_b web_1" "$HOSTGROUPS"
expect_no_line "ru_central1_a web_1" "$HOSTGROUPS"

echo
echo "=== 4b. Дубль имени в ответе API: предупреждение, а не молчаливая перезапись ==="
ERRF="$TMP/dup.err"
JSON="$(FAKE_YC_SCENARIO=dup "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "хост 'dup-vm' уже добавлен другой ВМ" "$ERR"
expect_line "1" "$(hostcount "$JSON")"
# Перезапись видна в данных: остаётся последняя запись, как её отдал API.
expect_line "dup-vm ansible_host = 10.0.8.2" "$(hostvars "$JSON" dup-vm)"

echo
echo "=== 5. Инъекция метками: ansible_host/ansible_ssh_common_args не применяются ==="
ERRF="$TMP/inject.err"
JSON="$(FAKE_YC_SCENARIO=inject "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
VARS="$(hostvars "$JSON" inject-vm)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
printf '%s\n' "$ERR"
# Метка ansible_host не подменяет адрес подключения: остаётся реальный публичный IP.
expect_line "inject-vm ansible_host = 178.154.248.50" "$VARS"
# Метка ansible_ssh_common_args не становится переменной хоста вовсе.
expect_no_line "inject-vm ansible_ssh_common_args" "$KEYS"
# Но данные не потеряны: они лежат под безопасным префиксом.
expect_line "inject-vm yc_label_ansible_host = 203.0.113.99" "$VARS"
expect_line "inject-vm yc_label_ansible_ssh_common_args = -o ProxyCommand=touch /tmp/pwned" "$VARS"
# Пользователь предупреждён по каждому такому ключу.
expect_in "метка 'ansible_host' не применяется как служебная переменная" "$ERR"
expect_in "метка 'ansible_ssh_common_args' не применяется как служебная переменная" "$ERR"
# Белый список работает: ansible_user применяется и дублируется под префиксом.
expect_line "inject-vm ansible_user = deploy" "$VARS"
expect_line "inject-vm yc_label_ansible_user = deploy" "$VARS"
# Контрольная ВМ никуда не пропала.
expect_line "2" "$(hostcount "$JSON")"
expect_line "control-vm ansible_host = 178.154.248.51" "$(hostvars "$JSON" control-vm)"

echo
echo "=== 6. Белый список: ansible_user/ansible_port применяются, ansible_bad_arg — нет ==="
ERRF="$TMP/whitelist.err"
JSON="$(FAKE_YC_SCENARIO=whitelist "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
VARS="$(hostvars "$JSON" wl-vm)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
expect_line "wl-vm ansible_user = deploy" "$VARS"
expect_line "wl-vm ansible_port = 2222" "$VARS"
expect_no_line "wl-vm ansible_bad_arg" "$KEYS"
expect_line "wl-vm yc_label_ansible_bad_arg = x" "$VARS"
expect_in "метка 'ansible_bad_arg' не применяется как служебная переменная" "$ERR"

echo
echo "=== 7. Пагинация: 150 ВМ в двух страницах ==="
JSON="$(FAKE_YC_SCENARIO=paged "$AI" -i "$INV" --list 2>/dev/null)"
echo "    хостов: $(hostcount "$JSON")"
expect_line "150" "$(hostcount "$JSON")"

echo
echo "=== 8. verify_file: чужие yaml не ломаются, myyc не перехвачен ==="
OUT="$("$AI" -i "$PWD/tests/plain_inventory.yml" --list 2>&1)"
expect_in "somehost" "$OUT"
expect_not_in "Incorrect plugin name" "$OUT"
# Имя заканчивается на _yc_inventory.yml: плагин файл забирает, не находит
# plugin: и уступает штатному yaml — хосты должны остаться.
OUT="$("$AI" -vvv -i "$PWD/tests/foreign_yc_inventory.yml" --list 2>&1)"
expect_in "foreignhost" "$OUT"
expect_in "with yaml plugin" "$OUT"
# Разделителя `_` нет — плагин обязан отказаться до разбора файла.
OUT="$("$AI" -vvv -i "$PWD/tests/myyc_inventory.yml" --list 2>&1)"
expect_in "myhost" "$OUT"
expect_in "did not pass its verify_file()" "$OUT"

echo
echo "=== 9. Метка ansible=false в любом регистре (фикс №7) ==="
JSON="$(FAKE_YC_SCENARIO=case_labels "$AI" -i "$INV" --list 2>/dev/null)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$KEYS"
expect_in "stay-vm" "$KEYS"
expect_in "stay-nolabel" "$KEYS"
expect_not_in "skip-lower" "$KEYS"
expect_not_in "skip-upper" "$KEYS"
expect_not_in "skip-title" "$KEYS"

echo
echo "=== 10. Аутентификация: приоритет ключа, YC_IAM_TOKEN, ошибки ==="
# Ключ и токен заданы сразу: SDK должен получить ключ, а не токен.
ERRF="$TMP/auth_sa.err"
FAKE_YC_ECHO_AUTH=1 "$AI" -i "$PWD/tests/auth_sa_yc_inventory.yml" --list >/dev/null 2>"$ERRF"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "FAKE_YC_AUTH service_account_key=fake-key-id iam_token=no" "$ERR"
# Ключа в файле нет — работает токен из YC_IAM_TOKEN.
ERRF="$TMP/auth_env.err"
YC_IAM_TOKEN=fake-iam-token-from-env FAKE_YC_ECHO_AUTH=1 \
    "$AI" -i "$PWD/tests/auth_env_yc_inventory.yml" --list >/dev/null 2>"$ERRF"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "FAKE_YC_AUTH service_account_key=no iam_token=yes" "$ERR"
# Ни ключа, ни токена, ни переменной окружения — понятная ошибка.
# Код возврата не проверяем: ansible-inventory на ошибке разбора источника
# только предупреждает и продолжает с неявным localhost, поэтому проверяем
# сам текст ошибки плагина.
ERR="$(FAKE_YC_ECHO_AUTH=1 "$AI" -i "$PWD/tests/auth_env_yc_inventory.yml" --list 2>&1 >/dev/null)"
printf '%s\n' "$ERR"
expect_in "Either 'service_account_key_file', 'iam_token', or 'YC_IAM_TOKEN' environment variable must be provided" "$ERR"
# Путь к ключу указан, файла нет.
ERR="$("$AI" -i "$PWD/tests/auth_missing_key_yc_inventory.yml" --list 2>&1 >/dev/null)"
printf '%s\n' "$ERR"
expect_in "Service account key file not found: tests/absent_sa_key.json" "$ERR"
# folder_id обязателен: опция объявлена required, Ansible отвергает конфиг
# до вызова parse().
ERR="$("$AI" -i "$PWD/tests/no_folder_yc_inventory.yml" --list 2>&1 >/dev/null)"
printf '%s\n' "$ERR"
expect_in "Required config 'folder_id' for 'yandex_cloud_inventory' inventory plugin not provided" "$ERR"

echo
echo "=== 11. DOCUMENTATION плагина рендерится ansible-doc ==="
# Проверка не косметическая: YAML в DOCUMENTATION легко сделать словарём
# вместо списка (достаточно двоеточия внутри пункта), и ansible-doc падает с
# «expected string or bytes-like object» — при этом ansible-inventory работает,
# поэтому ошибку видно только здесь.
DOC="${AI%/*}/ansible-doc"
[ -x "$DOC" ] || { echo "Нет $DOC — создайте окружение: ./bootstrap.sh" >&2; exit 1; }
# `|| true`: сломанная DOCUMENTATION роняет ansible-doc с ненулевым кодом, а с
# `set -e` скрипт оборвался бы молча вместо читаемого FAIL.
OUT="$("$DOC" -t inventory yandex_cloud_inventory 2>&1 || true)"
printf '%s\n' "$OUT" | head -5
expect_in "INVENTORY yandex_cloud_inventory" "$OUT"
expect_in "The host name is the VM name" "$OUT"
expect_not_in "Unable to retrieve documentation" "$OUT"

echo
if [ "$FAIL" -ne 0 ]; then
    echo "ПРОВАЛЕНО проверок: $FAIL (успешных: $PASS)" >&2
    exit 1
fi
echo "Все проверки пройдены: $PASS"
