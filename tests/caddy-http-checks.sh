#!/usr/bin/env bash
# Интеграционная проверка того самого Caddyfile, который генерирует remnanode-setup.sh,
# на настоящем Caddy из официального релиза (та же версия, что пинит установщик).
#
# Статическим разбором нельзя подтвердить требования HTTP-слоя, поэтому проверяем
# на живом сервере:
#   - :80 отдаёт постоянный 301 на HTTPS и сохраняет путь и query string;
#   - локальный TLS-сайт self-steal отдаёт HSTS, скрывает Server и отвечает на TLS 1.2/1.3;
#   - TLS 1.0/1.1 не согласуются.
# Блок layer4 вырезается: он требует плагина caddy-l4 и на HTTP-слой не влияет.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$SRC/remnanode-setup.sh"
WORK="$(mktemp -d)"
CADDY_PID=""
HTTP_PORT=""
HTTPS_PORT=""

cleanup() {
  if [[ -n "$CADDY_PID" ]]; then
    kill "$CADDY_PID" 2>/dev/null || true
    wait "$CADDY_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok() { printf '✔ %s\n' "$*"; }

command -v ss >/dev/null 2>&1 || fail "нужен ss (пакет iproute2)"

pick_port() {
  local p="$1"
  for ((; p < 65000; p++)); do
    if ! ss -H -lnt "sport = :$p" 2>/dev/null | grep -q .; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

[[ -r "$SETUP" ]] || fail "не найден $SETUP"
CADDY_VERSION="$(grep -m1 '^CADDY_VERSION=' "$SETUP" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[[ "$CADDY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "не удалось прочитать CADDY_VERSION из $SETUP"
HTTP_PORT="$(pick_port 18080)" || fail "нет свободного порта"
HTTPS_PORT="$(pick_port 18443)" || fail "нет свободного порта"

# 1. Caddy нужной версии: локальный, иначе официальный релиз.
CADDY="$(command -v caddy || true)"
if [[ -n "$CADDY" && "$("$CADDY" version 2>/dev/null | awk '{print $1}')" == "$CADDY_VERSION" ]]; then
  ok "использую локальный caddy $CADDY_VERSION"
else
  case "$(uname -m)" in
    x86_64 | amd64) caddy_arch=amd64 ;;
    aarch64 | arm64) caddy_arch=arm64 ;;
    *) fail "нет релиза Caddy для $(uname -m)" ;;
  esac
  caddy_url="https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}/caddy_${CADDY_VERSION#v}_linux_${caddy_arch}.tar.gz"
  curl -fsSL "$caddy_url" -o "$WORK/caddy.tgz" || fail "не удалось скачать $caddy_url"
  tar -xzf "$WORK/caddy.tgz" -C "$WORK" caddy || fail "не удалось распаковать архив Caddy"
  CADDY="$WORK/caddy"
  [[ "$("$CADDY" version | awk '{print $1}')" == "$CADDY_VERSION" ]] \
    || fail "скачанный Caddy не той версии (нужна $CADDY_VERSION)"
  ok "скачан официальный Caddy $CADDY_VERSION ($caddy_arch)"
fi

# 2. Достаём Caddyfile из установщика и подгоняем под локальный тест.
awk '/^cat > \/etc\/caddy\/Caddyfile <<EOF$/{f=1;next} f&&/^EOF$/{f=0} f' "$SETUP" > "$WORK/raw"
[[ -s "$WORK/raw" ]] || fail "в установщике не найден heredoc с Caddyfile"
grep -qF "redir https://\$SELF_STEAL_HOST{uri} permanent" "$WORK/raw" \
  || fail "в генерируемом Caddyfile нет постоянного 301 на :80"
grep -q 'protocols tls1.2 tls1.3' "$WORK/raw" \
  || fail "в генерируемом Caddyfile не зафиксированы TLS 1.2/1.3"

awk '
  /layer4 \{/ { skip = 1; depth = 1; next }
  skip {
    depth += gsub(/\{/, "{") - gsub(/\}/, "}")
    if (depth <= 0) { skip = 0 }
    next
  }
  { print }
' "$WORK/raw" > "$WORK/stripped"
if grep -q 'layer4' "$WORK/stripped"; then
  fail "не удалось вырезать блок layer4 из Caddyfile"
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$WORK/key.pem" -out "$WORK/fullchain.pem" \
  -subj '/CN=test.local' -addext 'subjectAltName=DNS:test.local' >/dev/null 2>&1 \
  || fail "openssl не смог создать тестовый сертификат"
mkdir -p "$WORK/www"
printf 'self-steal facade\n' > "$WORK/www/index.html"

sed -e "s|\\\$SELF_STEAL_HOST|test.local|g" \
  -e "s|http://test.local {|http://test.local:$HTTP_PORT {|" \
  -e "s|:9443 {|:$HTTPS_PORT {|" \
  -e "s|\\\$CERT_DIR/test.local|$WORK|g" \
  -e "s|\\\$SELF_STEAL_ROOT|$WORK/www|g" \
  "$WORK/stripped" > "$WORK/Caddyfile"

printf 'порты теста: http=%s https=%s\n' "$HTTP_PORT" "$HTTPS_PORT"
if ! "$CADDY" validate --adapter caddyfile --config "$WORK/Caddyfile"; then
  printf '--- сгенерированный Caddyfile ---\n'
  cat "$WORK/Caddyfile"
  fail "Caddy не принял Caddyfile из установщика"
fi
ok "Caddyfile из установщика валиден"

# Установщик прогоняет caddy fmt перед запуском: проверяем, что форматирование ничего не ломает.
"$CADDY" fmt --overwrite "$WORK/Caddyfile" >/dev/null
"$CADDY" validate --adapter caddyfile --config "$WORK/Caddyfile" >/dev/null 2>&1 \
  || fail "Caddyfile не проходит валидацию после caddy fmt"
ok "caddy fmt не ломает Caddyfile"

"$CADDY" run --adapter caddyfile --config "$WORK/Caddyfile" > "$WORK/caddy.log" 2>&1 &
CADDY_PID=$!
for _ in $(seq 1 80); do
  if ss -H -lnt "sport = :$HTTP_PORT" 2>/dev/null | grep -q .; then break; fi
  if ! kill -0 "$CADDY_PID" 2>/dev/null; then
    cat "$WORK/caddy.log"
    fail "Caddy завершился при старте"
  fi
  sleep 0.25
done
ss -H -lnt "sport = :$HTTP_PORT" 2>/dev/null | grep -q . || fail "Caddy не открыл порт $HTTP_PORT"

# 3. :80 → 301 с сохранением пути и query (регресс P0-2).
curl -sS -o "$WORK/body" -D "$WORK/head" --max-time 10 \
  --resolve "test.local:$HTTP_PORT:127.0.0.1" \
  "http://test.local:$HTTP_PORT/probe/path?probe=1"
head -1 "$WORK/head" | grep -q ' 301' \
  || { sed 's/^/   /' "$WORK/head"; fail "ожидался 301, получено: $(head -1 "$WORK/head")"; }
grep -qi '^location: https://test.local/probe/path?probe=1' "$WORK/head" \
  || { sed 's/^/   /' "$WORK/head"; fail "Location не сохранил путь и query string"; }
[[ ! -s "$WORK/body" ]] || fail "у редиректа непустое тело"
ok "301 сохраняет путь и query string"

# 4. Локальный TLS-сайт: HSTS, скрытый Server, TLS 1.2/1.3.
curl -sS -o "$WORK/index.html" -D "$WORK/tlshead" -k --max-time 10 \
  --resolve "test.local:$HTTPS_PORT:127.0.0.1" "https://test.local:$HTTPS_PORT/"
grep -qi '^strict-transport-security: max-age=31536000' "$WORK/tlshead" \
  || { sed 's/^/   /' "$WORK/tlshead"; fail "нет HSTS max-age=31536000"; }
grep -qi '^server:' "$WORK/tlshead" && fail "заголовок Server не скрыт"
grep -q 'self-steal facade' "$WORK/index.html" || fail "локальный сайт не отдал файл"
ok "HSTS на месте, Server скрыт, файл отдаётся"

for tls_ver in tls1_2 tls1_3; do
  negotiated="$(echo | openssl s_client -connect "127.0.0.1:$HTTPS_PORT" -servername test.local \
    -"$tls_ver" -brief 2>&1 | grep -oE 'Protocol version: TLSv1\.[0-9]+' || true)"
  case "$negotiated" in
    *TLSv1.2 | *TLSv1.3) ok "$tls_ver согласован ($negotiated)" ;;
    *) fail "TLS-сайт не согласовал $tls_ver (получено: ${negotiated:-пусто})" ;;
  esac
done

for tls_old in tls1 tls1_1; do
  if echo | openssl s_client -connect "127.0.0.1:$HTTPS_PORT" -servername test.local \
      -"$tls_old" -brief 2>&1 | grep -q 'Protocol version: TLSv1\.[01]'; then
    fail "TLS-сайт всё ещё согласует $tls_old"
  fi
done
ok "TLS 1.0 и 1.1 не согласуются"

printf 'все проверки HTTP-слоя Caddyfile прошли\n'
