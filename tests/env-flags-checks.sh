#!/usr/bin/env bash
# Юнит-проверки разбора логических переменных окружения (ENABLE_XHTTP,
# ENABLE_CDN), записи /root/remnanode.env и приоритета SERVER_IP.
#
# Проверки ловят регрессии, которые уже случались:
#   * `ENABLE_CDN=1` — ровно то, что установщик сам писал в env-файл, — молча
#     выключало CDN: флаг сравнивался только с префиксом «y»;
#   * ответ «n» на вопрос про XHTTP не сохранялся, поэтому повторный запуск
#     включал XHTTP обратно по дефолту;
#   * мусор в переменной трактовался как «нет» (функция выключалась незаметно);
#   * `SERVER_IP` из env затирался автодетектом, хотя README обещает обратное.
#
# Фрагменты установщика извлекаются по тем же маркерам, что видит читатель
# файла, поэтому переименование шага или разъезд с кодом ломают CI, а не сервер.
#
# SC2016: ищем в установщике фрагменты shell-кода, поэтому одинарные кавычки с
#   `$VAR` намеренны (grep -F/-q по литералам, а не подстановка).
# SC2317 (shellcheck <= 0.10) и SC2329 (переименован в 0.11): заглушки внешних
#   команд (have/ok/warn) вызываются кодом установщика, который подключается
#   ниже, — shellcheck считает их недостижимыми и не может увидеть вызовы.
# shellcheck disable=SC2016,SC2317,SC2329
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$SRC/remnanode-setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok()   { printf '✔ %s\n' "$*"; }

[[ -r "$SETUP" ]] || fail "не найден $SETUP"

extract() { # extract <имя функции> → файл с её телом
  local fn="$1"
  sed -n "/^${fn}() {\$/,/^}\$/p" "$SETUP" > "$WORK/$fn.sh"
  grep -q "^${fn}() {" "$WORK/$fn.sh" || fail "не удалось извлечь $fn из установщика"
  grep -q '^}$' "$WORK/$fn.sh" || fail "тело $fn обрезано (нет закрывающей скобки)"
}

# Стабы: вопросы в тесте не задаются, ответ подставляется через ASK_REPLY —
# так проверяется именно нормализация, а не диалог.
die()  { printf '✖ %s\n' "$*" >&2; exit 1; }
warn() { printf '▲ %s\n' "$*" >&2; }
note() { printf '   %s\n' "$*" >&2; }
ask()  { # ask VAR PROMPT [DEFAULT]; как настоящий ask, но ответ из ASK_REPLY
  local __var="$1" __default="${3:-}"
  printf -v "$__var" '%s' "${ASK_REPLY:-$__default}"
}

# --- 1. parse_bool / bool_yn / ask_bool -------------------------------------
for fn in parse_bool bool_yn ask_bool; do
  extract "$fn"
  # shellcheck source=/dev/null
  . "$WORK/$fn.sh"
done
ok "функции разбора логических флагов извлечены из установщика"

# Все написания, которые встречаются в env, в env-файле прежних версий и в
# ответах пользователя, должны пониматься одинаково.
for spec in 'y:1' 'Y:1' 'yes:1' 'YES:1' 'true:1' 'on:1' '1:1' \
            'n:0' 'N:0' 'no:0' 'false:0' 'off:0' '0:0'; do
  val="${spec%%:*}"
  expect="${spec#*:}"
  got="$(parse_bool "$val" 0)"
  [[ "$got" == "$expect" ]] || fail "parse_bool '$val' → «$got», ожидалось «$expect»"
done
[[ "$(parse_bool '' 0)" == 0 && "$(parse_bool '' 1)" == 1 ]] \
  || fail "parse_bool: пустое значение должно давать дефолт"
[[ "$(parse_bool 'не-булево' 1)" == 1 ]] || fail "parse_bool: мусор должен давать дефолт (1)"
[[ "$(parse_bool 'не-булево' 0)" == 0 ]] || fail "parse_bool: мусор должен давать дефолт (0)"
[[ "$(bool_yn 1)" == y && "$(bool_yn 0)" == n ]] || fail "bool_yn: 1→y, 0→n"
ok "parse_bool: y/yes/true/on/1 → 1, n/no/false/off/0 → 0, мусор → дефолт"

# Значение из env (в том числе «1» из env-файла прежних версий) должно
# становиться дефолтом вопроса, а не теряться.
ASK_REPLY='' ask_bool ENABLE_CDN 'Добавить VLESS за CDN?' '1'
[[ "$ENABLE_CDN" == 1 ]] || fail "ENABLE_CDN=1 из env выключает CDN (получено $ENABLE_CDN)"
ASK_REPLY='' ask_bool ENABLE_XHTTP 'Включить XHTTP?' '0'
[[ "$ENABLE_XHTTP" == 0 ]] || fail "ENABLE_XHTTP=0 из env включает XHTTP (получено $ENABLE_XHTTP)"
ASK_REPLY='1' ask_bool ENABLE_XHTTP 'Включить XHTTP?' 'n'
[[ "$ENABLE_XHTTP" == 1 ]] || fail "ответ «1» не считается согласием (получено $ENABLE_XHTTP)"
ASK_REPLY='N' ask_bool ENABLE_CDN 'Добавить VLESS за CDN?' 'y'
[[ "$ENABLE_CDN" == 0 ]] || fail "ответ «N» не считается отказом (получено $ENABLE_CDN)"
ok "ask_bool: значение из env нормализуется, ответы 1/N понимаются"

# Мусорный ответ не должен молча выключать функцию: переспрашиваем и в итоге
# останавливаемся с понятной ошибкой.
if ( ASK_REPLY='может быть' ask_bool ENABLE_CDN 'Добавить VLESS за CDN?' 'y' ) \
     > "$WORK/junk-out" 2> "$WORK/junk-err"; then
  fail "мусорный ответ принят как решение"
fi
grep -q 'не похож на y/n' "$WORK/junk-err" \
  || fail "нет предупреждения о непонятном ответе: $(cat "$WORK/junk-err")"
grep -q 'нужен y или n' "$WORK/junk-err" \
  || fail "нет итоговой ошибки с подсказкой про y/n: $(cat "$WORK/junk-err")"
ok "ask_bool: мусорный ответ переспрашивается, затем установка останавливается"

# confirm: тот же разбор ответа, что у флагов. Раньше «1» и «yes» в ответ на
# «Всё верно, продолжаем?» читались по-разному, а мусор молча значил «нет».
extract confirm
ASSUME_YES=0 # в установщике переменная всегда определена; confirm её читает
export ASSUME_YES
# shellcheck source=/dev/null
. "$WORK/confirm.sh"
if ASK_REPLY='1' confirm 'Продолжаем?' 'n'; then :; else fail "confirm: ответ «1» не считается согласием"; fi
if ASK_REPLY='yes' confirm 'Продолжаем?' 'n'; then :; else fail "confirm: ответ «yes» не считается согласием"; fi
if ASK_REPLY='n' confirm 'Продолжаем?' 'y'; then fail "confirm: ответ «n» считается согласием"; fi
if ASSUME_YES=1 ASK_REPLY='n' confirm 'Продолжаем?' 'n' 2>/dev/null; then :; else fail "confirm: ASSUME_YES=1 не подтверждает автоматически"; fi
ok "confirm: 1/yes/n и ASSUME_YES понимаются одинаково"

# --- 2. Запись /root/remnanode.env и повторный запуск ------------------------
# Извлекаем ровно те фрагменты установщика, которые читают ответы шага 1 и
# пишут env-файл: сначала разбор флагов, затем блок записи.
sed -n '/^ask_bool ENABLE_XHTTP/,/^ask PANEL_IP /p' "$SETUP" | sed '$d' > "$WORK/flags.sh"
grep -q 'ask_bool ENABLE_CDN' "$WORK/flags.sh" || fail "не удалось извлечь разбор флагов из установщика"
grep -q 'ask_bool ENABLE_XHTTP' "$WORK/flags.sh" || fail "в извлечённом фрагменте нет разбора XHTTP"
awk '/^\( umask 077$/,/^\)$/' "$SETUP" > "$WORK/env-store.sh"
grep -qF 'export ENABLE_CDN=' "$WORK/env-store.sh" || fail "не удалось извлечь запись env-файла"
grep -qF '} > "$ENV_STORE"' "$WORK/env-store.sh" \
  || fail "извлечённый блок записи env-файла не пишет в ENV_STORE"
for fn in ask ask_secret cdn_transport_enabled bool_yn parse_bool; do
  extract "$fn"
done

# first_run_values <ENABLE_XHTTP|«-» = не задано> <ENABLE_CDN|«-»> <файл>
# Значения, которые шаг 1 установщика получает от предыдущих шагов. Пишутся
# файлом: их читает подключаемый код установщика, а не сам тест.
first_run_values() {
  local xhttp="$1" cdn="$2"
  {
    printf 'BASE_DOMAIN=example.com\n'
    printf 'PREFIX=usa\n'
    printf 'VLESS_HOST=usa1.example.com\n'
    printf 'HY_HOST=usa3.example.com\n'
    printf 'ACME_EMAIL=admin@example.com\n'
    printf 'SELF_STEAL_HOST=usa1.example.com\n'
    printf 'VISION_SNI=usa1.example.com\n'
    printf 'SERVER_IP=203.0.113.10\n'
    printf 'PANEL_IP=203.0.113.10\n'
    printf 'NODE_API_PORT=2222\n'
    printf 'CLOUDFLARE_API_TOKEN=test-token\n'
    printf 'NONINTERACTIVE=1\n'
    printf 'CDN_HOST=cdn.example.com\n'
    printf 'CDN_TRANSPORT=ws\n'
    # Пустые значения: установщик должен взять дефолты из констант.
    printf 'XHTTP_SNI=\nXHTTP_PATH=\nCDN_WS_PATH=\nCDN_XHTTP_PATH=\nCDN_GRPC_PATH=\n'
    printf 'ENV_STORE=%q\n' "$3"
    [[ "$xhttp" == - ]] || printf 'ENABLE_XHTTP=%q\n' "$xhttp"
    [[ "$cdn" == - ]] || printf 'ENABLE_CDN=%q\n' "$cdn"
    :
  } > "$4"
}

# run_install <файл значений> — первый запуск: значения → разбор шага 1 → env-файл.
run_install() {
  (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    . "$1"
    # shellcheck source=/dev/null
    . "$WORK/ask.sh"
    # shellcheck source=/dev/null
    . "$WORK/cdn_transport_enabled.sh"
    # shellcheck source=/dev/null
    . "$WORK/flags.sh"
    # shellcheck source=/dev/null
    . "$WORK/bool_yn.sh"
    # shellcheck source=/dev/null
    . "$WORK/env-store.sh"
  ) > "$WORK/install-out" 2>&1 || fail "первый запуск не удался: $(tail -n3 "$WORK/install-out")"
}

# read_flags <env-файл> → «ENABLE_XHTTP|ENABLE_CDN|XHTTP_SNI|XHTTP_PATH»
# Второй запуск: файл подхватывается, вопросы получают готовые ответы.
read_flags() {
  (
    set -Eeuo pipefail
    export NONINTERACTIVE=1
    export CLOUDFLARE_API_TOKEN=test-token
    # Флаги и CDN-переменные намеренно не задаём: проверяем именно env-файл.
    # shellcheck source=/dev/null
    . "$1"
    # shellcheck source=/dev/null
    . "$WORK/ask.sh"
    # shellcheck source=/dev/null
    . "$WORK/cdn_transport_enabled.sh"
    # shellcheck source=/dev/null
    . "$WORK/flags.sh"
    printf '%s|%s|%s|%s\n' "$ENABLE_XHTTP" "$ENABLE_CDN" "${XHTTP_SNI:-}" "${XHTTP_PATH:-}"
  ) 2>/dev/null | tail -n1
}

# Спека: «вход XHTTP : вход CDN : флаг в файле XHTTP : флаг в файле CDN :
#         решение XHTTP : решение CDN : SNI : path».
# «-» на входе означает «переменная не задана» — установщик берёт дефолт.
checked=0
for spec in \
  'y:y:y:y:1:1:www.gstatic.com:/api/v3/sync/r1' \
  '1:1:y:y:1:1:www.gstatic.com:/api/v3/sync/r1' \
  'yes:on:y:y:1:1:www.gstatic.com:/api/v3/sync/r1' \
  'true:no:y:n:1:0:www.gstatic.com:/api/v3/sync/r1' \
  '-:-:y:n:1:0:www.gstatic.com:/api/v3/sync/r1' \
  'n:y:n:y:0:1::' \
  'n:n:n:n:0:0::' \
  '0:off:n:n:0:0::' \
  'N:0:n:n:0:0::'; do
  IFS=: read -r in_xhttp in_cdn file_xhttp file_cdn out_xhttp out_cdn out_sni out_path <<< "$spec"
  store="$WORK/store-$in_xhttp-$in_cdn.env"
  first_run_values "$in_xhttp" "$in_cdn" "$store" "$store.input"
  run_install "$store.input"
  grep -qx "export ENABLE_XHTTP=$file_xhttp" "$store" \
    || fail "при входе $in_xhttp/$in_cdn в env-файле нет ENABLE_XHTTP=$file_xhttp"
  grep -qx "export ENABLE_CDN=$file_cdn" "$store" \
    || fail "при входе $in_xhttp/$in_cdn в env-файле нет ENABLE_CDN=$file_cdn"
  if [[ "$file_xhttp" == n ]] && grep -q 'XHTTP_SNI' "$store"; then
    fail "выключенный XHTTP оставил в env-файле XHTTP_SNI"
  fi
  read_out="$(read_flags "$store")"
  [[ "$read_out" == "$out_xhttp|$out_cdn|$out_sni|$out_path" ]] \
    || fail "при входе $in_xhttp/$in_cdn повторный запуск дал «$read_out», ожидалось «$out_xhttp|$out_cdn|$out_sni|$out_path»"
  checked=$((checked + 1))
done
ok "env-файл: $checked наборов вход/файл/повторный запуск совпали (y/n, 1/0, дефолты)"

# env-файл прежних версий писал именно «1» (вместе с флагами — значения CDN):
# такой файл обязан включать CDN, а не выключать его.
printf 'export ENABLE_XHTTP=1\nexport ENABLE_CDN=1\nexport CDN_HOST=cdn.example.com\nexport CDN_TRANSPORT=ws\n' \
  > "$WORK/legacy.env"
[[ "$(read_flags "$WORK/legacy.env")" == '1|1|www.gstatic.com|/api/v3/sync/r1' ]] \
  || fail "env-файл прежних версий (ENABLE_CDN=1) не включает CDN: «$(read_flags "$WORK/legacy.env")»"
ok "совместимость: ENABLE_CDN=1 из старого env-файла по-прежнему включает CDN"

# --- 3. SERVER_IP из env важнее автодетекта ----------------------------------
awk '/^# SERVER_IP нужен для A-записей/,/^ask BASE_DOMAIN /' "$SETUP" | sed '$d' > "$WORK/server-ip.sh"
grep -q 'ifconfig.me' "$WORK/server-ip.sh" || fail "не удалось извлечь блок определения SERVER_IP"
for fn in is_ipv4 is_private_ipv4; do
  extract "$fn"
done
# Внутри проверки подменяем внешние зависимости блока: curl — «ответ внешнего
# сервиса», have — наличие команды; его собственный вывод глушим.
curl() { printf '%s' "${CURL_FIXTURE:-}"; }

resolve_server_ip() { # resolve_server_ip <SERVER_IP из env> <ответ внешнего сервиса>
  (
    set -Eeuo pipefail
    SERVER_IP="$1"
    CURL_FIXTURE="$2"
    have() { command -v "$1" >/dev/null 2>&1; }
    ok() { :; }
    warn() { :; }
    # shellcheck source=/dev/null
    . "$WORK/is_ipv4.sh"
    # shellcheck source=/dev/null
    . "$WORK/is_private_ipv4.sh"
    # shellcheck source=/dev/null
    . "$WORK/server-ip.sh"
    printf '%s\n' "$SERVER_IP"
  ) 2>/dev/null | tail -n1
}

got="$(resolve_server_ip '203.0.113.10' '198.51.100.7')"
[[ "$got" == '203.0.113.10' ]] || fail "SERVER_IP из env затирается автодетектом: $got"
got="$(resolve_server_ip '' '198.51.100.7')"
[[ "$got" == '198.51.100.7' ]] || fail "без SERVER_IP автодетект не работает: $got"
got="$(resolve_server_ip '10.0.0.5' '198.51.100.7')"
[[ "$got" == '198.51.100.7' ]] || fail "приватный SERVER_IP не заменяется публичным адресом: $got"
got="$(resolve_server_ip '' '')"
[[ -z "$got" ]] || fail "при недоступном автодетекте SERVER_IP должен остаться пустым: $got"
ok "SERVER_IP: значение из env приоритетнее автодетекта, приватный адрес заменяется"

# --- 4. Порт ноды не должен совпадать с портами схемы -----------------------
# CDN-порты (сайт CDN-хоста и его инбаунды) объявлены константами, и проверка
# занятости обязана их учитывать: иначе Node API займёт порт CDN-инбаунда.
ports_line="$(sed -n '/^case "\$NODE_API_PORT" in/{n;p;}' "$SETUP")"
[[ -n "$ports_line" ]] || fail "не найдена проверка занятости NODE_API_PORT"
ports_line="${ports_line%)}"
ports_line="${ports_line//\"/}"
IFS='|' read -r -a port_tokens <<< "$ports_line"
for port in 80 443 9443 10443 10444; do
  found=0
  for token in "${port_tokens[@]}"; do
    [[ "${token// /}" == "$port" ]] && found=1
  done
  (( found )) || fail "порт схемы $port не исключён из NODE_API_PORT"
done
for var in CDN_TLS_PORT CDN_WS_PORT CDN_XHTTP_PORT CDN_GRPC_PORT; do
  grep -qF "\$$var" <<< "$ports_line" \
    || fail "$var не исключён из NODE_API_PORT (конфликт портов с CDN)"
done
ok "NODE_API_PORT: занятые порты схемы, включая CDN, отвергаются"

printf 'все проверки переменных окружения и шага 1 прошли\n'
