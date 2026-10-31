#!/usr/bin/env bash
# Проверка плагина inventory БЕЗ доступа к облаку.
#
# Подменяет SDK yandexcloud заглушкой (tests/fake_yc) и прогоняет настоящий
# ansible-inventory по четырём сценариям. Нужен только .venv проекта.
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

echo "=== 1. Обычный каталог: IP, группы, метки ==="
"$AI" -i "$INV" --graph --vars 2>/dev/null

echo
echo "=== 2. ВМ без сетевых интерфейсов: предупреждение, остальные на месте ==="
FAKE_YC_SCENARIO=no_nic "$AI" -i "$INV" --graph 2>&1 | grep -E "WARNING|healthy_vm" || true

echo
echo "=== 3. Пагинация: 150 ВМ в двух страницах ==="
FAKE_YC_SCENARIO=paged "$AI" -i "$INV" --list 2>/dev/null \
  | python3 -c "import json,sys; h=json.load(sys.stdin)['_meta']['hostvars']; print('хостов:', len(h))"

echo
echo "=== 4. Чужой yaml-inventory не перехватывается ==="
"$AI" -i "$PWD/tests/plain_inventory.yml" --list 2>&1 | grep -c somehost \
  | xargs -I{} echo "хост somehost найден (совпадений: {})"
