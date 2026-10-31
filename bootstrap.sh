#!/usr/bin/env bash
# Окружение для проверки плагина (см. tests/run-tests.sh).
#
# Собирает локальный .venv с ansible-core + yandexcloud. venv не переносим
# (абсолютные пути в шебангах), поэтому собирается на той машине, где
# запускается, а не копируется. Идемпотентный: битый .venv пересоздаёт.
#
# Запуск:  ./bootstrap.sh [PYTHON=/usr/bin/python3.14 ./bootstrap.sh]
set -euo pipefail

cd "$(dirname "$0")"
PROJECT="$PWD"
VENV="$PROJECT/.venv"

say() { printf '\n== %s\n' "$*"; }

venv_usable() {
    local sh
    [ -x "$VENV/bin/python" ] || return 1
    sh="$(head -1 "$VENV/bin/ansible-inventory" 2>/dev/null | sed 's/^#!//')"
    [ -n "$sh" ] && [ -x "$sh" ] || return 1
    "$VENV/bin/python" -c 'import yandexcloud, ansible' >/dev/null 2>&1 || return 1
    return 0
}

if [ -d "$VENV" ]; then
    if venv_usable; then
        say "Окружение .venv на месте и работает — оставляю как есть"
    else
        say "Существующее .venv не запускается (абсолютные пути / другой Python) — пересоздаю"
        case "$(realpath "$VENV")" in
            "$PROJECT"/.venv) rm -rf "$VENV" ;;
            *) echo "Отказ: $VENV вне проекта, удалять не буду" >&2; exit 1 ;;
        esac
    fi
fi

# ansible-core 2.19 требует Python >= 3.11.
check_pyver() {
    local cmd="$1" ver
    ver="$("$cmd" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0.0)"
    if [ "$(printf '%s\n3.11\n' "$ver" | sort -V | head -1)" != "3.11" ]; then
        echo "Ошибка: $cmd — это Python $ver, а нужен 3.11+." >&2
        echo "Варианты: поставить uv (сам скачает Python) или PYTHON=/usr/bin/python3.14 ./bootstrap.sh" >&2
        exit 1
    fi
}

if [ ! -d "$VENV" ]; then
    PY="${PYTHON:-python3}"
    if command -v uv >/dev/null 2>&1; then
        if [ -n "${PYTHON:-}" ]; then
            say "Создаю .venv через uv из $PYTHON"
            check_pyver "$PY"
        else
            say "Создаю .venv через uv (Python 3.11)"
        fi
        uv venv --python "${PYTHON:-3.11}" "$VENV"
    else
        say "uv не найден, создаю .venv через $PY -m venv"
        check_pyver "$PY"
        "$PY" -m venv "$VENV" || {
            echo "Подсказка: на Ubuntu модуль venv ставится пакетом python3-venv" >&2
            exit 1
        }
    fi
fi

say "Ставлю ansible-core и yandexcloud из requirements-test.txt"
if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$VENV/bin/python" -r "$PROJECT/requirements-test.txt"
else
    "$VENV/bin/python" -m pip install --upgrade pip >/dev/null
    "$VENV/bin/python" -m pip install -r "$PROJECT/requirements-test.txt"
fi

cat <<EOF

Готово. Проверка плагина без облака:

  ./tests/run-tests.sh
EOF
