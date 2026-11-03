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
# SC2030/SC2031: каждый «запуск установщика» намеренно изолирован в subshell,
#   чтобы переменные одного запуска не протекали в другой.
# shellcheck disable=SC2016,SC2030,SC2031,SC2317,SC2329
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$SRC/remnanode-setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok()   { printf '✔ %s\n' "$*"; }

[[ -r "$SETUP" ]] || fail "не найден $SETUP"

# Источник истины — lib/*.sh; блоки флагов и env-файла теперь функции,
# тесты вызывают их напрямую, без sed/awk-извлечения.
for f in "$SRC"/lib/*.sh; do
  [[ "$(basename "$f")" == "90-main.sh" ]] && continue
  # shellcheck source=/dev/null
  . "$f"
done
ok()   { printf '✔ %s\n' "$*"; }
# Стабы: вопросы в тесте не задаются, ответ подставляется через ASK_REPLY.
die()  { printf '✖ %s\n' "$*" >&2; exit 1; }
warn() { printf '▲ %s\n' "$*" >&2; }
note() { printf '   %s\n' "$*" >&2; }
ask()  { # ask VAR PROMPT [DEFAULT]
  local __var="$1" __default="${3:-}"
  printf -v "$__var" '%s' "${ASK_REPLY:-$__default}"
}

# --- 1. parse_bool / bool_yn / ask_bool -------------------------------------
ok "функции разбора логических флагов загружены из lib/"

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
ASSUME_YES=0 # в установщике переменная всегда определена; confirm её читает
export ASSUME_YES
if ASK_REPLY='1' confirm 'Продолжаем?' 'n'; then :; else fail "confirm: ответ «1» не считается согласием"; fi
if ASK_REPLY='yes' confirm 'Продолжаем?' 'n'; then :; else fail "confirm: ответ «yes» не считается согласием"; fi
if ASK_REPLY='n' confirm 'Продолжаем?' 'y'; then fail "confirm: ответ «n» считается согласием"; fi
if ASSUME_YES=1 ASK_REPLY='n' confirm 'Продолжаем?' 'n' 2>/dev/null; then :; else fail "confirm: ASSUME_YES=1 не подтверждает автоматически"; fi
ok "confirm: 1/yes/n и ASSUME_YES понимаются одинаково"

# --- 2. Запись /root/remnanode.env и повторный запуск ------------------------
# prompt_flags и write_env_store — функции lib/15-wizard.sh.

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
    printf 'NODE_IMAGE=remnawave/node:3.1.1\n'
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
    prompt_flags
    write_env_store
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
    prompt_flags
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
  [[ "$(stat -c '%a' "$store")" == "600" ]] \
    || fail "env-файл с токенами должен быть 0600, а не $(stat -c '%a' "$store")"
  grep -qx 'export NODE_IMAGE=remnawave/node:3.1.1' "$store" \
    || fail "NODE_IMAGE не сохраняется в env-файл (повторный запуск вернёт latest)"
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
resolve_server_ip_test() { # <SERVER_IP из env> <ответ внешнего сервиса>
  (
    set -Eeuo pipefail
    SERVER_IP="$1"
    CURL_FIXTURE="$2"
    have() { return 0; }
    curl() { printf '%s' "$CURL_FIXTURE"; }
    ok() { :; }
    warn() { :; }
    resolve_server_ip
    printf '%s\n' "$SERVER_IP"
  ) 2>/dev/null | tail -n1
}

got="$(resolve_server_ip_test '203.0.113.10' '198.51.100.7')"
[[ "$got" == '203.0.113.10' ]] || fail "SERVER_IP из env затирается автодетектом: $got"
got="$(resolve_server_ip_test '' '198.51.100.7')"
[[ "$got" == '198.51.100.7' ]] || fail "без SERVER_IP автодетект не работает: $got"
got="$(resolve_server_ip_test '10.0.0.5' '198.51.100.7')"
[[ "$got" == '198.51.100.7' ]] || fail "приватный SERVER_IP не заменяется публичным адресом: $got"
got="$(resolve_server_ip_test 'not-an-ip' '198.51.100.7')"
[[ "$got" == '198.51.100.7' ]] || fail "невалидный SERVER_IP не заменяется автодетектом: $got"
got="$(resolve_server_ip_test '' '')"
[[ -z "$got" ]] || fail "при недоступном автодетекте SERVER_IP должен остаться пустым: $got"
ok "SERVER_IP: значение из env приоритетнее автодетекта, приватный адрес заменяется"

# --- 4. Порт ноды не должен совпадать с портами схемы -----------------------
# CDN-порты (сайт CDN-хоста и его инбаунды) объявлены константами, и проверка
# занятости обязана их учитывать: иначе Node API займёт порт CDN-инбаунда.
for port in 80 443 9443 10443 10444; do
  is_reserved_node_port "$port" \
    || fail "порт схемы $port не исключён из NODE_API_PORT"
done
for var in CDN_TLS_PORT CDN_WS_PORT CDN_XHTTP_PORT CDN_GRPC_PORT; do
  port="${!var}"
  is_reserved_node_port "$port" \
    || fail "$var ($port) не исключён из NODE_API_PORT (конфликт портов с CDN)"
done
ok "NODE_API_PORT: занятые порты схемы, включая CDN, отвергаются"

# --- 5. Быстрый режим: блок протоколов без вопросов -------------------------
# QUICK_SETUP=1 обязан включать XHTTP и CDN сам: домен CDN — уникальный
# cdn-<6 hex>.<базовый> (без коллизии между несколькими нодами на одном домене),
# пути на свежей установке — случайные, а сохранённые значения (повторный
# запуск, ENV_STORE_LOADED=1) не затираются новыми случайными.
run_quick_flags() {
  (
    set -Eeuo pipefail
    export NONINTERACTIVE=1 QUICK_SETUP=1
    export BASE_DOMAIN=example.com
    export CLOUDFLARE_API_TOKEN=test-token
    export CDN_WS_ENABLED=0 CDN_XHTTP_ENABLED=0 CDN_GRPC_ENABLED=0
    prompt_flags
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$ENABLE_XHTTP" "$ENABLE_CDN" "$XHTTP_SNI" \
      "$XHTTP_PATH" "$CDN_HOST" "$CDN_WS_PATH" "$CDN_TRANSPORT"
  ) 2>/dev/null
}

export XHTTP_SNI='' XHTTP_PATH='' CDN_HOST='' CDN_TRANSPORT=''
export CDN_WS_PATH=/api/v1/stream CDN_XHTTP_PATH=/api/v3/sync/c1 CDN_GRPC_PATH=/api/v4/stream
export ENV_STORE_LOADED=0
quick_out="$(run_quick_flags)" || fail "быстрый режим: блок флагов завершился ошибкой"
quick_out2="$(run_quick_flags)" || fail "быстрый режим (2-я нода): блок флагов завершился ошибкой"
IFS='|' read -r q_xhttp q_cdn q_sni q_path q_host q_wspath q_cdntr <<< "$quick_out"
IFS='|' read -r _ _ _ _ q_host2 _ _ <<< "$quick_out2"
[[ "$q_xhttp" == 1 && "$q_cdn" == 1 ]] \
  || fail "быстрый режим не включил XHTTP/CDN сам: «$quick_out»"
[[ "$q_sni" == "www.gstatic.com" ]] || fail "быстрый режим: SNI не дефолтный: «$q_sni»"
[[ "$q_host" =~ ^cdn-[0-9a-f]{6}\.example\.com$ ]] \
  || fail "быстрый режим: CDN-домен не вида cdn-<hex6>.example.com: «$q_host»"
[[ "$q_host" != "$q_host2" ]] \
  || fail "быстрый режим: две ноды на одном домене получили одинаковый CDN-домен: «$q_host»"
[[ "$q_path" =~ ^/api/v3/sync/[0-9a-f]{8}$ ]] \
  || fail "быстрый режим: путь XHTTP не случайный на свежей установке: «$q_path»"
[[ "$q_wspath" =~ ^/api/v1/[0-9a-f]{8}$ ]] \
  || fail "быстрый режим: путь CDN WS не случайный на свежей установке: «$q_wspath»"
[[ "$q_cdntr" == "ws" ]] || fail "быстрый режим: транспорт CDN по умолчанию не ws: «$q_cdntr»"
export CDN_TRANSPORT=grpc
quick_grpc="$(run_quick_flags)" || fail "быстрый режим: выбор grpc завершился ошибкой"
IFS='|' read -r _ _ _ _ _ _ q_cdntr_grpc <<< "$quick_grpc"
[[ "$q_cdntr_grpc" == "grpc" ]] \
  || fail "быстрый режим: сохранённый CDN_TRANSPORT=grpc не выбран: «$q_cdntr_grpc»"
export CDN_TRANSPORT=''
ok "быстрый режим: XHTTP+CDN, выбор транспорта CDN, уникальный CDN-домен и случайные пути"

export XHTTP_PATH=/custom/sync CDN_HOST=cdn2.example.com ENV_STORE_LOADED=1
export CDN_WS_PATH=/api/v1/stream
quick_out="$(run_quick_flags)" || fail "быстрый режим (повтор): блок флагов завершился ошибкой"
IFS='|' read -r q_xhttp q_cdn q_sni q_path q_host q_wspath q_cdntr <<< "$quick_out"
[[ "$q_path" == "/custom/sync" && "$q_host" == "cdn2.example.com" && "$q_wspath" == "/api/v1/stream" ]] \
  || fail "быстрый режим затёр сохранённые значения при повторном запуске: «$quick_out»"
ok "быстрый режим: сохранённые пути и домен при повторном запуске не меняются"

printf 'все проверки переменных окружения и шага 1 прошли\n'
