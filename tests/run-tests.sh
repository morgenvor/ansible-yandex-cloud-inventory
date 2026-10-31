#!/usr/bin/env bash
# Проверка плагина inventory БЕЗ доступа к облаку.
#
# Подменяет SDK yandexcloud заглушкой (tests/fake_yc) и прогоняет настоящий
# ansible-inventory по сценариям. Нужен только .venv проекта (./bootstrap.sh).
#
# Каждый сценарий содержит утверждения (assert): при регрессе скрипт падает
# с ненулевым кодом и печатает, чего не хватало, — глазами сравнивать не нужно.
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

AI="${ANSIBLE_INVENTORY_BIN:-$PWD/.venv/bin/ansible-inventory}"
INV="$PWD/tests/yc_inventory.yml"

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
# expect_line <строка> <текст> — точное совпадение строки (для счётчиков).
expect_line() {
    if printf '%s\n' "$2" | grep -qxF -- "$1"; then ok "'$1'"; else bad "'$1' (получено: '$2')"; fi
}

echo "=== 1. Обычный каталог: IP, группы, метки, фильтр ansible=false ==="
OUT="$("$AI" -i "$INV" --graph --vars 2>/dev/null)"
printf '%s\n' "$OUT"
expect_in "docker_server" "$OUT"
expect_in "nexus_server" "$OUT"
# ansible_host — публичный IP (фикс №1); внутренний остаётся в private_ipv4.
expect_in "ansible_host = 178.154.248.236" "$OUT"
expect_in "private_ipv4 = 10.0.0.5" "$OUT"
# ВМ без публичного IP живёт на внутреннем.
expect_in "ansible_host = 10.0.0.6" "$OUT"
# Значение метки с дефисом сохраняется (фикс №5)...
expect_in "role = web-app" "$OUT"
# ...а дефис в имени переменной заменяется на подчёркивание.
expect_in "owner_team = platform" "$OUT"
# Фикс №6: имя хоста не в зарезервированной переменной name.
expect_in "yc_name = docker-server" "$OUT"
# Фикс №7: ВМ с меткой ansible=false в inventory не попадает.
expect_not_in "old_test_vm" "$OUT"

echo
echo "=== 2. ВМ без сетевых интерфейсов: предупреждение, остальные на месте ==="
OUT="$(FAKE_YC_SCENARIO=no_nic "$AI" -i "$INV" --graph 2>&1)"
printf '%s\n' "$OUT"
expect_in "WARNING" "$OUT"
expect_in "broken-vm" "$OUT"
expect_in "healthy_vm" "$OUT"

echo
echo "=== 3. Пагинация: 150 ВМ в двух страницах ==="
OUT="$(FAKE_YC_SCENARIO=paged "$AI" -i "$INV" --list 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)['_meta']['hostvars']))")"
echo "    хостов: $OUT"
expect_line "150" "$OUT"

echo
echo "=== 4. Чужой yaml-inventory не перехватывается ==="
OUT="$("$AI" -i "$PWD/tests/plain_inventory.yml" --list 2>&1)"
echo "    совпадений somehost: $(printf '%s' "$OUT" | grep -c somehost || true)"
# Фикс №2: файл не нашего вида обслуживает штатный yaml, а не наш плагин.
expect_in "somehost" "$OUT"
expect_not_in "Incorrect plugin name" "$OUT"

echo
echo "=== 5. Метка ansible=false в любом регистре (фикс №7) ==="
OUT="$(FAKE_YC_SCENARIO=case_labels "$AI" -i "$INV" --graph 2>/dev/null)"
printf '%s\n' "$OUT"
expect_in "stay_vm" "$OUT"
expect_in "stay_nolabel" "$OUT"
expect_not_in "skip_lower" "$OUT"
expect_not_in "skip_upper" "$OUT"
expect_not_in "skip_title" "$OUT"

echo
if [ "$FAIL" -ne 0 ]; then
    echo "ПРОВАЛЕНО проверок: $FAIL (успешных: $PASS)" >&2
    exit 1
fi
echo "Все проверки пройдены: $PASS"