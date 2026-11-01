#!/usr/bin/env bash
# Живая проверка 3.0.0 на настоящем каталоге Yandex Cloud — ТОЛЬКО ЧТЕНИЕ.
#
# Зачем отдельно от tests/run-tests.sh: стенд подменяет SDK (tests/fake_yc) и
# поэтому не доказывает две вещи — что плагин говорит с настоящим API и что на
# реальных ВМ с настоящими метками получается ожидаемая адресация групп. Этот
# скрипт проверяет именно это.
#
# Облако он НЕ меняет: только ListInstances через плагин и утверждения по
# полученному inventory. Метки для проверок групп ставит владелец каталога —
# ставить и снимать их вручную, см. docs/upstream-differences.md, §2 и §6.
#
# Запуск:
#   LIVE_INVENTORY=secrets/live_yc_inventory.yml ./tests/live-check.sh
#
# LIVE_PYTHONPATH — только для самопроверки скрипта на заглушке SDK
# (сценарий 12 в tests/run-tests.sh): в обычном запуске пусто, чтобы
# заглушка из tests/fake_yc не подменяла настоящий SDK.
#
# Код возврата: 0 — применимые проверки прошли; 1 — есть FAIL; 2 — нет входа.
set -uo pipefail

cd "$(dirname "$0")/.."

INV="${LIVE_INVENTORY:-}"
if [ -z "$INV" ]; then
    printf 'Укажите конфиг плагина: LIVE_INVENTORY=secrets/live_yc_inventory.yml %s\n' "$0" >&2
    printf 'Конфиг лежит вне git (secrets/) и содержит folder_id и способ аутентификации.\n' >&2
    exit 2
fi
[ -f "$INV" ] || { printf 'Нет файла %s\n' "$INV" >&2; exit 2; }

# Нужен настоящий SDK, поэтому PYTHONPATH из окружения не наследуем: стенд
# подменяет SDK через PYTHONPATH=tests/fake_yc, а живьём это дало бы ложный ok.
export PYTHONPATH="${LIVE_PYTHONPATH:-}"
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
export ANSIBLE_HOME="$PWD/.ansible-home"
export ANSIBLE_LOCAL_TEMP="$ANSIBLE_HOME/tmp"
mkdir -p "$ANSIBLE_LOCAL_TEMP"

AI="${ANSIBLE_INVENTORY_BIN:-$PWD/.venv/bin/ansible-inventory}"
[ -x "$AI" ] || { printf 'Нет %s — создайте окружение: ./bootstrap.sh\n' "$AI" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); printf '    ok: %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '    FAIL: %s\n' "$*" >&2; }
skip() { SKIP=$((SKIP + 1)); printf '    skip: %s\n' "$*"; }
note() { printf '    -- %s\n' "$*"; }

# verdicts <строки «ok текст»/«bad текст»/«skip текст»> — вывод python-проверки.
# Читаем here-string, а не пайп: в пайпе цикл ушёл бы в подоболочку и счётчики
# PASS/FAIL потерялись бы.
verdicts() {
    local kind text
    while IFS=' ' read -r kind text; do
        case "$kind" in
            ok) ok "$text" ;;
            bad) bad "$text" ;;
            skip) skip "$text" ;;
        esac
    done <<< "$1"
}

hostcount() {
    printf '%s' "$1" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["_meta"]["hostvars"]))
'
}
# hostvars <json> <host> — строки «host key = value»; значения Ansible помечает
# unsafe и в JSON отдаёт словарём, поэтому разворачиваем их обратно.
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
# hostkeys <json> — строки «host key» по всем хостам.
hostkeys() {
    printf '%s' "$1" | python3 -c '
import json, sys
for host, data in sorted(json.load(sys.stdin)["_meta"]["hostvars"].items()):
    for key in sorted(data):
        print(f"{host} {key}")
'
}
# hostgroups <json> — строки «group host» по всем группам.
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

echo "=== 1. Инвентарь читается у настоящего API ==="
ERRF="$TMP/list.err"
if ! JSON="$("$AI" -i "$INV" --list 2>"$ERRF")"; then
    bad "ansible-inventory завершился ошибкой"
    sed 's/^/    /' "$ERRF" >&2
    exit 1
fi
ERR="$(cat "$ERRF")"
if [ -z "$JSON" ]; then
    bad "пустой ответ inventory"
    exit 1
fi
N="$(hostcount "$JSON" 2>/dev/null || true)"
# Имя переменной не GROUPS: в bash GROUPS — зарезервированный массив ID групп
# пользователя, присваивание ему игнорируется, и в отчёт попало бы «1000».
GROUP_LIST="$(hostgroups "$JSON" | awk '{print $1}' | sort -u | paste -sd' ' -)"
note "хостов: ${N:-?}; группы: ${GROUP_LIST:-нет}"
if [ -n "$N" ] && [ "$N" -ge 1 ]; then
    ok "каталог отдан API и разобран плагином"
else
    bad "в каталоге нет ни одной ВМ — проверять нечего"
    exit 1
fi

echo
echo "=== 2. Имя хоста = имя ВМ как есть (нет нормализации дефисов) ==="
verdicts "$(printf '%s' "$JSON" | python3 -c '
import json, sys
def unwrap(value):
    # Ansible помечает значения меток unsafe и в JSON отдаёт словарём
    # {"__ansible_unsafe": ...}: без разворота сравнение видит dict, а не строку.
    return value["__ansible_unsafe"] if isinstance(value, dict) and "__ansible_unsafe" in value else value
hostvars = json.load(sys.stdin)["_meta"]["hostvars"]
broken = [(h, unwrap(hostvars[h].get("yc_name"))) for h in sorted(hostvars)
          if str(unwrap(hostvars[h].get("yc_name"))) != h]
dashed = [h for h in sorted(hostvars) if "-" in h]
if broken:
    for host, name in broken:
        print("bad " + host + ": имя хоста не совпадает с yc_name " + repr(name))
else:
    print("ok все %d имён хостов совпадают с именами ВМ" % len(hostvars))
if dashed:
    print("ok с дефисом в имени: " + ", ".join(dashed))
else:
    print("skip в каталоге нет имён с дефисом — нормализация на живых данных не проверена")
')"

echo
echo "=== 3. Адреса: ansible_host и private_ipv4 не пустые ==="
verdicts "$(printf '%s' "$JSON" | python3 -c '
import json, sys
def unwrap(value):
    return value["__ansible_unsafe"] if isinstance(value, dict) and "__ansible_unsafe" in value else value
hostvars = json.load(sys.stdin)["_meta"]["hostvars"]
empty = []
public = 0
for host, data in sorted(hostvars.items()):
    if not unwrap(data.get("ansible_host")):
        empty.append(host)
    if unwrap(data.get("ipv4")):
        public += 1
for host in empty:
    print("bad " + host + ": пустой ansible_host")
if not empty:
    print("ok у всех %d хостов ansible_host заполнен" % len(hostvars))
noipv4 = [h for h, d in hostvars.items() if not unwrap(d.get("ipv4"))]
print("ok с публичным IP: %d, без публичного (ipv4 = None): %d" % (public, len(noipv4)))
')"

echo
echo "=== 4. Имена групп пригодны для пути group_vars/<имя> ==="
verdicts "$(printf '%s' "$JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
groups = [g for g in data if not g.startswith("_") and g not in ("all", "ungrouped")]
forbidden = [g for g in groups if any(c in g for c in "/. ")]
for g in forbidden:
    print("bad группа " + repr(g) + " содержит символы пути — возможен выход за group_vars")
if not forbidden:
    print("ok ни в одном из %d имён групп нет / . и пробелов" % len(groups))
')"

echo
echo "=== 5. Группа из метки только под префиксом yc_ ==="
verdicts "$(printf '%s' "$JSON" | python3 -c '
import json, sys, re
def unwrap(value):
    return value["__ansible_unsafe"] if isinstance(value, dict) and "__ansible_unsafe" in value else value
data = json.load(sys.stdin)
hostvars = data["_meta"]["hostvars"]
host2groups = {}
for group, body in data.items():
    if group.startswith("_"):
        continue
    for host in body.get("hosts") or []:
        host2groups.setdefault(host, set()).add(group)
NAME = re.compile(r"^yc_[A-Za-z0-9][A-Za-z0-9_]{0,62}$")
seen = False
for host in sorted(hostvars):
    if "yc_label_ansible_group" not in hostvars[host]:
        continue
    seen = True
    raw = str(unwrap(hostvars[host].get("yc_label_ansible_group")))
    suffix = raw.strip().replace("-", "_")
    if not raw.strip():
        print(f"ok {host}: пустое значение ansible_group — группа не создаётся")
        continue
    expected = "yc_" + suffix
    if not NAME.match(expected):
        print(f"skip {host}: недопустимое значение {raw!r} — группу создавать нельзя")
        continue
    if expected in host2groups.get(host, set()):
        print(f"ok {host}: в группе {expected}")
    else:
        print(f"bad {host}: нет группы {expected} (метка {raw!r})")
    if suffix in host2groups.get(host, set()):
        print(f"bad {host}: хост попал в группу без префикса {suffix} — метка достаёт до чужих group_vars")
if not seen:
    print("skip ни у одной ВМ нет метки ansible_group — проверки групп неприменимы")
')"

echo
echo "=== 6. Предупреждения про недопустимые значения метки ==="
INVALID="$(printf '%s' "$JSON" | python3 -c '
import json, sys, re
def unwrap(value):
    return value["__ansible_unsafe"] if isinstance(value, dict) and "__ansible_unsafe" in value else value
hostvars = json.load(sys.stdin)["_meta"]["hostvars"]
def label(host):
    return str(unwrap(hostvars[host].get("yc_label_ansible_group")) or "").strip()
print(sum(1 for h in hostvars
          if label(h) and not re.match(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", label(h))))
')"
if [ "${INVALID:-0}" -gt 0 ]; then
    if [[ $ERR == *недопустимо* ]]; then
        ok "недопустимое значение метки сопровождается предупреждением"
    else
        bad "недопустимое значение метки есть, предупреждения нет"
    fi
else
    skip "нет ВМ с недопустимым значением метки — предупреждение не проверить"
fi
DOUBLE="$(printf '%s' "$JSON" | python3 -c '
import json, sys
def unwrap(value):
    return value["__ansible_unsafe"] if isinstance(value, dict) and "__ansible_unsafe" in value else value
hostvars = json.load(sys.stdin)["_meta"]["hostvars"]
print(sum(1 for h in hostvars
          if str(unwrap(hostvars[h].get("yc_label_ansible_group")) or "").strip().startswith("yc_")))
')"
if [ "${DOUBLE:-0}" -gt 0 ]; then
    if [[ $ERR == *"уже начинается с 'yc_'"* ]]; then
        ok "значение с готовым префиксом даёт предупреждение о двойном префиксе"
    else
        bad "значение с готовым префиксом есть, предупреждения о двойном префиксе нет"
    fi
else
    skip "нет ВМ со значением метки, уже начинающимся с yc_"
fi

echo
echo "=== 7. Адресация по имени хоста и по группе из метки ==="
DASHED="$(printf '%s' "$JSON" | python3 -c '
import json, sys
print(next((h for h in sorted(json.load(sys.stdin)["_meta"]["hostvars"]) if "-" in h), ""))
')"
if [ -n "$DASHED" ]; then
    OUT="$("$AI" -i "$INV" --host "$DASHED" 2>/dev/null)"
    [[ $OUT == *yc_name* ]] && ok "--host '$DASHED' находит хост" || bad "--host '$DASHED' хост не нашёл"
    LIM="$("$AI" -i "$INV" --list --limit "$DASHED" 2>/dev/null)"
    CNT="$(hostcount "$LIM" 2>/dev/null || true)"
    [ "${CNT:-0}" = "1" ] && ok "--limit '$DASHED' оставляет ровно один хост" \
        || bad "--limit '$DASHED' дал хостов: ${CNT:-0}"
else
    skip "нет имени с дефисом — --host/--limit по такому имени не проверить"
fi

# Группу берём ту, что действительно получена из метки без префикса: иначе на
# уязвимом плагине в проверку 8 попала бы чужая группа с именем yc_* и проверка
# дала бы ложный ok.
G="$(printf '%s' "$JSON" | python3 -c '
import json, sys, re
def unwrap(value):
    return value["__ansible_unsafe"] if isinstance(value, dict) and "__ansible_unsafe" in value else value
data = json.load(sys.stdin)
hostvars = data["_meta"]["hostvars"]
groups = {g for g in data if not g.startswith("_")}
NAME = re.compile(r"^yc_[A-Za-z0-9][A-Za-z0-9_]{0,62}$")
candidates = []
for host in sorted(hostvars):
    if "yc_label_ansible_group" not in hostvars[host]:
        continue
    raw = str(unwrap(hostvars[host].get("yc_label_ansible_group"))).strip().replace("-", "_")
    if not raw or raw.startswith("yc_"):
        continue
    expected = "yc_" + raw
    if NAME.match(expected):
        candidates.append(expected)
print(next((c for c in candidates if c in groups), ""))
')"
if [ -n "$G" ]; then
    EXPECT="$(hostgroups "$JSON" | awk -v g="$G" '$1 == g' | wc -l | tr -d ' ')"
    CNT="$("$AI" -i "$INV" --list --limit "$G" 2>/dev/null)"
    CNT="$(hostcount "$CNT" 2>/dev/null || true)"
    [ "${CNT:-0}" = "$EXPECT" ] && ok "--limit '$G' даёт $EXPECT хост(ов), как в inventory" \
        || bad "--limit '$G' дал ${CNT:-0} вместо $EXPECT"
else
    skip "нет группы, полученной из метки без префикса — --limit по ней не проверить"
fi

echo
echo "=== 8. group_vars: yc_<группа> применяется, <группа> — нет ==="
# Фикстура строится в TMP симлинком на живой конфиг: содержимое конфига (с
# folder_id) не копируется, а group_vars Ansible ищет рядом с источником.
if [ -z "$G" ]; then
    skip "нет группы, полученной из метки без префикса — наследование group_vars не проверить"
else
    BASE="${G#yc_}"
    HOST="$(hostgroups "$JSON" | awk -v g="$G" '$1 == g {print $2; exit}')"
    mkdir -p "$TMP/grp/group_vars"
    ln -sf "$(cd "$(dirname "$INV")" && pwd)/$(basename "$INV")" "$TMP/grp/yc_inventory.yml"
    printf 'from_yc_group: "yes"\n' >"$TMP/grp/group_vars/$G.yml"
    printf 'from_plain_group: "yes"\n' >"$TMP/grp/group_vars/$BASE.yml"
    JSON2="$("$AI" -i "$TMP/grp/yc_inventory.yml" --list 2>/dev/null)"
    VARS="$(hostvars "$JSON2" "$HOST")"
    [[ $'\n'$VARS$'\n' == *$'\n'"$HOST from_yc_group = yes"$'\n'* ]] \
        && ok "group_vars/$G.yml применился к хосту $HOST" \
        || bad "group_vars/$G.yml не применился к хосту $HOST"
    if [[ $(hostkeys "$JSON2") == *from_plain_group* ]]; then
        bad "сработал group_vars/$BASE.yml — метка снова достаёт до группы без префикса"
    else
        ok "group_vars/$BASE.yml не применился ни к одному хосту"
    fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
    printf 'ПРОВАЛЕНО: %s (ok: %s, skip: %s)\n' "$FAIL" "$PASS" "$SKIP" >&2
    exit 1
fi
printf 'Живые проверки пройдены: ok %s, skip %s\n' "$PASS" "$SKIP"