# --- Caddyfile, L4 и проверки ---
caddy_build_matches() {
  have caddy \
    && [[ "$(caddy version 2>/dev/null | awk '{print $1}')" == "$CADDY_VERSION" ]] \
    && caddy list-modules 2>/dev/null | grep -qE 'layer4' \
    && caddy build-info 2>/dev/null | tr '\t' ' ' \
      | grep -Fq "github.com/mholt/caddy-l4 $CADDY_L4_VERSION"
}

assert_port443_free() {
  local line holder
  have ss || return 0
  line="$(ss -H -lntp 'sport = :443' 2>/dev/null | grep -vi caddy | head -1 || true)"
  [[ -n "$line" ]] || return 0
  holder="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line")"
  holder="${holder:-неизвестный процесс}"
  die "Порт 443/tcp занят процессом «$holder»: остановите его (systemctl stop <сервис>), иначе Caddy не сможет слушать 443."
}

has_tcp_listener() {
  ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .
}

has_tcp_listener_at() {
  local address="$1" port="$2"
  ss -H -lnt "sport = :$port" 2>/dev/null | awk '{print $4}' | grep -Fqx "$address:$port"
}

has_udp_listener() {
  ss -H -lnu "sport = :$1" 2>/dev/null | grep -q .
}

all_protocol_listeners_ready() {
  local xhttp_ready=1 cdn_ready=1
  # 10444 слушает только включённый XHTTP: с выключенным профилем его нет.
  if (( ENABLE_XHTTP )); then
    has_tcp_listener_at 127.0.0.1 10444 || xhttp_ready=0
  fi
  # CDN-сайт Caddy слушает всегда, когда включён CDN, а инбаунды — только если
  # они есть в назначенном панелью профиле (то есть включены на карточке ноды).
  if (( ENABLE_CDN )); then
    has_tcp_listener_at 127.0.0.1 "$CDN_TLS_PORT" || cdn_ready=0
    if (( CDN_WS_ENABLED )); then
      has_tcp_listener_at 127.0.0.1 "$CDN_WS_PORT" || cdn_ready=0
    fi
    if (( CDN_XHTTP_ENABLED )); then
      has_tcp_listener_at 127.0.0.1 "$CDN_XHTTP_PORT" || cdn_ready=0
    fi
    if (( CDN_GRPC_ENABLED )); then
      has_tcp_listener_at 127.0.0.1 "$CDN_GRPC_PORT" || cdn_ready=0
    fi
  fi
  (( xhttp_ready == 1 && cdn_ready == 1 )) \
    && has_tcp_listener 443 \
    && has_tcp_listener_at 127.0.0.1 9443 \
    && has_tcp_listener_at 127.0.0.1 10443 \
    && has_tcp_listener "$NODE_API_PORT" \
    && has_udp_listener 443
}

check_tls_route() {
  local name="$1" sni="$2" output
  printf '   %s%s%s (%s)%s\n' "${C_B:-}" "${C_MAG:-}" "$name" "$sni" "${C_RST:-}"
  if output="$(timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$sni" \
      -verify_hostname "$sni" -verify_return_error -brief </dev/null 2>&1)" \
      && grep -Eq 'CONNECTION ESTABLISHED|Protocol version:' <<<"$output"; then
    printf '%s\n' "$output" | head -8 | sed 's/^/     /'
    return 0
  fi
  printf '%s\n' "$output" | head -8 | sed 's/^/     /'
  warn "$name: TLS-маршрут для SNI $sni не прошёл проверку."
  return 1
}

verify_http_layer() {
  local tmp
  tmp="$(mktemp)"
  if curl -sS -o /dev/null -D "$tmp" --max-time 10 \
      --resolve "$SELF_STEAL_HOST:80:127.0.0.1" \
      "http://$SELF_STEAL_HOST/probe/path?probe=1" 2>/dev/null \
      && head -1 "$tmp" | grep -q ' 301' \
      && grep -qi "^location: https://$SELF_STEAL_HOST/probe/path?probe=1" "$tmp"; then
    ok "Порт 80 отдаёт постоянный 301 с сохранением пути и query"
  else
    sed 's/^/     /' "$tmp" | head -8
    rm -f "$tmp"
    die "Порт 80 не отдаёт 301 на HTTPS с сохранением URI (см. вывод выше)."
  fi
  if curl -sS -o /dev/null -D "$tmp" --max-time 10 \
      --resolve "$SELF_STEAL_HOST:9443:127.0.0.1" \
      "https://$SELF_STEAL_HOST:9443/" 2>/dev/null \
      && grep -qi '^strict-transport-security: max-age=31536000' "$tmp"; then
    ok "Локальный TLS-сайт: сертификат валиден и отдаёт HSTS max-age=31536000"
  else
    sed 's/^/     /' "$tmp" | head -8
    rm -f "$tmp"
    die "Self-steal сайт не отдал HSTS или сертификат не прошёл проверку."
  fi
  rm -f "$tmp"
  local tls_ver
  for tls_ver in tls1_2 tls1_3; do
    echo | timeout 10 openssl s_client -connect 127.0.0.1:9443 \
      -servername "$SELF_STEAL_HOST" -"$tls_ver" -brief >/dev/null 2>&1 \
      || die "Локальный TLS-сайт не принимает $tls_ver — проверьте tls protocols в Caddyfile."
  done
  ok "Локальный TLS-сайт принимает TLS 1.2 и TLS 1.3"
}

xhttp_l4_block() {
  if (( ENABLE_XHTTP )); then
    printf '      @xhttp tls sni %s\n      route @xhttp {\n        proxy 127.0.0.1:10444\n      }' "$XHTTP_SNI"
  fi
}

cdn_l4_block() {
  if (( ENABLE_CDN )); then
    printf '      @cdn tls sni %s\n      route @cdn {\n        proxy 127.0.0.1:%s\n      }' "$CDN_HOST" "$CDN_TLS_PORT"
  fi
}

cdn_routes_block() {
  if (( CDN_WS_ENABLED )); then
    printf '\n  @ws path %s*\n  reverse_proxy @ws 127.0.0.1:%s' "$CDN_WS_PATH" "$CDN_WS_PORT"
  fi
  if (( CDN_XHTTP_ENABLED )); then
    printf '\n  @xhttpcdn path %s*\n  reverse_proxy @xhttpcdn 127.0.0.1:%s' "$CDN_XHTTP_PATH" "$CDN_XHTTP_PORT"
  fi
  if (( CDN_GRPC_ENABLED )); then
    printf '\n  @grpccdn path %s/*\n  reverse_proxy @grpccdn h2c://127.0.0.1:%s {\n    flush_interval -1\n  }' "$CDN_GRPC_PATH" "$CDN_GRPC_PORT"
  fi
}

render_caddyfile() {
  # Генерирует Caddyfile в $CADDYFILE_PATH. Вынесено из main, чтобы
  # интеграционный тест вызывал функцию, а не извлекал heredoc sed/awk.
# Маршрут XHTTP вырезается целиком, когда XHTTP выключен: иначе Caddy уводил бы
# SNI XHTTP в 127.0.0.1:10444, где после отключения inbound'а никто не слушает.
XHTTP_L4_BLOCK="$(xhttp_l4_block)"
CDN_L4_BLOCK="$(cdn_l4_block)"
cat > "$CADDYFILE_PATH" <<EOF
{
  admin off
  auto_https disable_redirects
  layer4 {
    :443 {
      @vision tls sni $SELF_STEAL_HOST
      route @vision {
        proxy 127.0.0.1:10443
      }
$XHTTP_L4_BLOCK
$CDN_L4_BLOCK
      route {
        proxy 127.0.0.1:$SELF_STEAL_TLS_PORT
      }
    }
  }
}

# Постоянный 301 на HTTPS с сохранением пути и query string.
# Домен берётся из конфигурации, а не из заголовка Host, поэтому open redirect невозможен.
http://$SELF_STEAL_HOST${SELF_STEAL_HTTP_PORT:+:$SELF_STEAL_HTTP_PORT} {
  redir https://$SELF_STEAL_HOST{uri} permanent
}

https://$SELF_STEAL_HOST:$SELF_STEAL_TLS_PORT {
  bind 127.0.0.1
  tls "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem" "$CERT_DIR/$SELF_STEAL_HOST/key.pem" {
    protocols tls1.2 tls1.3
  }
  root * $SELF_STEAL_ROOT
  header {
    -Server
    Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
    Strict-Transport-Security "max-age=31536000"
  }
  file_server
}
EOF

if (( ENABLE_XHTTP )) && is_xhttp_target_local && [[ "$XHTTP_SNI" != "$SELF_STEAL_HOST" ]]; then
  # XHTTP REALITY с локальным target: REALITY-сервер форвардит неаутентифи-
  # цированный handshake на 127.0.0.1:9443 с SNI XHTTP_SNI. Публичный сайт для
  # этого SNI не нужен — Caddy отвечает только на loopback, поэтому используем
  # внутренний сертификат (`tls internal`): REALITY-клиент не проверяет цепочку
  # target, ему важен только согласованный TLS-handshake. Отдельный блок нужен,
  # потому что сертификат self-steal домена не подходит для чужого SNI.
  cat >> "$CADDYFILE_PATH" <<EOF

https://$XHTTP_SNI:$SELF_STEAL_TLS_PORT {
  bind 127.0.0.1
  tls internal
  root * $SELF_STEAL_ROOT
  header {
    -Server
    Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
    Strict-Transport-Security "max-age=31536000"
  }
  file_server
}
EOF
fi

if (( ENABLE_CDN )); then
  # Отдельный блок для CDN-хоста. Публичный TLS терминирует CDN, а к нам на :443
  # приходит уже его SNI — отсюда маршрут @cdn в layer4. Здесь мы терминируем
  # TLS сертификатом CDN-хоста и отдаём: пути инбаундов — в Xray (loopback),
  # всё остальное — тот же фасад, что и на self-steal сайте. Сторонний сканер
  # по CDN-хосту видит обычный веб-сайт. Xray при этом не смотрит наружу.
  CDN_ROUTES_BLOCK="$(cdn_routes_block)"
  cat >> "$CADDYFILE_PATH" <<EOF

https://$CDN_HOST:$CDN_TLS_PORT {
  bind 127.0.0.1
  tls "$CERT_DIR/$CDN_HOST/fullchain.pem" "$CERT_DIR/$CDN_HOST/key.pem" {
    protocols tls1.2 tls1.3
  }
$CDN_ROUTES_BLOCK
  root * $SELF_STEAL_ROOT
  header {
    -Server
    Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
    Strict-Transport-Security "max-age=31536000"
  }
  file_server
}
EOF
fi
}
