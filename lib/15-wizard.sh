# --- интерактивные вопросы и запись env-файла ---
# Вынесено из main, чтобы тесты вызывали функции напрямую, а не извлекали
# блоки кода sed/awk.
prompt_flags() {
# === flags block start ===
# Быстрый режим (QUICK_SETUP=1): XHTTP и CDN включены без вопросов; SNI —
# проверенный дефолт, пути на свежей установке — случайные, CDN-домен —
# уникальный cdn-<hex>.<базовый домен> (поддомен 1-го уровня для бесплатного
# Cloudflare Universal SSL, без коллизии между несколькими нодами на домене).
# Значения из env/сохранённого env-файла не затираются.
if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
  ENABLE_XHTTP=1
else
  ask_bool ENABLE_XHTTP "Включить XHTTP (рекомендуется: да)?" "${ENABLE_XHTTP:-y}"
fi
if (( ENABLE_XHTTP )); then
  if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
    XHTTP_SNI="${XHTTP_SNI:-www.gstatic.com}"
    if [[ -z "${XHTTP_PATH:-}" ]]; then
      XHTTP_PATH="$(gen_random_api_path /api/v3/sync 2>/dev/null || printf '/api/v3/sync/r1')"
    fi
    note "XHTTP: включён автоматически (SNI $XHTTP_SNI, путь $XHTTP_PATH)"
  else
    ask XHTTP_SNI  "Маскировочный SNI для XHTTP (сайт для REALITY-handshake)" "${XHTTP_SNI:-www.gstatic.com}"
    ask XHTTP_PATH "Путь XHTTP (случайный URL-путь)" "${XHTTP_PATH:-/api/v3/sync/r1}"
  fi
  # Target REALITY для XHTTP. external — проверенный внешний сайт; local —
  # локальный self-steal сайт (экспериментально, нужен стенд). Явно заданный
  # нестандартный host:port не перезаписываем — это ручная настройка.
  if [[ -n "${XHTTP_TARGET:-}" && "$XHTTP_TARGET" != "www.gstatic.com:443" ]] \
      && ! is_xhttp_target_local; then
    note "XHTTP target из env сохранён: $XHTTP_TARGET"
  else
    __target_mode="external"
    if is_xhttp_target_local; then __target_mode="local"; fi
    __target_default=1
    if [[ "$__target_mode" == "local" ]]; then __target_default=2; fi
    ask_choice __target_mode "XHTTP target для REALITY" "$__target_default" \
      "external: Внешний www.gstatic.com:443 — проверенный вариант (рекомендуется)" \
      "local: Локальный self-steal 127.0.0.1:$SELF_STEAL_TLS_PORT — экспериментально, нужен стенд"
    if [[ "$__target_mode" == "local" ]]; then
      XHTTP_TARGET="self"
    else
      XHTTP_TARGET="www.gstatic.com:443"
    fi
    unset __target_mode __target_default
  fi
else
  warn "XHTTP отключён — будет использован только Vision (Reality)."
  XHTTP_SNI=""
  XHTTP_PATH=""
fi
if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
  ENABLE_CDN=1
else
  ask_bool ENABLE_CDN "Добавить VLESS за CDN (прячет IP ноды)?" "${ENABLE_CDN:-n}"
fi
if (( ENABLE_CDN )); then
  note "CDN прячет origin: клиент идёт на CDN-домен по 443, CDN — на :443 ноды."
  note "Публичный TLS терминирует CDN, между CDN и нодой — сертификат origin (DNS-01 через Cloudflare)."
  note "Проксируемую A-запись для CDN-домена установщик создаст сам в Cloudflare (оранжевое облако) —"
  note "вручную её создавать не нужно. Исключение — запуск с --no-cloudflare: тогда запись делаете вы."
  if [[ -z "${CDN_HOST:-}" ]]; then
    if declare -F gen_cdn_host >/dev/null 2>&1; then
      __cdn_default="$(gen_cdn_host "${BASE_DOMAIN:-}" 2>/dev/null || printf 'cdn.%s' "${BASE_DOMAIN:-}")"
    else
      __cdn_default="cdn-$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n').${BASE_DOMAIN:-}"
    fi
  else
    __cdn_default="$CDN_HOST"
  fi
  if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
    CDN_HOST="$__cdn_default"
    # В быстром режиме транспорт раньше молча фиксировался на ws. Теперь это
    # такой же выбираемый пункт, как шаблон подписки; сохранённый выбор — дефолт.
    case "${CDN_TRANSPORT,,}" in
      xhttp) __cdn_num=2 ;;
      grpc)  __cdn_num=3 ;;
      both)  __cdn_num=4 ;;
      all)   __cdn_num=5 ;;
      *)     __cdn_num=1 ;;
    esac
    ask_choice CDN_TRANSPORT "Транспорт VLESS за CDN" "$__cdn_num" \
      "ws: WebSocket — максимальная совместимость (по умолчанию)" \
      "xhttp: XHTTP — современный транспорт" \
      "grpc: gRPC (h2c) — для Cloudflare" \
      "both: ws + xhttp" \
      "all: ws + xhttp + grpc"
    unset __cdn_num
    note "CDN: включён (домен $CDN_HOST, транспорт ${CDN_TRANSPORT,,})"
  else
    ask CDN_HOST "Домен, проксируемый CDN (A-запись под оранжевым облаком)" "$__cdn_default"
    ask CDN_TRANSPORT "Транспорт CDN: ws, xhttp, grpc, both (ws+xhttp) или all" "${CDN_TRANSPORT:-ws}"
  fi
  unset __cdn_default
  CDN_TRANSPORT="${CDN_TRANSPORT,,}"
  case "$CDN_TRANSPORT" in
    ws|xhttp|grpc|both|all) ;;
    *) die "CDN_TRANSPORT должен быть ws, xhttp, grpc, both или all (получено: $CDN_TRANSPORT)." ;;
  esac
  if cdn_transport_enabled ws; then
    CDN_WS_ENABLED=1
    if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
      # На свежей установке дефолтный путь заменяем случайным; сохранённый
      # (повторный запуск, ENV_STORE_LOADED=1) не трогаем.
      if [[ "${ENV_STORE_LOADED:-0}" != 1 && "${CDN_WS_PATH:-}" == "/api/v1/stream" ]]; then
        CDN_WS_PATH="$(gen_random_api_path /api/v1 2>/dev/null || printf '/api/v1/stream')"
      fi
    else
      ask CDN_WS_PATH "Путь WebSocket для CDN" "${CDN_WS_PATH:-/api/v1/stream}"
    fi
  fi
  if cdn_transport_enabled xhttp; then
    CDN_XHTTP_ENABLED=1
    if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
      if [[ "${ENV_STORE_LOADED:-0}" != 1 && "${CDN_XHTTP_PATH:-}" == "/api/v3/sync/c1" ]]; then
        CDN_XHTTP_PATH="$(gen_random_api_path /api/v3/sync 2>/dev/null || printf '/api/v3/sync/c1')"
      fi
    else
      ask CDN_XHTTP_PATH "Путь XHTTP для CDN" "${CDN_XHTTP_PATH:-/api/v3/sync/c1}"
    fi
  fi
  if cdn_transport_enabled grpc; then
    CDN_GRPC_ENABLED=1
    if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
      if [[ "${ENV_STORE_LOADED:-0}" != 1 && "${CDN_GRPC_PATH:-}" == "/api/v4/stream" ]]; then
        CDN_GRPC_PATH="$(gen_random_api_path /api/v4 2>/dev/null || printf '/api/v4/stream')"
      fi
    else
      ask CDN_GRPC_PATH "serviceName gRPC для CDN" "${CDN_GRPC_PATH:-/api/v4/stream}"
    fi
  fi
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    note "Для CDN нужен Cloudflare Token с Zone:Read + DNS:Edit: им установщик создаст проксируемую"
    note "A-запись CDN-домена и выпустит сертификат origin по DNS-01."
    ask_secret CLOUDFLARE_API_TOKEN \
      "Cloudflare API Token (для A-записи и DNS-01 сертификата CDN)" ""
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# БЛОК 4/4: Панель Remnawave
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
  if has_tty; then printf '\n %s%s━━━ Быстрая автоустановка: панель Remnawave ━━━%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" > /dev/tty 2>/dev/null || true; fi
else
  if has_tty; then printf '\n %s%s━━━ Блок 4/4: Панель Remnawave ━━━%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" > /dev/tty 2>/dev/null || true; fi
fi
note "Панель управляет нодами, пользователями и подписками."
# === flags block end ===
}

write_env_store() {
( umask 077
  {
    printf 'export SERVER_IP=%q\n' "$SERVER_IP"
    printf 'export BASE_DOMAIN=%q\n' "$BASE_DOMAIN"
    printf 'export PREFIX=%q\n' "$PREFIX"
    printf 'export VLESS_HOST=%q\n' "$VLESS_HOST"
    printf 'export HY_HOST=%q\n' "$HY_HOST"
    printf 'export ACME_EMAIL=%q\n' "$ACME_EMAIL"
    printf 'export SELF_STEAL_HOST=%q\n' "$SELF_STEAL_HOST"
    printf 'export VISION_SNI=%q\n' "$VISION_SNI"
    # Оба решения (и «да», и «нет») сохраняются в читаемом виде y/n: иначе
    # ответ «n» терялся бы и повторный запуск включал функцию обратно по дефолту.
    printf 'export ENABLE_XHTTP=%s\n' "$(bool_yn "$ENABLE_XHTTP")"
    if (( ENABLE_XHTTP )); then
      printf 'export XHTTP_SNI=%q\n' "$XHTTP_SNI"
      printf 'export XHTTP_PATH=%q\n' "$XHTTP_PATH"
    fi
    printf 'export REALITY_MIN_CLIENT_VER=%q\n' "${REALITY_MIN_CLIENT_VER:-0.0.0}"
    printf 'export XHTTP_TARGET=%q\n' "${XHTTP_TARGET:-www.gstatic.com:443}"
    printf 'export ACME_METHOD=%q\n' "${ACME_METHOD:-auto}"
    printf 'export XRAY_LOG_DIR=%q\n' "${XRAY_LOG_DIR:-/var/log/remnanode/xray}"
    printf 'export ENABLE_CDN=%s\n' "$(bool_yn "$ENABLE_CDN")"
    if (( ENABLE_CDN )); then
      printf 'export CDN_HOST=%q\n' "$CDN_HOST"
      printf 'export CDN_TRANSPORT=%q\n' "$CDN_TRANSPORT"
      printf 'export CDN_WS_PATH=%q\n' "$CDN_WS_PATH"
      printf 'export CDN_XHTTP_PATH=%q\n' "$CDN_XHTTP_PATH"
      printf 'export CDN_GRPC_PATH=%q\n' "$CDN_GRPC_PATH"
    fi
    printf 'export PANEL_IP=%q\n' "${PANEL_IP:-}"
    printf 'export NODE_API_PORT=%q\n' "${NODE_API_PORT:-2222}"
    # Образ тоже сохраняем: иначе повторный запуск без --node-image вернёт latest.
    printf 'export NODE_IMAGE=%q\n' "${NODE_IMAGE:-remnawave/node:3.4.4}"
    if [[ -n "${CUSTOM_CORE_URL:-}" ]]; then
      printf 'export CUSTOM_CORE_URL=%q\n' "$CUSTOM_CORE_URL"
    fi
    # Новые интерактивные ответы — сохраняем для идемпотентного повторного запуска
    printf 'export NODE_TAG=%q\n' "$(panel_node_tag)"
    printf 'export SELF_STEAL_TEMPLATE=%q\n' "${SELF_STEAL_TEMPLATE:-vaultdrop}"
    if [[ -n "${SELF_STEAL_TEMPLATE_URL:-}" ]]; then
      printf 'export SELF_STEAL_TEMPLATE_URL=%q\n' "$SELF_STEAL_TEMPLATE_URL"
    fi
    printf 'export XRAY_TEMPLATE_CHOICE=%q\n' "${XRAY_TEMPLATE_CHOICE:-standard}"
    printf 'export CF_MODE=%s\n' "$(bool_yn "${CF_MODE:-0}")"
    printf 'export QUICK_SETUP=%s\n' "$(bool_yn "${QUICK_SETUP:-0}")"
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      printf 'export CLOUDFLARE_API_TOKEN=%q\n' "$CLOUDFLARE_API_TOKEN"
    fi
    if [[ -n "${CLOUDFLARE_ZONE:-}" ]]; then
      printf 'export CLOUDFLARE_ZONE=%q\n' "$CLOUDFLARE_ZONE"
    fi
    printf 'export REMNAWAVE_AUTO_SETUP=%s\n' "$(bool_yn "${REMNAWAVE_AUTO_SETUP:-0}")"
    if [[ -n "${REMNAWAVE_PANEL_URL:-}" ]]; then
      printf 'export REMNAWAVE_PANEL_URL=%q\n' "$REMNAWAVE_PANEL_URL"
    fi
    if [[ -n "${REMNAWAVE_API_TOKEN:-}" ]]; then
      printf 'export REMNAWAVE_API_TOKEN=%q\n' "$REMNAWAVE_API_TOKEN"
    fi
  } > "$ENV_STORE"
)
# Redirection не меняет права уже существующего файла: если ENV_STORE когда-то
# создан с 0644, токены остались бы читаемыми. Приводим к 0600 явно.
chmod 600 "$ENV_STORE"
}
