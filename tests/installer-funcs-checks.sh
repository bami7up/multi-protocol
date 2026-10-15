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

for fn in is_ipv4 is_ipv6 is_private_ipv4 is_fqdn is_safe_xhttp_path acme_cert_days_left; do
  sed -n "/^${fn}() {\$/,/^}\$/p" "$SETUP" > "$WORK/$fn.sh"
  grep -q "^${fn}() {" "$WORK/$fn.sh" || fail "не удалось извлечь $fn из установщика"
  grep -q '^}$' "$WORK/$fn.sh" || fail "тело $fn обрезано (нет закрывающей скобки)"
  # shellcheck source=/dev/null
  . "$WORK/$fn.sh"
done
ok "функции валидации извлечены из установщика"

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
