#!/usr/bin/env bash
# Юнит-проверки чистых функций валидации из remnanode-setup.sh.
# Функции извлекаются из установщика и выполняются здесь, чтобы регрессия
# (например, «висячие» одинарные двоеточия в is_ipv6 или отвергание punycode
# TLD в is_fqdn) ломала CI, а не сервер пользователя.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$SRC/remnanode-setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok()   { printf '✔ %s\n' "$*"; }

[[ -r "$SETUP" ]] || fail "не найден $SETUP"

for fn in is_ipv4 is_ipv6 is_private_ipv4 is_fqdn is_safe_xhttp_path \
           acme_cert_days_left cf_rand_index cf_make_hosts cf_valid_saved_host \
           multiselect_filter cdn_transport_enabled write_config_profile self_steal_template_url \
           self_steal_template_list random_hex gen_random_api_path random_node_port \
           normalize_domain_input normalize_panel_url panel_url_host resolve_ipv4_host; do
  sed -n "/^${fn}() {\$/,/^}\$/p" "$SETUP" > "$WORK/$fn.sh"
  grep -q "^${fn}() {" "$WORK/$fn.sh" || fail "не удалось извлечь $fn из установщика"
  grep -q '^}$' "$WORK/$fn.sh" || fail "тело $fn обрезано (нет закрывающей скобки)"
  # shellcheck source=/dev/null
  . "$WORK/$fn.sh"
done
ok "функции валидации извлечены из установщика"

# Словари генератора случайных хостов Cloudflare (однострочные массивы).
grep -E '^CF_HOST_(ADJ|NOUN)=\(' "$SETUP" > "$WORK/cf-arrays.sh"
grep -q '^CF_HOST_ADJ=(' "$WORK/cf-arrays.sh" || fail "нет словаря CF_HOST_ADJ"
grep -q '^CF_HOST_NOUN=(' "$WORK/cf-arrays.sh" || fail "нет словаря CF_HOST_NOUN"
# shellcheck source=/dev/null
. "$WORK/cf-arrays.sh"
(( ${#CF_HOST_ADJ[@]} >= 16 && ${#CF_HOST_NOUN[@]} >= 16 )) \
  || fail "словари генератора слишком малы: ${#CF_HOST_ADJ[@]}/${#CF_HOST_NOUN[@]}"
ok "словари генератора хостов извлечены (${#CF_HOST_ADJ[@]} прилагательных, ${#CF_HOST_NOUN[@]} существительных)"

expect_valid()   { if ! "$@"; then fail "должно быть валидно: $*"; fi; }
expect_invalid() { if "$@"; then fail "должно быть невалидно: $*"; fi; }

# --- is_ipv4 ---
expect_valid   is_ipv4 '1.2.3.4'
expect_valid   is_ipv4 '10.0.0.1'
expect_valid   is_ipv4 '255.255.255.255'
expect_invalid is_ipv4 '256.1.1.1'
expect_invalid is_ipv4 '1.2.3'
expect_invalid is_ipv4 '1.2.3.4.5'
expect_invalid is_ipv4 'a.b.c.d'
expect_invalid is_ipv4 ''
expect_invalid is_ipv4 '1.2.3.4 '
ok "is_ipv4"

# --- is_ipv6: висячие одинарные двоеточия (регрессия P2-3) ---
expect_valid   is_ipv6 '2001:db8::1'
expect_valid   is_ipv6 '::1'
expect_valid   is_ipv6 '::'
expect_valid   is_ipv6 'fe80::'
expect_valid   is_ipv6 '1::'
expect_valid   is_ipv6 '2001:0db8:0000:0000:0000:0000:0000:0001'
expect_valid   is_ipv6 '::ffff:abcd'
expect_invalid is_ipv6 ':1:2:3:4:5:6:7'
expect_invalid is_ipv6 '1:2:3:4:5:6:7:'
expect_invalid is_ipv6 '1:2:3:4:5:6:7'
expect_invalid is_ipv6 '1:2:3:4:5:6:7:8:9'
expect_invalid is_ipv6 '1::2::3'
expect_invalid is_ipv6 '12345::1'
expect_invalid is_ipv6 'gggg::1'
expect_invalid is_ipv6 ':::'
expect_invalid is_ipv6 '1.2.3.4'
expect_invalid is_ipv6 ''
ok "is_ipv6"

# --- is_private_ipv4: сервер за NAT должен быть предупреждён (P3-4) ---
expect_valid   is_private_ipv4 '10.0.0.1'
expect_valid   is_private_ipv4 '10.255.255.255'
expect_valid   is_private_ipv4 '192.168.1.1'
expect_valid   is_private_ipv4 '172.16.0.1'
expect_valid   is_private_ipv4 '172.31.255.255'
expect_valid   is_private_ipv4 '127.0.0.1'
expect_valid   is_private_ipv4 '169.254.1.1'
expect_valid   is_private_ipv4 '0.0.0.0'
expect_valid   is_private_ipv4 '100.64.0.1'
expect_valid   is_private_ipv4 '100.127.255.255'
expect_invalid is_private_ipv4 '8.8.8.8'
expect_invalid is_private_ipv4 '11.0.0.1'
expect_invalid is_private_ipv4 '172.15.255.255'
expect_invalid is_private_ipv4 '172.32.0.1'
expect_invalid is_private_ipv4 '100.63.0.1'
expect_invalid is_private_ipv4 '100.128.0.1'
expect_invalid is_private_ipv4 '192.169.0.1'
expect_invalid is_private_ipv4 ''
ok "is_private_ipv4"

# --- is_fqdn, включая punycode TLD (регрессия P2-8) ---
expect_valid   is_fqdn 'example.com'
expect_valid   is_fqdn 'usa1.example.co.uk'
expect_valid   is_fqdn 'sub-domain.example.com'
expect_valid   is_fqdn 'example.xn--p1ai'
expect_valid   is_fqdn 'example.com.'
expect_invalid is_fqdn 'example'
expect_invalid is_fqdn 'example.123'
expect_invalid is_fqdn '-bad.example.com'
expect_invalid is_fqdn 'bad-.example.com'
expect_invalid is_fqdn 'bad..example.com'
expect_invalid is_fqdn ''
expect_invalid is_fqdn "$(printf 'a%.0s' {1..64}).example.com"
ok "is_fqdn"

# --- is_safe_xhttp_path ---
expect_valid   is_safe_xhttp_path '/api/v3/sync/r1'
expect_valid   is_safe_xhttp_path '/'
expect_invalid is_safe_xhttp_path 'api/v3'
expect_invalid is_safe_xhttp_path '/path?x=1'
expect_invalid is_safe_xhttp_path ''
expect_invalid is_safe_xhttp_path "$(printf '/a%.0s' {1..1100})"
ok "is_safe_xhttp_path"

# --- Cloudflare: генератор осмысленных случайных хостов (P5-фича) ---
for _ in $(seq 1 60); do
  idx="$(cf_rand_index 7)" || fail "cf_rand_index 7 отказался"
  [[ "$idx" =~ ^[0-6]$ ]] || fail "cf_rand_index 7 выдал $idx"
done
if cf_rand_index 0 >/dev/null 2>&1; then fail "cf_rand_index 0 должен отказаться"; fi
if cf_rand_index abc >/dev/null 2>&1; then fail "cf_rand_index abc должен отказаться"; fi
ok "cf_rand_index"

mapfile -t gen_hosts < <(cf_make_hosts example.com)
(( ${#gen_hosts[@]} == 2 )) || fail "cf_make_hosts выдал ${#gen_hosts[@]} строк вместо 2"
h1="${gen_hosts[0]}"; h2="${gen_hosts[1]}"
[[ "$h1" =~ ^[a-z]+-[a-z]+\.example\.com$ ]] || fail "хост 1 неверного формата: $h1"
[[ "$h2" =~ ^[a-z]+-[a-z]+\.example\.com$ ]] || fail "хост 2 неверного формата: $h2"
[[ "$h1" != "$h2" ]] || fail "хосты совпадают: $h1"
is_fqdn "$h1" || fail "хост 1 не проходит is_fqdn: $h1"
is_fqdn "$h2" || fail "хост 2 не проходит is_fqdn: $h2"
a1="${h1%%-*}"; rest="${h1#*-}"; n1="${rest%%.*}"
a2="${h2%%-*}"; rest="${h2#*-}"; n2="${rest%%.*}"
[[ "$a1" != "$a2" ]] || fail "прилагательные повторяются: $a1"
[[ "$n1" != "$n2" ]] || fail "существительные повторяются: $n1"
in_list() { local w="$1" x; shift; for x in "$@"; do if [[ "$x" == "$w" ]]; then return 0; fi; done; return 1; }
in_list "$a1" "${CF_HOST_ADJ[@]}"  || fail "слово '$a1' не из словаря прилагательных"
in_list "$a2" "${CF_HOST_ADJ[@]}"  || fail "слово '$a2' не из словаря прилагательных"
in_list "$n1" "${CF_HOST_NOUN[@]}" || fail "слово '$n1' не из словаря существительных"
in_list "$n2" "${CF_HOST_NOUN[@]}" || fail "слово '$n2' не из словаря существительных"
ok "cf_make_hosts: два непохожих валидных хоста ($h1 / $h2)"

# cf_valid_saved_host: повторный запуск переиспользует хосты только из
# текущего BASE_DOMAIN (при смене домена старые имена не годятся).
expect_valid   cf_valid_saved_host 'quiet-otter.example.com' 'example.com'
expect_valid   cf_valid_saved_host 'a.b.example.com' 'example.com'
expect_invalid cf_valid_saved_host 'quiet-otter.other.com' 'example.com'
expect_invalid cf_valid_saved_host 'quiet-otter' 'example.com'
expect_invalid cf_valid_saved_host '' 'example.com'
expect_invalid cf_valid_saved_host 'quiet-otter.example.com' ''
ok "cf_valid_saved_host"

# --- Cloudflare: оркестровка cf_setup_hosts на моках API (без сети) ---
# Проверяется реальный порядок действий: зона → свободность имён → создание/
# обновление A-записей DNS-only → ожидание DNS, а также что die срабатывает
# при ошибке API, отсутствии зоны и исчерпании перебора имён. curl подменяется
# моком ПОСЛЕ извлечения функций.
for fn in cf_api cf_json_success cf_json_error cf_curl_cfg_init \
         cf_check_token_zone cf_upsert_a cf_a_exists cf_setup_hosts cf_zone_id_for_host \
         cf_setup_cdn_host; do
  sed -n "/^${fn}() {\$/,/^}\$/p" "$SETUP" > "$WORK/$fn.sh"
  grep -q "^${fn}() {" "$WORK/$fn.sh" || fail "не удалось извлечь $fn из установщика"
  # shellcheck source=/dev/null
  . "$WORK/$fn.sh"
done

# Стабы окружения установщика: вывод, проверка утилит, dig (отвечает текущим
# IP). Функции вывода log/warn/note объявлены здесь, а ok/fail уже есть сверху
# и переопределять их нельзя — shellcheck считает вызовы до позднего
# переопределения ошибкой (SC2218), и вывод кейсов нам всё равно нужен.
log()  { :; }
warn() { :; }
note() { :; }
die()  {
  if [[ -n "${CF_CURL_CFG:-}" && -f "$CF_CURL_CFG" ]]; then rm -f "$CF_CURL_CFG"; fi
  printf 'die: %s\n' "$*" >&2
  exit 1
}
have() { return 0; }
dig()  { printf '%s\n' "$SERVER_IP"; }

CF_MOCK_LOG="$WORK/cf-mock.log"
CF_MOCK_ZONE_FOUND=1
CF_MOCK_ZONE_NAME=example.com
CF_MOCK_ZONE_ERROR=0
CF_MOCK_ALL_TAKEN=0
CF_MOCK_COLLIDE_ONCE=0
CF_MOCK_SAVED_TAKEN=0

cf_api() { # мок Cloudflare API: пишет журнал вызовов, отдаёт канонические ответы
  local method="$1" path="$2" body="${3:-}"
  printf '%s %s %s\n' "$method" "$path" "$body" >> "$CF_MOCK_LOG"
  if [[ "$method" == GET && "$path" == /zones?name=* ]]; then
    if [[ "$CF_MOCK_ZONE_ERROR" == 1 ]]; then
      printf '{"success":false,"errors":[{"message":"мок: нет прав"}]}'
    elif [[ "$CF_MOCK_ZONE_FOUND" == 1 && "$path" == "/zones?name=${CF_MOCK_ZONE_NAME:-example.com}&status=active" ]]; then
      printf '{"success":true,"result":[{"id":"zone123"}]}'
    else
      printf '{"success":true,"result":[]}'
    fi
    return 0
  fi
  if [[ "$method" == GET && "$path" == /zones/zone123/dns_records* ]]; then
    if [[ "$CF_MOCK_ALL_TAKEN" == 1 ]]; then
      printf '{"success":true,"result":[{"id":"taken"}]}'
      return 0
    fi
    if [[ "$CF_MOCK_COLLIDE_ONCE" == 1 && ! -f "$WORK/cf-mock-collided" ]]; then
      : > "$WORK/cf-mock-collided"
      printf '{"success":true,"result":[{"id":"taken"}]}'
      return 0
    fi
    if [[ "$CF_MOCK_SAVED_TAKEN" == 1 && "$path" == *name=quiet-otter.example.com* ]]; then
      printf '{"success":true,"result":[{"id":"old-rec"}]}'
      return 0
    fi
    printf '{"success":true,"result":[]}'
    return 0
  fi
  if [[ "$method" == POST || "$method" == PUT ]]; then
    printf '{"success":true,"result":{"id":"new-rec"}}'
    return 0
  fi
  printf '{"success":false,"errors":[{"message":"мок: неожиданный вызов %s %s"}]}' "$method" "$path"
}

# Быстрая автоустановка должна отличать неверный токен от отсутствующей зоны,
# чтобы повторно запросить соответственно токен или домен. Проверяем cleanup.
CF_MOCK_ZONE_FOUND=1
CF_MOCK_ZONE_ERROR=0
BASE_DOMAIN=example.com
CLOUDFLARE_API_TOKEN=mock-token-123
CF_CURL_CFG=""
cf_check_token_zone || fail "cf_check_token_zone: валидный токен/зона не прошли проверку"
[[ -z "$CF_CURL_CFG" ]] || fail "cf_check_token_zone: временный файл токена не удалён"
CF_MOCK_ZONE_ERROR=1
if cf_check_token_zone; then fail "cf_check_token_zone: принял ответ API с ошибкой"; else [[ "$?" == 1 ]] || fail "ошибка API должна давать статус 1"; fi
CF_MOCK_ZONE_ERROR=0
CF_MOCK_ZONE_FOUND=0
if cf_check_token_zone; then fail "cf_check_token_zone: принял отсутствующую зону"; else [[ "$?" == 2 ]] || fail "отсутствующая зона должна давать статус 2"; fi
CF_MOCK_ZONE_FOUND=1
ok "cf_check_token_zone: успех, ошибка токена/API и отсутствующая зона различаются"

# Переменные «окружения установщика»: их читает извлечённая cf_setup_hosts.
export BASE_DOMAIN=example.com
export SERVER_IP=203.0.113.10
export CLOUDFLARE_API_TOKEN=mock-token-123

# Случай 1: свежая генерация. Первая попадание имени занята — должен поменять
# имя, и создаться ровно две DNS-only записи с текущим IP.
unset VLESS_HOST HY_HOST
: > "$CF_MOCK_LOG"
rm -f "$WORK/cf-mock-collided"
CF_MOCK_ZONE_FOUND=1 CF_MOCK_ZONE_ERROR=0 CF_MOCK_ALL_TAKEN=0
CF_MOCK_COLLIDE_ONCE=1 CF_MOCK_SAVED_TAKEN=0
cf_setup_hosts
[[ "$VLESS_HOST" =~ ^[a-z]+-[a-z]+\.example\.com$ ]] || fail "сгенерированный VLESS_HOST неверного формата: ${VLESS_HOST:-пусто}"
[[ "$HY_HOST" =~ ^[a-z]+-[a-z]+\.example\.com$ ]] || fail "сгенерированный HY_HOST неверного формата: ${HY_HOST:-пусто}"
[[ "$VLESS_HOST" != "$HY_HOST" ]] || fail "генератор выдал одинаковые хосты: $VLESS_HOST"
[[ "$(grep -c '^POST ' "$CF_MOCK_LOG")" == 2 ]] || fail "ожидалось два POST (создание), получено: $(grep -c '^POST ' "$CF_MOCK_LOG")"
grep -q '"proxied":false' "$CF_MOCK_LOG" || fail "запись создаётся не в режиме DNS-only"
grep -qF "$SERVER_IP" "$CF_MOCK_LOG" || fail "в записи не текущий IP ноды"
[[ -f "$WORK/cf-mock-collided" ]] || fail "перебор занятого имени не срабатывал"
[[ -z "$CF_CURL_CFG" ]] || fail "CF_CURL_CFG не очищен после успешной работы"
ok "cf_setup_hosts: свежая генерация, обход занятого имени, две DNS-only записи"

# Случай 2: сохранённые хосты переиспользуются, чужая генерация не нужна —
# существующая запись обновляется (PUT), вторая создаётся (POST).
VLESS_HOST=quiet-otter.example.com
HY_HOST=brisk-lantern.example.com
: > "$CF_MOCK_LOG"
rm -f "$WORK/cf-mock-collided"
CF_MOCK_COLLIDE_ONCE=0 CF_MOCK_SAVED_TAKEN=1
cf_setup_hosts
[[ "$VLESS_HOST" == quiet-otter.example.com ]] || fail "сохранённый хост затёрся: $VLESS_HOST"
grep -q '^PUT /zones/zone123/dns_records/old-rec ' "$CF_MOCK_LOG" || fail "существующая запись не обновилась (нет PUT)"
grep -q '^POST ' "$CF_MOCK_LOG" || fail "вторая запись не создалась (нет POST)"
[[ "$(grep -c '^GET /zones/zone123/dns_records' "$CF_MOCK_LOG")" == 2 ]] \
  || fail "с сохранёнными хостами лишние проверки занятости (генерация не должна вызываться)"
ok "cf_setup_hosts: сохранённые хосты переиспользованы, записи обновлены"

# Случай 3: зона не найдена токеном → понятная остановка.
CF_MOCK_ZONE_FOUND=0
if ( cf_setup_hosts ) 2>"$WORK/cf-err-zone"; then
  fail "отсутствие зоны не остановило установку"
fi
grep -q 'не видит зону example.com' "$WORK/cf-err-zone" \
  || fail "нет понятной ошибки про зону: $(cat "$WORK/cf-err-zone")"
CF_MOCK_ZONE_FOUND=1
ok "cf_setup_hosts: ненайденная зона → die с правами/CLOUDFLARE_ZONE в подсказке"

# Случай 4: ошибка API (нет прав) → сообщение самой ошибки доходит до пользователя.
CF_MOCK_ZONE_ERROR=1
if ( cf_setup_hosts ) 2>"$WORK/cf-err-api"; then
  fail "ошибка API не остановила установку"
fi
grep -qF 'Cloudflare API (зоны): мок: нет прав' "$WORK/cf-err-api" \
  || fail "сообщение ошибки API потерялось: $(cat "$WORK/cf-err-api")"
CF_MOCK_ZONE_ERROR=0
ok "cf_setup_hosts: ошибка API доходит до пользователя"

# Случай 5: все имена заняты → перебор исчерпан с явной ошибкой.
unset VLESS_HOST HY_HOST
CF_MOCK_ALL_TAKEN=1
if ( cf_setup_hosts ) 2>"$WORK/cf-err-taken"; then
  fail "исчерпание перебора имён не остановило установку"
fi
grep -q 'Не удалось подобрать свободные' "$WORK/cf-err-taken" \
  || fail "нет ошибки исчерпания перебора: $(cat "$WORK/cf-err-taken")"
CF_MOCK_ALL_TAKEN=0
ok "cf_setup_hosts: занятая зона → явная ошибка после 5 попыток"

# Случай 6: запись CDN-хоста создаётся проксируемой (оранжевое облако) — иначе
# трафик не пошёл бы через CDN, а постучался прямо в ноду.
: > "$CF_MOCK_LOG"
cf_curl_cfg_init
cf_upsert_a zone123 cdn.example.com proxied
grep -q '"proxied":true' "$CF_MOCK_LOG" || fail "запись CDN-хоста создаётся без proxied:true"
grep -qF 'cdn.example.com' "$CF_MOCK_LOG" || fail "в записи нет CDN-хоста"
rm -f "$CF_CURL_CFG"
CF_CURL_CFG=""
ok "cf_upsert_a: CDN-хост создаётся проксируемым (proxied=on)"

# Случай 7 (регрессия «не создаёт домен для CDN»): cf_setup_hosts не
# вызывался (CF_MODE=n, хосты VLESS/Hysteria2 созданы вручную), токен
# задан только ради CDN. Проксируемая запись обязана создаться, а зона —
# найтись перебором суффиксов CDN-хоста.
export CDN_HOST=cdn.example.com
export CF_ZONE_ID="" CF_ZONE_NAME="" CDN_DNS_MANAGED=""
CF_MOCK_ZONE_FOUND=1 CF_MOCK_ZONE_ERROR=0 CF_MOCK_ALL_TAKEN=0
CF_MOCK_COLLIDE_ONCE=0 CF_MOCK_SAVED_TAKEN=0 CF_MOCK_ZONE_NAME=example.com
: > "$CF_MOCK_LOG"
cf_setup_cdn_host
[[ "$CDN_DNS_MANAGED" == cloudflare ]] || fail "CDN-запись без CF_MODE не помечена созданной (CDN_DNS_MANAGED=$CDN_DNS_MANAGED)"
[[ "$(grep -c '^POST ' "$CF_MOCK_LOG")" == 1 ]] || fail "ожидался ровно один POST (CDN-запись), журнал: $(cat "$CF_MOCK_LOG")"
grep -q '"proxied":true' "$CF_MOCK_LOG" || fail "CDN-запись без CF_MODE создаётся без proxied:true"
grep -q '^GET /zones?name=example.com&status=active' "$CF_MOCK_LOG" \
  || fail "зона CDN-хоста не искалась суффиксами, журнал: $(cat "$CF_MOCK_LOG")"
[[ -z "$CF_CURL_CFG" ]] || fail "CF_CURL_CFG не очищен после cf_setup_cdn_host"
ok "cf_setup_cdn_host: запись создаётся без CF_MODE, зона найдена суффиксами хоста"

# Случай 8: зона, уже найденная cf_setup_hosts, переиспользуется —
# повторных запросов /zones не нужно.
CF_ZONE_ID=zone123 CF_ZONE_NAME=example.com
: > "$CF_MOCK_LOG"
cf_setup_cdn_host
[[ "$CDN_DNS_MANAGED" == cloudflare ]] || fail "переиспользование зоны не помечено созданной записью"
if grep -q '^GET /zones?' "$CF_MOCK_LOG"; then
  fail "при готовой зоне выполнен лишний поиск /zones: $(cat "$CF_MOCK_LOG")"
fi
[[ "$(grep -c '^POST ' "$CF_MOCK_LOG")" == 1 ]] || fail "при готовой зоне запись CDN не создалась: $(cat "$CF_MOCK_LOG")"
ok "cf_setup_cdn_host: зона cf_setup_hosts переиспользуется без поиска"

# Случай 9: CDN-хост в другой зоне, чем BASE_DOMAIN: готовая зона не
# подходит, нужна своя — запись должна уйти в зону CDN-хоста.
CDN_HOST=cdn.other.org CF_MOCK_ZONE_NAME=other.org
: > "$CF_MOCK_LOG"
cf_setup_cdn_host
[[ "$CDN_DNS_MANAGED" == cloudflare ]] || fail "CDN-хост в чужой зоне не помечен созданным"
grep -q '^GET /zones?name=other.org&status=active' "$CF_MOCK_LOG" \
  || fail "зона CDN-хоста other.org не искалась: $(cat "$CF_MOCK_LOG")"
grep -qF 'cdn.other.org' "$CF_MOCK_LOG" || fail "в запросах нет CDN-хоста другой зоны"
CDN_HOST=cdn.example.com CF_MOCK_ZONE_NAME=example.com
ok "cf_setup_cdn_host: CDN-хост в другой зоне получает свою зону"

# Случай 10: токен зону CDN-хоста не видит → установка не падает, но
# результат честно manual (пользователь увидит действие в сводке),
# а не тишина, как раньше.
CF_ZONE_ID="" CF_ZONE_NAME="" CF_MOCK_ZONE_FOUND=0
: > "$CF_MOCK_LOG"
cf_setup_cdn_host
[[ "$CDN_DNS_MANAGED" == manual ]] || fail "невидимая зона не помечена manual (получено: $CDN_DNS_MANAGED)"
[[ "$(grep -c '^POST ' "$CF_MOCK_LOG")" == 0 ]] \
  || fail "при невидимой зоне запись всё равно создавалась"
CF_MOCK_ZONE_FOUND=1
ok "cf_setup_cdn_host: невидимая токеном зона → manual без записи"

# Случай 11: явный --no-cloudflare → ни одного вызова API, запись manual.
export CF_MODE_SETTING=0
: > "$CF_MOCK_LOG"
cf_setup_cdn_host
[[ "$CDN_DNS_MANAGED" == manual ]] || fail "--no-cloudflare не помечен manual"
[[ ! -s "$CF_MOCK_LOG" ]] || fail "--no-cloudflare всё равно ходил в API: $(cat "$CF_MOCK_LOG")"
unset CF_MODE_SETTING
ok "cf_setup_cdn_host: --no-cloudflare не трогает Cloudflare API"

# Мастер обязан предлагать CDN-домен сам (Enter — cdn.<базовый домен>),
# а не требовать выдумывать его с пустым дефолтом.
# shellcheck disable=SC2016 # ищем литеральный фрагмент кода установщика, подстановка не нужна
grep -qF 'cdn.${BASE_DOMAIN' "$SETUP" \
  || fail "мастер не предлагает CDN-домен по умолчанию (cdn.<базовый домен>)"
ok "CDN_HOST: по умолчанию предлагается cdn.<BASE_DOMAIN>"

# --- Быстрый режим: нормализация вводов и случайные значения ---------------
# Домен и URL панели люди вставляют «как из браузера»: со схемой, слэшем в
# конце, в верхнем регистре. Мастер обязан приводить это к рабочему виду,
# а не умирать с непонятной ошибкой Cloudflare/панели.
[[ "$(normalize_domain_input 'https://Example.COM/')" == "example.com" ]] \
  || fail "normalize_domain_input: https://Example.COM/ не приведён к example.com"
[[ "$(normalize_domain_input 'example.com.')" == "example.com" ]] \
  || fail "normalize_domain_input: хвостовая точка не срезана"
[[ "$(normalize_domain_input 'www.example.com/path')" == "example.com" ]] \
  || fail "normalize_domain_input: www и путь не срезаны"
[[ "$(normalize_panel_url 'panel.example.com')" == "https://panel.example.com" ]] \
  || fail "normalize_panel_url: без схемы должен добавляться https://"
[[ "$(normalize_panel_url 'https://panel.example.com/')" == "https://panel.example.com" ]] \
  || fail "normalize_panel_url: хвостовой слэш не срезан"
[[ "$(normalize_panel_url 'http://203.0.113.5:3000/')" == "http://203.0.113.5:3000" ]] \
  || fail "normalize_panel_url: http с IP и портом должен сохраняться"
if normalize_panel_url 'ftp://panel.example.com' >/dev/null; then
  fail "normalize_panel_url: чужая схема принята"
fi
if normalize_panel_url 'https://panel.example.com/login' >/dev/null; then
  fail "normalize_panel_url: URL с путём принят"
fi
if normalize_panel_url 'https://' >/dev/null; then
  fail "normalize_panel_url: пустой хост принят"
fi
[[ "$(panel_url_host 'https://panel.example.com:8443')" == "panel.example.com" ]] \
  || fail "panel_url_host: порт не срезан"
ok "нормализация домена и URL панели (https:// добавляется, слэш/путь срезаются)"

# IP панели по её домену: dig подменён стабом выше (отвечает SERVER_IP).
[[ "$(resolve_ipv4_host '203.0.113.7')" == "203.0.113.7" ]] \
  || fail "resolve_ipv4_host: готовый IPv4 должен возвращаться как есть"
[[ "$(resolve_ipv4_host 'panel.example.com')" == "$SERVER_IP" ]] \
  || fail "resolve_ipv4_host: A-запись домена панели не определилась"
ok "resolve_ipv4_host: IP панели определяется по её домену"

# Случайные значения быстрого режима: формат и диапазон, а не конкретные числа.
hex8="$(random_hex 8)"
[[ "$hex8" =~ ^[0-9a-f]{8}$ ]] || fail "random_hex 8 выдал «$hex8»"
rand_path="$(gen_random_api_path /api/v3/sync)"
[[ "$rand_path" =~ ^/api/v3/sync/[0-9a-f]{8}$ ]] || fail "gen_random_api_path выдал «$rand_path»"
is_safe_xhttp_path "$rand_path" || fail "случайный путь не проходит is_safe_xhttp_path: $rand_path"
for _ in $(seq 1 30); do
  rand_port="$(random_node_port)"
  [[ "$rand_port" =~ ^[0-9]+$ ]] || fail "random_node_port выдал «$rand_port»"
  (( rand_port >= 11000 && rand_port <= 59999 )) \
    || fail "случайный порт вне безопасного диапазона: $rand_port"
  case "$rand_port" in
    10443|10444|10446|10447|10448|9443|9444) fail "случайный порт совпал с портом схемы: $rand_port" ;;
  esac
done
ok "случайные путь и порт быстрого режима (формат и диапазон)"

unset BASE_DOMAIN SERVER_IP CLOUDFLARE_API_TOKEN VLESS_HOST HY_HOST CDN_HOST CF_ZONE_ID CF_ZONE_NAME CDN_DNS_MANAGED CF_MOCK_ZONE_NAME

# --- multiselect_filter: готовый Config Profile для панели ---
# Профиль обязан следовать режиму XHTTP: с выключенным XHTTP inbound
# REALITY_XHTTP уходит из профиля, иначе нода поднимала бы 127.0.0.1:10444,
# к которому Caddy больше не маршрутизирует (см. L4-блок в установщике).
# Заодно проверяем, что плейсхолдеры шаблона заменены на реальные хосты.
command -v jq >/dev/null 2>&1 || fail "для проверки Config Profile нужен jq"
MULTISELECT="$SRC/Multiselect.json"
[[ -r "$MULTISELECT" ]] || fail "не найден $MULTISELECT"
export SELF_STEAL_HOST=usa1.example.com HY_HOST=usa3.example.com
export XHTTP_SNI=www.gstatic.com XHTTP_PATH=/api/v3/sync/r1 CERT_DIR=/etc/remna-certs
# CDN-режим: набор inbound'ов обязан следовать за ENABLE_CDN/CDN_TRANSPORT,
# а пути CDN — подставляться в профиль вместо шаблонных.
export CDN_HOST=cdn.example.com CDN_TRANSPORT=ws
export CDN_WS_PATH=/api/v1/stream CDN_XHTTP_PATH=/api/v3/sync/c1 CDN_GRPC_PATH=/api/v4/stream
export ENABLE_CDN=0

export ENABLE_XHTTP=1
multiselect_filter < "$MULTISELECT" > "$WORK/profile-on.json"
jq -e . "$WORK/profile-on.json" >/dev/null || fail "профиль с XHTTP — не валидный JSON"
[[ "$(jq -c '[.inbounds[].tag]' "$WORK/profile-on.json")" == '["REALITY_VISION","REALITY_XHTTP","HYSTERIA2"]' ]] \
  || fail "с включённым XHTTP профиль потерял inbound: $(jq -c '[.inbounds[].tag]' "$WORK/profile-on.json")"
[[ "$(jq -r '.inbounds[] | select(.tag=="REALITY_VISION") | .streamSettings.realitySettings.serverNames[0]' "$WORK/profile-on.json")" == "$SELF_STEAL_HOST" ]] \
  || fail "в Vision не подставлен self-steal домен"
[[ "$(jq -r '.inbounds[] | select(.tag=="REALITY_XHTTP") | .streamSettings.xhttpSettings.path' "$WORK/profile-on.json")" == "$XHTTP_PATH" ]] \
  || fail "в XHTTP не подставлен path"
[[ "$(jq -r '.inbounds[] | select(.tag=="REALITY_XHTTP") | .streamSettings.realitySettings.target' "$WORK/profile-on.json")" == "$XHTTP_SNI:443" ]] \
  || fail "target XHTTP не следует за внешним SNI"
[[ "$(jq -r '.inbounds[] | select(.tag=="HYSTERIA2") | .streamSettings.tlsSettings.certificates[0].keyFile' "$WORK/profile-on.json")" == "$CERT_DIR/$HY_HOST/key.pem" ]] \
  || fail "в Hysteria2 не подставлен путь к сертификату"
if grep -q '<prefix>' "$WORK/profile-on.json"; then
  fail "в профиле остались плейсхолдеры <prefix>1.<domain>/<prefix>3.<domain>"
fi
ok "multiselect_filter: хосты подставлены, XHTTP включён"

export ENABLE_XHTTP=0
multiselect_filter < "$MULTISELECT" > "$WORK/profile-off.json"
jq -e . "$WORK/profile-off.json" >/dev/null || fail "профиль без XHTTP — не валидный JSON"
[[ "$(jq -c '[.inbounds[].tag]' "$WORK/profile-off.json")" == '["REALITY_VISION","HYSTERIA2"]' ]] \
  || fail "неверный набор inbound'ов без XHTTP: $(jq -c '[.inbounds[].tag]' "$WORK/profile-off.json")"
[[ "$(jq '[.inbounds[] | select((.streamSettings.network // "") == "xhttp")] | length' "$WORK/profile-off.json")" == 0 ]] \
  || fail "с выключенным XHTTP в профиле остался xhttp-inbound"
# Остальные разделы (dns/outbounds/routing) адаптация задевать не должна.
[[ "$(jq -S 'del(.inbounds)' "$MULTISELECT")" == "$(jq -S 'del(.inbounds)' "$WORK/profile-off.json")" ]] \
  || fail "адаптация профиля затронула dns/outbounds/routing"
ok "multiselect_filter: с выключенным XHTTP остаются только Vision и Hysteria2"

# cdn_transport_enabled: строка CDN_TRANSPORT → набор транспортов. От неё
# зависят и промпты, и состав профиля, поэтому проверяем все значения.
for spec in \
  'ws:ws' 'ws:!xhttp' 'ws:!grpc' \
  'xhttp:xhttp' 'xhttp:!ws' 'xhttp:!grpc' \
  'grpc:grpc' 'grpc:!ws' 'grpc:!xhttp' \
  'both:ws' 'both:xhttp' 'both:!grpc' \
  'all:ws' 'all:xhttp' 'all:grpc' \
  'bogus:!ws' 'bogus:!xhttp' 'bogus:!grpc' \
  ':!ws' ':!grpc'; do
  spec_transport="${spec%%:*}"
  spec_expect="${spec#*:}"
  spec_name="${spec_expect#!}"
  if CDN_TRANSPORT="$spec_transport" cdn_transport_enabled "$spec_name"; then
    [[ "$spec_expect" == "$spec_name" ]] \
      || fail "CDN_TRANSPORT='$spec_transport' не должен включать транспорт $spec_name"
  else
    [[ "$spec_expect" == "!$spec_name" ]] \
      || fail "CDN_TRANSPORT='$spec_transport' должен включать транспорт $spec_name"
  fi
done
ok "cdn_transport_enabled: ws/xhttp/grpc/both/all, чужое значение не включает ничего"

# Таблица вариантов: xhttp:cdn:transport → ожидаемые теги inbound'ов.
while IFS=: read -r xhttp cdn transport want; do
  [[ -n "${want:-}" ]] || continue
  ENABLE_XHTTP="$xhttp" ENABLE_CDN="$cdn" CDN_TRANSPORT="$transport" \
    multiselect_filter < "$MULTISELECT" > "$WORK/profile-variant.json" \
    || fail "фильтр профиля упал: xhttp=$xhttp cdn=$cdn transport=$transport"
  got="$(jq -c '[.inbounds[].tag]' "$WORK/profile-variant.json")"
  [[ "$got" == "$want" ]] \
    || fail "xhttp=$xhttp cdn=$cdn transport=$transport: ожидались $want, получено $got"
done <<'CASES'
1:0:ws:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2"]
0:0:ws:["REALITY_VISION","HYSTERIA2"]
1:1:ws:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_WS"]
1:1:xhttp:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_XHTTP"]
1:1:both:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_WS","VLESS_CDN_XHTTP"]
0:1:xhttp:["REALITY_VISION","HYSTERIA2","VLESS_CDN_XHTTP"]
0:1:both:["REALITY_VISION","HYSTERIA2","VLESS_CDN_WS","VLESS_CDN_XHTTP"]
1:1:grpc:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_GRPC"]
0:1:grpc:["REALITY_VISION","HYSTERIA2","VLESS_CDN_GRPC"]
1:1:all:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_WS","VLESS_CDN_XHTTP","VLESS_CDN_GRPC"]
0:1:all:["REALITY_VISION","HYSTERIA2","VLESS_CDN_WS","VLESS_CDN_XHTTP","VLESS_CDN_GRPC"]
# Неизвестный транспорт не должен оставлять «все» CDN-инбаунды: без выбранного
# транспорта профиль обязан совпасть с режимом без CDN.
1:1:bogus:["REALITY_VISION","REALITY_XHTTP","HYSTERIA2"]
CASES
ok "multiselect_filter: состав профиля следует за XHTTP и CDN (ws/xhttp/grpc/all)"

# Пути CDN-транспортов в профиле должны совпадать с маршрутами Caddy.
ENABLE_XHTTP=0 ENABLE_CDN=1 CDN_TRANSPORT=all \
  multiselect_filter < "$MULTISELECT" > "$WORK/profile-cdn.json"
[[ "$(jq -r '.inbounds[] | select(.tag=="VLESS_CDN_WS") | .streamSettings.wsSettings.path' "$WORK/profile-cdn.json")" == "$CDN_WS_PATH" ]] \
  || fail "в CDN WebSocket не подставлен path"
[[ "$(jq -r '.inbounds[] | select(.tag=="VLESS_CDN_XHTTP") | .streamSettings.xhttpSettings.path' "$WORK/profile-cdn.json")" == "$CDN_XHTTP_PATH" ]] \
  || fail "в CDN XHTTP не подставлен path"
[[ "$(jq -r '.inbounds[] | select(.tag=="VLESS_CDN_GRPC") | .streamSettings.grpcSettings.serviceName' "$WORK/profile-cdn.json")" == "$CDN_GRPC_PATH" ]] \
  || fail "в CDN gRPC не подставлен serviceName"
[[ "$(jq -c '[.inbounds[] | select(.tag|startswith("VLESS_CDN_")) | {tag, net: .streamSettings.network, listen, port}]' "$WORK/profile-cdn.json")" \
   == '[{"tag":"VLESS_CDN_WS","net":"ws","listen":"127.0.0.1","port":10446},{"tag":"VLESS_CDN_XHTTP","net":"xhttp","listen":"127.0.0.1","port":10447},{"tag":"VLESS_CDN_GRPC","net":"grpc","listen":"127.0.0.1","port":10448}]' ]] \
  || fail "CDN-инбаунды в профиле не совпадают с портами транспортов: $(jq -c '[.inbounds[] | select(.tag|startswith("VLESS_CDN_")) | {tag, net: .streamSettings.network, listen, port}]' "$WORK/profile-cdn.json")"
[[ "$(jq '[.inbounds[] | select(.tag|startswith("VLESS_CDN")) | select(.streamSettings.security != "none")] | length' "$WORK/profile-cdn.json")" == 0 ]] \
  || fail "CDN-инбаунды в профиле должны быть без собственного TLS (security: none)"
# gRPC без TLS — это h2c: Caddy обязан ходить в него тем же протоколом.
[[ "$(jq -r '.inbounds[] | select(.tag=="VLESS_CDN_GRPC") | .streamSettings.security' "$WORK/profile-cdn.json")" == "none" ]] \
  || fail "CDN gRPC в профиле должен быть без TLS (security: none = h2c со стороны Caddy)"
ok "multiselect_filter: пути и security CDN-инбаундов корректны"

# write_config_profile — вторая половина задачи: готовый профиль должен ещё и
# сохраниться на диск. Локальный шаблон рядом со скриптом берётся без сети
# (тот же шаблон, что в репозитории), поэтому пишем в отдельный NODE_DIR.
# have/warn — стабы, объявленные выше для Cloudflare-кейсов; здесь нужен только retry.
retry() { local _tries="$1" _delay="$2"; shift 2; "$@"; }
export NODE_DIR="$WORK/node" SCRIPT_DIR="$SRC"
export ENABLE_XHTTP=1
export ENABLE_CDN=0
write_config_profile >/dev/null
[[ -f "$NODE_DIR/Multiselect.json" ]] || fail "Config Profile не сохранён в $NODE_DIR"
jq -e . "$NODE_DIR/Multiselect.json" >/dev/null \
  || fail "сохранённый Config Profile — не валидный JSON"
[[ "$(jq -c '[.inbounds[].tag]' "$NODE_DIR/Multiselect.json")" == '["REALITY_VISION","REALITY_XHTTP","HYSTERIA2"]' ]] \
  || fail "в сохранённом профиле неверный набор inbound'ов"
# С включённым CDN в сохранённом файле появляются выбранные CDN-инбаунды
# (both — прежнее значение env-файлов, all — все три транспорта).
export ENABLE_CDN=1 CDN_TRANSPORT=both
write_config_profile >/dev/null
[[ "$(jq -c '[.inbounds[].tag]' "$NODE_DIR/Multiselect.json")" == '["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_WS","VLESS_CDN_XHTTP"]' ]] \
  || fail "в сохранённом профиле нет CDN-инбаундов: $(jq -c '[.inbounds[].tag]' "$NODE_DIR/Multiselect.json")"
export ENABLE_CDN=1 CDN_TRANSPORT=grpc
write_config_profile >/dev/null
[[ "$(jq -c '[.inbounds[].tag]' "$NODE_DIR/Multiselect.json")" == '["REALITY_VISION","REALITY_XHTTP","HYSTERIA2","VLESS_CDN_GRPC"]' ]] \
  || fail "CDN_TRANSPORT=grpc не оставил в профиле только gRPC-инбаунд: $(jq -c '[.inbounds[].tag]' "$NODE_DIR/Multiselect.json")"
ok "write_config_profile: профиль сохранён в NODE_DIR/Multiselect.json"

# --- условный L4-маршрут XHTTP в Caddyfile ---
# Фрагмент извлекается из установщика как есть: с выключенным XHTTP Caddy не
# должен уводить SNI XHTTP в 127.0.0.1:10444, где после отключения inbound'а
# никто не слушает (иначе проверка TLS-маршрутов уронит установку).
sed -n '/^XHTTP_L4_BLOCK=""/,/^fi$/p' "$SETUP" > "$WORK/l4-block.sh"
grep -q '^XHTTP_L4_BLOCK=""' "$WORK/l4-block.sh" || fail "не удалось извлечь генерацию L4-блока XHTTP"
grep -q '^fi$' "$WORK/l4-block.sh" || fail "фрагмент генерации L4-блока обрезан (нет fi)"
export XHTTP_SNI=www.gstatic.com
l4_block_with_xhttp() {
  local enable="$1"
  (
    set -Eeuo pipefail
    ENABLE_XHTTP="$enable"
    # shellcheck source=/dev/null
    . "$WORK/l4-block.sh"
    printf '%s' "$XHTTP_L4_BLOCK"
  )
}
[[ "$(l4_block_with_xhttp 1)" == *"@xhttp tls sni www.gstatic.com"* ]] \
  || fail "с включённым XHTTP L4-маршрут XHTTP не генерируется"
[[ -z "$(l4_block_with_xhttp 0)" ]] \
  || fail "с выключенным XHTTP L4-маршрут XHTTP всё ещё генерируется"
ok "Caddyfile: L4-маршрут XHTTP появляется только при включённом XHTTP"

# --- условный L4-маршрут CDN ---
# Тот же приём: без ENABLE_CDN Caddy не должен уводить SNI CDN-хоста на
# 127.0.0.1:9444 (там нет сайта и сертификата).
sed -n '/^CDN_L4_BLOCK=""/,/^fi$/p' "$SETUP" > "$WORK/l4-cdn.sh"
grep -q '^CDN_L4_BLOCK=""' "$WORK/l4-cdn.sh" || fail "не удалось извлечь генерацию L4-блока CDN"
grep -q '^fi$' "$WORK/l4-cdn.sh" || fail "фрагмент генерации L4-блока CDN обрезан (нет fi)"
cdn_l4_block() {
  local enable="$1"
  (
    set -Eeuo pipefail
    # Значения читает извлекаемый фрагмент, поэтому здесь они экспортируются.
    export ENABLE_CDN="$enable" CDN_HOST=cdn.example.com CDN_TLS_PORT=9444
    # shellcheck source=/dev/null
    . "$WORK/l4-cdn.sh"
    printf '%s' "$CDN_L4_BLOCK"
  )
}
[[ "$(cdn_l4_block 1)" == *"@cdn tls sni cdn.example.com"* ]] \
  || fail "с включённым CDN L4-маршрут CDN не генерируется"
[[ "$(cdn_l4_block 1)" == *"proxy 127.0.0.1:9444"* ]] \
  || fail "L4-маршрут CDN ведёт не на CDN-сайт Caddy"
[[ -z "$(cdn_l4_block 0)" ]] \
  || fail "с выключенным CDN L4-маршрут CDN всё ещё генерируется"
ok "Caddyfile: L4-маршрут CDN появляется только при включённом CDN"

unset SELF_STEAL_HOST HY_HOST XHTTP_SNI XHTTP_PATH CERT_DIR ENABLE_XHTTP NODE_DIR SCRIPT_DIR

# --- self_steal_template_url: тема фасада → URL шаблона ---
# Список тем в установщике обязан совпадать с файлами self-steal-templates/:
# иначе --self-steal-template NAME дал бы 404 прямо на ноде.
grep -E '^SELF_STEAL_(RAW_BASE|TEMPLATES)=' "$SETUP" > "$WORK/self-steal.sh"
grep -q '^SELF_STEAL_TEMPLATES=(' "$WORK/self-steal.sh" || fail "нет списка тем self-steal"
# shellcheck source=/dev/null
. "$WORK/self-steal.sh"
mapfile -t theme_names < <(self_steal_template_list)
(( ${#theme_names[@]} >= 2 )) || fail "список тем self-steal пуст"
themes_checked=0
for theme in "${theme_names[@]}"; do
  url="$(self_steal_template_url "$theme")" || fail "тема $theme не разрешается в URL"
  [[ "$url" == "$SELF_STEAL_RAW_BASE/self-steal-templates/$theme.html" ]] \
    || fail "тема $theme → неожиданный URL: $url"
  [[ -r "$SRC/self-steal-templates/$theme.html" ]] \
    || fail "в репозитории нет файла темы $theme"
  themes_checked=$((themes_checked + 1))
done
[[ "$themes_checked" == "${#theme_names[@]}" ]] || fail "проверены не все темы"
export SELF_STEAL_TEMPLATE_URL='https://example.com/custom.html'
[[ "$(self_steal_template_url '')" == 'https://example.com/custom.html' ]] \
  || fail "пустая тема должна возвращать явный SELF_STEAL_TEMPLATE_URL"
if self_steal_template_url 'no-such-theme' >/dev/null; then
  fail "неизвестная тема не отвергается"
fi
unset SELF_STEAL_TEMPLATE_URL
ok "self_steal_template_url: $themes_checked тем совпадают с файлами, чужое имя отвергается"

# Резолвер темы из шага 1 установщика: тема → URL, явный URL важнее темы,
# чужое имя останавливает установку со списком доступных тем.
sed -n "/^# Тема фасада → URL шаблона/,/^fi\$/p" "$SETUP" > "$WORK/resolve-theme.sh"
grep -q 'self_steal_template_url' "$WORK/resolve-theme.sh" \
  || fail "не удалось извлечь резолвер темы из установщика"
grep -q 'if \[\[ -z' "$WORK/resolve-theme.sh" \
  || fail "в извлечённом резолвере нет условия (извлекли не тот фрагмент)"
resolve_theme() { # resolve_theme <тема> <явный URL> → «URL|признак использования темы»
  (
    set -Eeuo pipefail
    export SELF_STEAL_TEMPLATE="$1"
    export SELF_STEAL_TEMPLATE_URL="$2"
    export SELF_STEAL_THEME_USED=0
    # shellcheck source=/dev/null
    . "$WORK/resolve-theme.sh"
    printf '%s|%s' "$SELF_STEAL_TEMPLATE_URL" "$SELF_STEAL_THEME_USED"
  )
}
[[ "$(resolve_theme mail '')" == "$SELF_STEAL_RAW_BASE/self-steal-templates/mail.html|1" ]] \
  || fail "тема mail не превратилась в URL: $(resolve_theme mail '')"
[[ "$(resolve_theme '' 'https://example.com/my.html')" == 'https://example.com/my.html|0' ]] \
  || fail "явный SELF_STEAL_TEMPLATE_URL не имеет приоритета над темой"
if resolve_theme 'no-such-theme' '' >/dev/null 2>"$WORK/theme-err"; then
  fail "неизвестная тема не остановила установку"
fi
grep -q 'Неизвестная тема self-steal: no-such-theme' "$WORK/theme-err" \
  || fail "нет понятной ошибки про неизвестную тему: $(cat "$WORK/theme-err")"
grep -qF vaultdrop "$WORK/theme-err" \
  || fail "в ошибке не перечислены доступные темы: $(cat "$WORK/theme-err")"
ok "резолвер темы: тема → URL, явный URL важнее, чужое имя → die со списком тем"

# --- acme_cert_days_left: повторный запуск не должен «пропускать» битый
#     или истекающий сертификат (регрессия P2-2) ---
export ACME_HOME="$WORK/acme"
mkdir -p "$ACME_HOME"

mkcert() { # mkcert <домен> <дней>
  local d="$1" days="$2" dir
  dir="$ACME_HOME/${d}_ecc"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
    -keyout "$dir/$d.key" -out "$dir/$d.crt" \
    -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1 \
    || fail "openssl не смог создать тестовый сертификат $d"
}

if acme_cert_days_left 'missing.test'; then
  fail "сертификата нет, а функция вернула успех"
fi

mkcert 'fresh.test' 90
days="$(acme_cert_days_left 'fresh.test')" || fail "fresh.test: не удалось прочитать срок"
(( days >= 89 && days <= 90 )) || fail "fresh.test: неожиданный срок ${days}д (ожидалось 89–90)"

mkcert 'soon.test' 3
days="$(acme_cert_days_left 'soon.test')" || fail "soon.test: не удалось прочитать срок"
(( days <= 7 )) || fail "soon.test: срок ${days}д > 7 — перевыпуск не сработает"

mkdir -p "$ACME_HOME/corrupt.test_ecc"
printf 'это не сертификат\n' > "$ACME_HOME/corrupt.test_ecc/corrupt.test.crt"
if acme_cert_days_left 'corrupt.test'; then
  fail "битый сертификат считается валидным"
fi
ok "acme_cert_days_left: свежий учитывается, битый/отсутствующий требует перевыпуска"


# --- Panel API: HTTP-код обязан доживать до panel_api_success ---
# Регрессия: panel_api вызывается через $(...), и выставленный внутри подоболочки
# PANEL_HTTP_CODE не возвращался вызывающему. Из-за этого panel_api_success
# всегда видел «000» и считал ошибкой даже 200 с валидным токеном («не удалось
# подключиться к панели» при заведомо рабочем токене).
for fn in panel_curl_cfg_init panel_http_code_file panel_http_error_file panel_state_init panel_api_code panel_api \
         panel_api_success panel_api_error panel_check_connection \
         panel_connection_hint panel_api_retry \
         panel_fetch_node_secret \
         panel_profile_name panel_result_uuid panel_try_host \
         panel_find_profile_by_name json5_to_json; do
  sed -n "/^${fn}() {\$/,/^}\$/p" "$SETUP" > "$WORK/panel-$fn.sh"
  grep -q "^${fn}() {" "$WORK/panel-$fn.sh" || fail "не удалось извлечь $fn из установщика"
  # shellcheck source=/dev/null
  . "$WORK/panel-$fn.sh"
done

PANEL_STATE_DIR="$WORK/panel-state"
mkdir -p "$PANEL_STATE_DIR"
PANEL_MOCK_CALLS="$WORK/panel-calls.log"
PANEL_MOCK_PROFILES_BODY='{"response":{"total":0,"configProfiles":[]}}'
PANEL_MOCK_NODES_BODY='{"response":[]}'

curl() { # мок панели: тело и код задаются переменными сценария
  local url="" a body code
  for a in "$@"; do url="$a"; done
  printf '%s\n' "$url" >> "$PANEL_MOCK_CALLS"
  body="$PANEL_MOCK_PROFILES_BODY"; code="$PANEL_MOCK_PROFILES_CODE"
  if [[ "$url" == */nodes ]]; then
    body="$PANEL_MOCK_NODES_BODY"; code="$PANEL_MOCK_NODES_CODE"
  fi
  [[ -z "$PANEL_MOCK_ERR" ]] || printf '%s\n' "$PANEL_MOCK_ERR" >&2
  printf '%s\n%s' "$body" "$code"
  return "${PANEL_MOCK_RC:-0}"
}

PANEL_MOCK_PROFILES_CODE=200
PANEL_MOCK_NODES_CODE=200
PANEL_MOCK_RC=0
PANEL_MOCK_ERR=""
sleep() { :; }

panel_mock_reset() {
  export PANEL_HTTP_BODY=""
  export PANEL_HTTP_CODE_FILE=""
  export PANEL_HTTP_ERROR_FILE=""
  export PANEL_CONN_REASON=""
  export PANEL_CONN_DETAIL=""
  export PANEL_CONN_CODE=""
  PANEL_MOCK_PROFILES_CODE=200
  PANEL_MOCK_NODES_CODE=200
  PANEL_MOCK_PROFILES_BODY='{"response":{"total":0,"configProfiles":[]}}'
  PANEL_MOCK_NODES_BODY='{"response":[]}'
  PANEL_MOCK_RC=0
  PANEL_MOCK_ERR=""
  rm -f "${PANEL_CURL_CFG:-}" 2>/dev/null || true
  PANEL_CURL_CFG=""
  : > "$PANEL_MOCK_CALLS"
  panel_curl_cfg_init
}

export REMNAWAVE_PANEL_URL="https://panel.example.com/"
REMNAWAVE_API_TOKEN="$(printf 'eyJ%s' "$(printf 'A%.0s' {1..220})")"
export REMNAWAVE_API_TOKEN

panel_mock_reset
panel_check_connection \
  || fail "panel_check_connection: валидный ответ 200 считается ошибкой (код HTTP терялся в подоболочке)"
[[ "$(panel_api_code)" == "200" ]] || fail "panel_api_code: код 200 не сохранился"
grep -q '^header = "Authorization: Bearer eyJ' "$PANEL_CURL_CFG" \
  || fail "panel_curl_cfg_init: токен не попал в curl config"
ok "panel_api: HTTP-код и токен доходят до проверки (регрессия ложного «не удалось подключиться»)"

panel_mock_reset
PANEL_MOCK_PROFILES_CODE=401
PANEL_MOCK_NODES_CODE=401
PANEL_MOCK_PROFILES_BODY='{"message":"Unauthorized","code":"A001"}'
PANEL_MOCK_NODES_BODY='{"message":"Unauthorized","code":"A001"}'
if panel_check_connection; then fail "panel_check_connection: 401 принят как успех"; fi
[[ "$PANEL_CONN_REASON" == "unauthorized" ]] || fail "401 не распознан как проблема токена: $PANEL_CONN_REASON"
[[ "$(panel_connection_hint)" == *"HTTP 401"* ]] || fail "подсказка для 401 не упоминает HTTP 401"
ok "panel_api: 401 → «токен отклонён», а не общая ошибка"

panel_mock_reset
PANEL_MOCK_PROFILES_CODE=403
PANEL_MOCK_NODES_CODE=403
PANEL_MOCK_PROFILES_BODY='{"message":"Forbidden resource","code":"A040"}'
PANEL_MOCK_NODES_BODY='{"message":"Forbidden resource","code":"A040"}'
if panel_check_connection; then fail "panel_check_connection: 403 принят как успех"; fi
[[ "$PANEL_CONN_REASON" == "scope" ]] || fail "403 не распознан как нехватка прав: $PANEL_CONN_REASON"
[[ "$(panel_connection_hint)" == *"прав"* ]] || fail "подсказка для 403 не говорит о правах токена"
ok "panel_api: 403 → «токен рабочий, не хватает прав»"

panel_mock_reset
PANEL_MOCK_PROFILES_CODE=403
PANEL_MOCK_PROFILES_BODY='{"message":"Forbidden resource","code":"A040"}'
if panel_check_connection; then fail "panel_check_connection: 403 config-profiles принят как успех"; fi
[[ "$PANEL_CONN_REASON" == "scope" ]] || fail "403 на одном разделе не распознан: $PANEL_CONN_REASON"
[[ "$PANEL_CONN_DETAIL" == *"config-profiles"* ]] || fail "в отказе не назван раздел: $PANEL_CONN_DETAIL"
[[ "$PANEL_CONN_DETAIL" != *"nodes"* ]] || fail "в отказ попал доступный раздел: $PANEL_CONN_DETAIL"
ok "panel_api: 403 называет только разделы без прав"

panel_mock_reset
PANEL_MOCK_PROFILES_CODE=000
PANEL_MOCK_NODES_CODE=000
PANEL_MOCK_RC=7
PANEL_MOCK_ERR="curl: (7) Failed to connect to panel.example.com port 443"
if panel_check_connection; then fail "panel_check_connection: сетевая ошибка принята как успех"; fi
[[ "$PANEL_CONN_REASON" == "network" ]] || fail "сетевая ошибка не распознана: $PANEL_CONN_REASON"
[[ "$PANEL_CONN_DETAIL" == *"curl: (7)"* ]] || fail "текст ошибки curl потерялся: $PANEL_CONN_DETAIL"
ok "panel_api: сетевой сбой → код 000 и текст curl в диагностике"

panel_mock_reset
PANEL_MOCK_PROFILES_CODE=200
PANEL_MOCK_PROFILES_BODY='<!DOCTYPE html><html><body>Cloudflare Access</body></html>'
if panel_check_connection; then fail "panel_check_connection: HTML вместо JSON принят как успех"; fi
[[ "$PANEL_CONN_REASON" == "not-json" ]] || fail "HTML вместо JSON не распознан: $PANEL_CONN_REASON"
ok "panel_api: HTML (Cloudflare Access) не считается успешным ответом"

panel_mock_reset
PANEL_MOCK_PROFILES_CODE=403
PANEL_MOCK_PROFILES_BODY='{"message":"Forbidden resource"}'
if panel_api_retry GET /config-profiles >/dev/null; then fail "panel_api_retry: 403 принят как успех"; fi
[[ "$(wc -l < "$PANEL_MOCK_CALLS")" == 1 ]] || fail "panel_api_retry ретраит 4xx (403)"
panel_mock_reset
PANEL_MOCK_PROFILES_CODE=500
PANEL_MOCK_PROFILES_BODY='{"message":"Internal error"}'
if panel_api_retry GET /config-profiles >/dev/null; then fail "panel_api_retry: 500 принят как успех"; fi
[[ "$(wc -l < "$PANEL_MOCK_CALLS")" == 3 ]] || fail "panel_api_retry: 500 не повторился 3 раза"
panel_mock_reset
ok "panel_api_retry: 403 не ретраится, 5xx — три попытки"

# Имя Config Profile: точки из домена запрещены API (400 на POST).
BASE_DOMAIN="example.com"
name="$(panel_profile_name)"
[[ "$name" != *.* ]] || fail "panel_profile_name: точка осталась в имени ($name)"
[[ "$name" =~ ^[A-Za-z0-9_\ -]{2,30}$ ]] || fail "panel_profile_name: недопустимые символы ($name)"
BASE_DOMAIN="$(printf 'very-long-subdomain-%.0s' {1..3}).example.com"
name="$(panel_profile_name)"
(( ${#name} <= 30 )) || fail "panel_profile_name: имя длиннее 30 символов (${#name})"
[[ "$name" =~ ^[A-Za-z0-9_\ -]{2,30}$ ]] || fail "panel_profile_name: недопустимые символы ($name)"
unset BASE_DOMAIN
ok "panel_profile_name: домен с точками санируется, длина ≤ 30"

# Ответы-обёртки Remnawave 3.x: {response:{configProfiles:[...]}}.
found="$( (
  # shellcheck disable=SC2317,SC2329  # вызывается косвенно; код зависит от версии shellcheck
  panel_api() { printf '%s' '{"response":{"total":1,"configProfiles":[{"uuid":"p-1","name":"multi-example-com"}]}}'; }
  panel_find_profile_by_name 'multi-example-com'
) )"
[[ "$found" == "p-1" ]] || fail "panel_find_profile_by_name не читает {response:{configProfiles}}: '$found'"
ok "panel_find_profile_by_name: список профилей в обёртке response.configProfiles"

# JSON5 → JSON: комментарии вне строк удаляются, URL внутри строк не ломается.
converted="$(printf '%s\n' $'{\n  "url": "https://example.com/x", // комментарий\n  "list": [1, 2,],\n}\n' | json5_to_json | jq -c .)" \
  || fail "json5_to_json: результат не разбирается jq"
[[ "$converted" == '{"url":"https://example.com/x","list":[1,2]}' ]] \
  || fail "json5_to_json: неверный результат: $converted"
for tpl in Xray_template.json Xray_template_split.json; do
  json5_to_json < "$SRC/$tpl" | jq -e . >/dev/null 2>&1 \
    || fail "json5_to_json: $tpl не превращается в валидный JSON"
done
ok "json5_to_json: комментарии и висячие запятые убраны, шаблоны валидны"

# Результат upsert-функции: она печатает ok/warn и лишь последней строкой uuid.
# При ошибке код возврата ненулевой, и текст предупреждения НЕ должен стать uuid
# (иначе он уходил бы в URL запросов и установка «завершалась успешно»).
res="$(panel_result_uuid $'  ✔ Config Profile создан: x (5f0f1a76-1111-2222-3333-444455556666)\n5f0f1a76-1111-2222-3333-444455556666' 0)"
[[ "$res" == "5f0f1a76-1111-2222-3333-444455556666" ]] \
  || fail "panel_result_uuid: uuid не извлечён из вывода функции: '$res'"
res="$(panel_result_uuid '  ▲ Не удалось создать Config Profile: Internal server error (код A500, HTTP 500)' 1)"
[[ -z "$res" ]] || fail "panel_result_uuid: текст ошибки принят за uuid: '$res'"
ok "panel_result_uuid: uuid берётся только из успешного вызова"

# shellcheck disable=SC2317,SC2329  # вызывается косвенно; код зависит от версии shellcheck
panel_upsert_host() { return "${HOST_STUB_RC:-0}"; }
out="$(panel_try_host a b c)"
[[ -z "$out" ]] || fail "panel_try_host: в консоль попал вывод успешного вызова: '$out'"
HOST_STUB_RC=1
rc=0
panel_try_host a b c >/dev/null || rc=$?
[[ "$rc" -eq 1 ]] || fail "panel_try_host: код ошибки потерян (rc=$rc)"
HOST_STUB_RC=0
unset -f panel_upsert_host
ok "panel_try_host: успех молчит, ошибка возвращает код"

# panel_fetch_node_secret: Remnawave 3.x (secretKey) и 2.x (pubKey)
panel_mock_reset
key="$( (
  # shellcheck disable=SC2317,SC2329
  panel_api() { printf '%s' '{"response":{"secretKey":"eyJhbGciOiJSUzI1NiJ9.v3key"}}'; }
  # shellcheck disable=SC2317,SC2329
  panel_api_code() { printf '200'; }
  panel_fetch_node_secret
) )"
[[ "$key" == "eyJhbGciOiJSUzI1NiJ9.v3key" ]] || fail "panel_fetch_node_secret v3 secretKey не извлечён: '$key'"

key="$( (
  # shellcheck disable=SC2317,SC2329
  panel_api() { printf '%s' '{"response":{"pubKey":"eyJhbGciOiJSUzI1NiJ9.v2key"}}'; }
  # shellcheck disable=SC2317,SC2329
  panel_api_code() { printf '200'; }
  panel_fetch_node_secret
) )"
[[ "$key" == "eyJhbGciOiJSUzI1NiJ9.v2key" ]] || fail "panel_fetch_node_secret legacy pubKey не извлечён: '$key'"

if (
  # shellcheck disable=SC2317,SC2329
  panel_api() { printf '%s' '{"message":"Forbidden resource"}'; }
  # shellcheck disable=SC2317,SC2329
  panel_api_code() { printf '403'; }
  # shellcheck disable=SC2317,SC2329
  panel_api_success() { return 1; }
  panel_fetch_node_secret
); then
  fail "panel_fetch_node_secret вернул успех при ошибке API"
fi
ok "panel_fetch_node_secret: извлекает secretKey / pubKey и возвращает ошибку при сбое"

printf 'все проверки функций установщика прошли\n'
