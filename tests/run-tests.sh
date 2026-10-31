#!/usr/bin/env bash
# Проверка плагина inventory БЕЗ доступа к облаку.
#
# Подменяет SDK yandexcloud заглушкой (tests/fake_yc) и прогоняет настоящий
# ansible-inventory по сценариям. Нужен только .venv проекта (./bootstrap.sh).
#
# Каждый сценарий содержит утверждения (assert): при регрессе скрипт падает
# с ненулевым кодом и печатает, чего не хватало, — глазами сравнивать не нужно.
# Сейчас: 10 сценариев, 53 проверки.
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
VARS="$(hostvars "$JSON" docker_server)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
# Метка уходит под безопасный префикс, значение с дефисом не портится (фикс №5).
expect_line "docker_server yc_label_role = web-app" "$VARS"
# Голой переменной role больше нет: метки не переопределяют переменные хоста.
expect_no_line "docker_server role = web-app" "$VARS"
# Дефис в ключе метки заменяется на подчёркивание.
expect_line "docker_server yc_label_owner_team = platform" "$VARS"
expect_line "docker_server yc_label_env = prod" "$VARS"
# ansible_host — публичный IP (фикс №1); внутренний остаётся в private_ipv4.
expect_line "docker_server ansible_host = 178.154.248.236" "$VARS"
expect_line "docker_server private_ipv4 = 10.0.0.5" "$VARS"
# ВМ без публичного IP живёт на внутреннем.
expect_line "nexus_server ansible_host = 10.0.0.6" "$(hostvars "$JSON" nexus_server)"
# Фикс №6: имя хоста не в зарезервированной переменной name.
expect_line "docker_server yc_name = docker-server" "$VARS"
# Фикс №7: ВМ с меткой ansible=false в inventory не попадает.
expect_not_in "old_test_vm" "$KEYS"
# Группировка: зона + метка ansible_group (директиву метки сохранили).
GRAPH="$("$AI" -i "$INV" --graph 2>/dev/null)"
expect_in "@ru_central1_a:" "$GRAPH"
expect_in "@docker:" "$GRAPH"

echo
echo "=== 2. ВМ без сетевых интерфейсов: предупреждение, остальные на месте ==="
ERRF="$TMP/no_nic.err"
JSON="$(FAKE_YC_SCENARIO=no_nic "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "нет сетевых интерфейсов" "$ERR"
expect_in "'broken-vm'" "$ERR"
expect_not_in "broken_vm" "$(hostkeys "$JSON")"
expect_line "healthy_vm ansible_host = 178.154.248.99" "$(hostvars "$JSON" healthy_vm)"

echo
echo "=== 3. NIC без IPv4: предупреждение, остальные хосты на месте ==="
ERRF="$TMP/nic_no_v4.err"
JSON="$(FAKE_YC_SCENARIO=nic_no_v4 "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "на первом интерфейсе нет IPv4-адреса" "$ERR"
expect_not_in "nov4_vm" "$(hostkeys "$JSON")"
expect_line "healthy_vm ansible_host = 178.154.248.99" "$(hostvars "$JSON" healthy_vm)"

echo
echo "=== 4. Коллизия имён хостов: web-1 и web_1, предупреждение, один хост ==="
ERRF="$TMP/collide.err"
JSON="$(FAKE_YC_SCENARIO=collide "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
printf '%s\n' "$ERR"
expect_in "у ВМ 'web-1' и 'web_1' совпадает имя хоста 'web_1'" "$ERR"
expect_line "1" "$(hostcount "$JSON")"
# Поведение прежнее: остаётся последняя ВМ (по порядку ответа API).
expect_line "web_1 ansible_host = 10.0.7.2" "$(hostvars "$JSON" web_1)"

echo
echo "=== 5. Инъекция метками: ansible_host/ansible_ssh_common_args не применяются ==="
ERRF="$TMP/inject.err"
JSON="$(FAKE_YC_SCENARIO=inject "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
VARS="$(hostvars "$JSON" inject_vm)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
printf '%s\n' "$ERR"
# Метка ansible_host не подменяет адрес подключения: остаётся реальный публичный IP.
expect_line "inject_vm ansible_host = 178.154.248.50" "$VARS"
# Метка ansible_ssh_common_args не становится переменной хоста вовсе.
expect_no_line "inject_vm ansible_ssh_common_args" "$KEYS"
# Но данные не потеряны: они лежат под безопасным префиксом.
expect_line "inject_vm yc_label_ansible_host = 203.0.113.99" "$VARS"
expect_line "inject_vm yc_label_ansible_ssh_common_args = -o ProxyCommand=touch /tmp/pwned" "$VARS"
# Пользователь предупреждён по каждому такому ключу.
expect_in "метка 'ansible_host' не применяется как служебная переменная" "$ERR"
expect_in "метка 'ansible_ssh_common_args' не применяется как служебная переменная" "$ERR"
# Белый список работает: ansible_user применяется и дублируется под префиксом.
expect_line "inject_vm ansible_user = deploy" "$VARS"
expect_line "inject_vm yc_label_ansible_user = deploy" "$VARS"
# Контрольная ВМ никуда не пропала.
expect_line "2" "$(hostcount "$JSON")"
expect_line "control_vm ansible_host = 178.154.248.51" "$(hostvars "$JSON" control_vm)"

echo
echo "=== 6. Белый список: ansible_user/ansible_port применяются, ansible_bad_arg — нет ==="
ERRF="$TMP/whitelist.err"
JSON="$(FAKE_YC_SCENARIO=whitelist "$AI" -i "$INV" --list 2>"$ERRF")"
ERR="$(cat "$ERRF")"
VARS="$(hostvars "$JSON" wl_vm)"
KEYS="$(hostkeys "$JSON")"
printf '%s\n' "$VARS"
expect_line "wl_vm ansible_user = deploy" "$VARS"
expect_line "wl_vm ansible_port = 2222" "$VARS"
expect_no_line "wl_vm ansible_bad_arg" "$KEYS"
expect_line "wl_vm yc_label_ansible_bad_arg = x" "$VARS"
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
expect_in "stay_vm" "$KEYS"
expect_in "stay_nolabel" "$KEYS"
expect_not_in "skip_lower" "$KEYS"
expect_not_in "skip_upper" "$KEYS"
expect_not_in "skip_title" "$KEYS"

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
if [ "$FAIL" -ne 0 ]; then
    echo "ПРОВАЛЕНО проверок: $FAIL (успешных: $PASS)" >&2
    exit 1
fi
echo "Все проверки пройдены: $PASS"
