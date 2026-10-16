#!/usr/bin/env bash
# Интеграционная проверка того самого Caddyfile, который генерирует remnanode-setup.sh,
# на настоящем Caddy из официального релиза (та же версия, что пинит установщик).
#
# Статическим разбором нельзя подтвердить требования HTTP-слоя, поэтому проверяем
# на живом сервере:
#   - :80 отдаёт постоянный 301 на HTTPS и сохраняет путь и query string;
#   - локальный TLS-сайт self-steal отдаёт HSTS, скрывает Server и отвечает на TLS 1.2/1.3;
#   - сайт CDN-хоста отдаёт фасад, а пути транспортов (ws/xhttp/grpc) уходят в Xray,
#     причём gRPC — по h2c, живым апстримом;
#   - TLS 1.0/1.1 не согласуются.
# Блок layer4 вырезается: он требует плагина caddy-l4 и на HTTP-слой не влияет.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$SRC/remnanode-setup.sh"
WORK="$(mktemp -d)"
CADDY_PID=""
H2C_PID=""
HTTP_PORT=""
HTTPS_PORT=""
CDN_HTTPS_PORT=""
CDN_HOST="cdn.test.local"
# Пути для CDN в тесте намеренно отличаются от шаблонных: так видно, что Caddy
# маршрутизирует именно те пути, которые переданы установщику.
CDN_PROBE_WS_PATH="/probe/ws"
CDN_PROBE_XHTTP_PATH="/probe/xhttp"
CDN_PROBE_GRPC_PATH="/probe/grpc"
CDN_WS_PORT=10446
CDN_XHTTP_PORT=10447
CDN_GRPC_PORT=10448

cleanup() {
  for pid in "$H2C_PID" "$CADDY_PID"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
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
CDN_HTTPS_PORT="$(pick_port 19443)" || fail "нет свободного порта"

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
# Блоков два: основной Caddyfile и (при включённом CDN) дописываемый сайт
# CDN-хоста — проверяем именно то, что окажется на ноде при CDN-режиме.
awk '
  /^[[:space:]]*cat >>? \/etc\/caddy\/Caddyfile <<EOF$/ { f = 1; next }
  f && /^EOF$/ { f = 0; next }
  f { print }
' "$SETUP" > "$WORK/raw"
[[ -s "$WORK/raw" ]] || fail "в установщике не найден heredoc с Caddyfile"
grep -q 'VLESS_CDN' "$SETUP" || fail "в установщике нет CDN-инбаундов"
grep -qF 'CDN_ROUTES_BLOCK' "$SETUP" \
  || fail "в установщике нет сборщика маршрутов CDN-сайта"
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

# Сертификат CDN-хоста в тесте — копия тестового: важно, что Caddy грузит его
# для сайта CDN, а не что он настоящий.
mkdir -p "$WORK/cdn.test.local"
cp "$WORK/fullchain.pem" "$WORK/cdn.test.local/fullchain.pem"
cp "$WORK/key.pem" "$WORK/cdn.test.local/key.pem"

sed -e "s|\\\$SELF_STEAL_HOST|test.local|g" \
  -e "s|\\\$CDN_HOST|cdn.test.local|g" \
  -e "s|http://test.local {|http://test.local:$HTTP_PORT {|" \
  -e "s|:9443 {|:$HTTPS_PORT {|" \
  -e "s|\\\$CDN_TLS_PORT|$CDN_HTTPS_PORT|g" \
  -e "s|\\\$CERT_DIR/test.local|$WORK|g" \
  -e "s|\\\$CERT_DIR/cdn.test.local|$WORK/cdn.test.local|g" \
  -e "s|\\\$SELF_STEAL_ROOT|$WORK/www|g" \
  "$WORK/stripped" > "$WORK/Caddyfile"

# Маршруты CDN-сайта установщик собирает в переменную CDN_ROUTES_BLOCK — в
# тексте heredoc стоит только её имя. Берём сборщик из установщика как есть и
# подставляем его результат: так проверяются и маршруты, и их пути.
sed -n '/^  CDN_ROUTES_BLOCK=""/,/^  cat >> \/etc\/caddy\/Caddyfile <<EOF$/p' "$SETUP" \
  | sed '$d' > "$WORK/cdn-routes.sh"
grep -q 'xhttpcdn' "$WORK/cdn-routes.sh" \
  || fail "в сборщике маршрутов CDN нет маршрута XHTTP"
{
  set -Eeuo pipefail
  # Значения читает извлекаемый фрагмент, поэтому здесь они экспортируются.
  export CDN_WS_ENABLED=1 CDN_XHTTP_ENABLED=1 CDN_GRPC_ENABLED=1
  export CDN_WS_PATH="$CDN_PROBE_WS_PATH" CDN_XHTTP_PATH="$CDN_PROBE_XHTTP_PATH"
  export CDN_GRPC_PATH="$CDN_PROBE_GRPC_PATH"
  export CDN_WS_PORT CDN_XHTTP_PORT CDN_GRPC_PORT
  # shellcheck source=/dev/null
  . "$WORK/cdn-routes.sh"
  printf '%s\n' "$CDN_ROUTES_BLOCK"
} > "$WORK/cdn-routes.txt"
[[ -s "$WORK/cdn-routes.txt" ]] || fail "сборщик маршрутов CDN выдал пустой блок"
awk -v routes="$WORK/cdn-routes.txt" '
  /\$CDN_ROUTES_BLOCK/ { while ((getline line < routes) > 0) print line; next }
  { print }
' "$WORK/Caddyfile" > "$WORK/Caddyfile.with-cdn" && mv "$WORK/Caddyfile.with-cdn" "$WORK/Caddyfile"
grep -qF "@ws path $CDN_PROBE_WS_PATH*" "$WORK/Caddyfile" \
  || fail "маршрут WebSocket CDN попал в Caddyfile не с тем путём"
grep -qF "@xhttpcdn path $CDN_PROBE_XHTTP_PATH*" "$WORK/Caddyfile" \
  || fail "маршрут XHTTP CDN попал в Caddyfile не с тем путём"
grep -qF "@grpccdn path $CDN_PROBE_GRPC_PATH/*" "$WORK/Caddyfile" \
  || fail "маршрут gRPC CDN попал в Caddyfile не с тем serviceName"
grep -qF "reverse_proxy @grpccdn h2c://127.0.0.1:$CDN_GRPC_PORT" "$WORK/Caddyfile" \
  || fail "gRPC-маршрут CDN должен вести в Xray по h2c (HTTP/2 без TLS)"
grep -qF "https://$CDN_HOST:$CDN_HTTPS_PORT {" "$WORK/Caddyfile" \
  || fail "сайт CDN-хоста не попал в Caddyfile"

printf 'порты теста: http=%s https=%s cdn-https=%s cdn-grpc-h2c=%s\n' \
  "$HTTP_PORT" "$HTTPS_PORT" "$CDN_HTTPS_PORT" "$CDN_GRPC_PORT"
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

# 2b. Апстрим для gRPC-маршрута: второй Caddy, говорящий по h2c (HTTP/2 без
#     TLS) — так проверяется вся цепочка Cloudflare-подобного проксирования,
#     а не только тот факт, что маршрут попал в конфиг.
cat > "$WORK/h2c.Caddyfile" <<EOF
{
  auto_https off
  servers {
    protocols h2c
  }
}
127.0.0.1:$CDN_GRPC_PORT {
  respond "grpc-h2c-upstream"
}
EOF
"$CADDY" run --adapter caddyfile --config "$WORK/h2c.Caddyfile" > "$WORK/h2c.log" 2>&1 &
H2C_PID=$!
for _ in $(seq 1 80); do
  if ss -H -lnt "sport = :$CDN_GRPC_PORT" 2>/dev/null | grep -q .; then break; fi
  if ! kill -0 "$H2C_PID" 2>/dev/null; then
    cat "$WORK/h2c.log"
    fail "Caddy-h2c-апстрим завершился при старте"
  fi
  sleep 0.25
done
ss -H -lnt "sport = :$CDN_GRPC_PORT" 2>/dev/null | grep -q . \
  || fail "Caddy-h2c-апстрим не открыл порт $CDN_GRPC_PORT"

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

# 4b. Каждая тема фасада должна реально отдаваться Caddy: так проверяются и
#     сами файлы тем, и то, что header-блок с CSP их не ломает.
grep -qi "content-security-policy:.*default-src 'none'" "$WORK/tlshead" \
  || { sed 's/^/   /' "$WORK/tlshead"; fail "локальный сайт отдаётся без CSP default-src 'none'"; }
for tpl in "$SRC"/self-steal-templates/*.html; do
  theme="$(basename "$tpl" .html)"
  title="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$tpl" | head -1)"
  [[ -n "$title" ]] || fail "тема $theme: в файле нет <title>"
  cp "$tpl" "$WORK/www/index.html"
  curl -sS -o "$WORK/page" -D "$WORK/pagehead" -k --max-time 10 \
    --resolve "test.local:$HTTPS_PORT:127.0.0.1" "https://test.local:$HTTPS_PORT/" \
    || fail "тема $theme: страница не отдалась Caddy"
  grep -qF "$title" "$WORK/page" || fail "тема $theme: Caddy отдал не тот файл"
  grep -qi '^content-security-policy:' "$WORK/pagehead" \
    || fail "тема $theme: ответ без CSP"
  ok "тема $theme: отдаётся Caddy, тело совпадает с файлом, CSP на месте"
done

# 4c. Сайт CDN-хоста: фасад на всех прочих путях и маршруты в Xray по путям
#     инбаундов. Инбаунды в тесте не слушают, поэтому правильный признак
#     работающего маршрута — ошибка апстрима (5xx), а не 404.
printf '   CDN-хост %s\n' "$CDN_HOST"
cp "$SRC/self-steal-templates/vaultdrop.html" "$WORK/www/index.html"
curl -sS -o "$WORK/cdn-page" -D "$WORK/cdn-head" -k --max-time 10 \
  --resolve "$CDN_HOST:$CDN_HTTPS_PORT:127.0.0.1" "https://$CDN_HOST:$CDN_HTTPS_PORT/" \
  || fail "CDN-хост: фасад не отдался"
grep -qF '<title>Vaultdrop' "$WORK/cdn-page" || fail "CDN-хост: отдан не фасад"
grep -qi '^strict-transport-security: max-age=31536000' "$WORK/cdn-head" \
  || { sed 's/^/   /' "$WORK/cdn-head"; fail "CDN-хост: нет HSTS"; }
grep -qi '^content-security-policy:' "$WORK/cdn-head" || fail "CDN-хост: нет CSP"
grep -qi '^server:' "$WORK/cdn-head" && fail "CDN-хост: заголовок Server не скрыт"
ok "CDN-хост: отдаётся фасад с HSTS/CSP и без Server"

# Маршруты ws/xhttp в тесте ведут в несуществующие инбаунды: признак
# работающего маршрута — ошибка апстрима, а не 404.
for cdn_path in "$CDN_PROBE_WS_PATH" "$CDN_PROBE_XHTTP_PATH"; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' -k --max-time 10 \
    --resolve "$CDN_HOST:$CDN_HTTPS_PORT:127.0.0.1" \
    "https://$CDN_HOST:$CDN_HTTPS_PORT$cdn_path")" \
    || fail "CDN-путь $cdn_path: запрос не выполнился"
  [[ "$status" != 404 ]] \
    || fail "CDN-путь $cdn_path: Caddy не маршрутизирует его в Xray (404)"
  [[ "$status" =~ ^5 ]] \
    || fail "CDN-путь $cdn_path: ожидалась ошибка апстрима (инбаунда нет), получено $status"
  ok "CDN-путь $cdn_path маршрутизируется в Xray (апстрим недоступен → $status)"
done

# gRPC: запрос доходит до h2c-апстрима и возвращает его ответ — значит Caddy
# выделил префикс serviceName и проксирует поток по HTTP/2 без TLS.
grpc_status="$(curl -sS -o "$WORK/grpc-body" -w '%{http_code}' -k --max-time 10 \
  --resolve "$CDN_HOST:$CDN_HTTPS_PORT:127.0.0.1" \
  "https://$CDN_HOST:$CDN_HTTPS_PORT$CDN_PROBE_GRPC_PATH/Tun")" \
  || fail "gRPC-путь $CDN_PROBE_GRPC_PATH/Tun: запрос не выполнился"
[[ "$grpc_status" == 200 ]] \
  || { sed 's/^/   /' "$WORK/grpc-body"; fail "gRPC-путь: ожидался ответ h2c-апстрима (200), получено $grpc_status"; }
grep -qF 'grpc-h2c-upstream' "$WORK/grpc-body" \
  || fail "gRPC-путь: до h2c-апстрима дошёл не тот запрос"
ok "CDN-путь $CDN_PROBE_GRPC_PATH/Tun проксируется в Xray по h2c (ответ апстрима получен)"

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
