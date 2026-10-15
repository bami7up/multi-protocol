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
           acme_cert_days_left cf_rand_index cf_make_hosts cf_valid_saved_host; do
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
for fn in cf_api cf_json_success cf_json_error cf_upsert_a cf_a_exists cf_setup_hosts; do
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
    elif [[ "$CF_MOCK_ZONE_FOUND" == 1 ]]; then
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

unset BASE_DOMAIN SERVER_IP CLOUDFLARE_API_TOKEN VLESS_HOST HY_HOST

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

printf 'все проверки функций установщика прошли\n'
