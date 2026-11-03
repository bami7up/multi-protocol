# --- Интерактивное изменение настроек после установки (--reconfigure) ---

reconfigure_print_summary() {
  hr
  kv "SERVER_IP"        "${SERVER_IP:-}"
  kv "VLESS"            "${VLESS_HOST:-}"
  kv "HYSTERIA2"        "${HY_HOST:-}"
  kv "SELF_STEAL"       "${SELF_STEAL_HOST:-}"
  kv "Фасад"            "${SELF_STEAL_TEMPLATE:-vaultdrop}"
  if (( ${ENABLE_XHTTP:-0} )); then
    kv "XHTTP"          "SNI ${XHTTP_SNI:-}, path ${XHTTP_PATH:-}, target ${XHTTP_TARGET:-}"
  else
    kv "XHTTP"          "(выключен)"
  fi
  if (( ${ENABLE_CDN:-0} )); then
    kv "CDN"            "${CDN_HOST:-} (${CDN_TRANSPORT:-ws})"
  else
    kv "CDN"            "(выключен)"
  fi
  kv "minClientVer"     "${REALITY_MIN_CLIENT_VER:-0.0.0}"
  kv "ACME"             "${ACME_METHOD:-auto} (для новых сертификатов)"
  kv "Авто-панель"      "$([[ "${REMNAWAVE_AUTO_SETUP:-0}" == 1 ]] && echo да || echo нет)"
  hr
}

reconfigure_choose_theme() {
  local current="${SELF_STEAL_TEMPLATE:-vaultdrop}" default=1 i choice__
  if [[ -n "${SELF_STEAL_TEMPLATE_URL:-}" ]]; then
    default=7
  elif [[ "$current" == "$SELF_STEAL_TEMPLATE_NONE" ]]; then
    default=6
  else
    for i in "${!SELF_STEAL_TEMPLATES[@]}"; do
      if [[ "${SELF_STEAL_TEMPLATES[$i]}" == "$current" ]]; then
        default=$((i + 1))
        break
      fi
    done
  fi
  ask_choice choice__ "Фасад self-steal" "$default" \
    "vaultdrop: Файлообменник" \
    "mail: Почта" \
    "cloud: Облако" \
    "admin: Админ-панель" \
    "docs: Документация" \
    "none: Свой сайт (ничего не устанавливать)" \
    "custom: Свой URL с готовым index.html"
  case "$choice__" in
    custom)
      ask SELF_STEAL_TEMPLATE_URL "URL готового index.html (https://...)" "${SELF_STEAL_TEMPLATE_URL:-}"
      [[ "$SELF_STEAL_TEMPLATE_URL" == https://* ]] \
        || die "SELF_STEAL_TEMPLATE_URL должен начинаться с https://"
      ;;
    none)
      SELF_STEAL_TEMPLATE="$SELF_STEAL_TEMPLATE_NONE"
      SELF_STEAL_TEMPLATE_URL=""
      SELF_STEAL_TEMPLATE_EXPLICIT=1
      ;;
    *)
      SELF_STEAL_TEMPLATE="$choice__"
      SELF_STEAL_TEMPLATE_URL=""
      SELF_STEAL_TEMPLATE_EXPLICIT=1
      ;;
  esac
  unset choice__
  note "Фасад: ${SELF_STEAL_TEMPLATE}${SELF_STEAL_TEMPLATE_URL:+ ($SELF_STEAL_TEMPLATE_URL)}"
}

reconfigure_apply_theme() {
  local tmp
  if [[ "$SELF_STEAL_TEMPLATE" == "$SELF_STEAL_TEMPLATE_NONE" && -z "${SELF_STEAL_TEMPLATE_URL:-}" ]]; then
    mkdir -p "$SELF_STEAL_ROOT"
    if [[ -s "$SELF_STEAL_ROOT/index.html" ]]; then
      ok "Свой сайт сохранён: $SELF_STEAL_ROOT/index.html"
    else
      warn "SELF_STEAL_TEMPLATE=none, но $SELF_STEAL_ROOT/index.html отсутствует — self-steal будет отдавать 404."
    fi
    return 0
  fi
  resolve_self_steal_template
  mkdir -p "$SELF_STEAL_ROOT"
  tmp="$(mktemp)"
  if retry 3 3 curl -fsSL "$SELF_STEAL_TEMPLATE_URL" -o "$tmp"; then
    install -m 644 "$tmp" "$SELF_STEAL_ROOT/index.html"
    chmod -R a=rX "$SELF_STEAL_ROOT"
    ok "Фасад обновлён: $SELF_STEAL_TEMPLATE_URL"
  else
    rm -f "$tmp"
    die "Не удалось скачать фасад $SELF_STEAL_TEMPLATE_URL"
  fi
  rm -f "$tmp"
}

reconfigure_apply_protocols() {
  # prompt_flags спрашивает XHTTP/CDN; QUICK_SETUP=1 заставил бы его включить
  # всё без вопросов, поэтому на время выбора принудительно расширенный режим.
  local saved_quick="${QUICK_SETUP:-0}"
  QUICK_SETUP=0
  prompt_flags
  QUICK_SETUP="$saved_quick"
  unset saved_quick

  if (( ENABLE_XHTTP )); then
    while ! is_fqdn "${XHTTP_SNI:-}"; do
      ask XHTTP_SNI "Корректный SNI для XHTTP (домен)" "${XHTTP_SNI:-www.gstatic.com}"
    done
    while ! is_safe_xhttp_path "${XHTTP_PATH:-}"; do
      ask XHTTP_PATH "Корректный путь XHTTP (начинается с /)" "${XHTTP_PATH:-/api/v3/sync/r1}"
    done
  fi
  if (( ENABLE_CDN )); then
    while ! is_fqdn "${CDN_HOST:-}"; do
      ask CDN_HOST "Корректный CDN-домен" "${CDN_HOST:-cdn.${BASE_DOMAIN:-example.com}}"
    done
  fi
}

reconfigure_ensure_cdn_cert() {
  local acme="${ACME:-/root/.acme.sh/acme.sh}"
  (( ENABLE_CDN )) || return 0
  [[ -n "${CDN_HOST:-}" ]] || die "CDN включён, но CDN_HOST пуст."
  if [[ -s "$CERT_DIR/$CDN_HOST/fullchain.pem" && -s "$CERT_DIR/$CDN_HOST/key.pem" ]]; then
    return 0
  fi
  [[ -x "$acme" ]] || die "acme.sh не найден: $acme"
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] \
    || die "Для CDN-сертификата нужен CLOUDFLARE_API_TOKEN (DNS-01)."
  issue_cert_dns "$CDN_HOST" || die "Не удалось выпустить CDN-сертификат для $CDN_HOST."
  mkdir -p "$CERT_DIR/$CDN_HOST"
  "$acme" --install-cert -d "$CDN_HOST" --ecc \
    --key-file       "$CERT_DIR/$CDN_HOST/key.pem" \
    --fullchain-file "$CERT_DIR/$CDN_HOST/fullchain.pem" \
    --reloadcmd "systemctl restart caddy >/dev/null 2>&1 || true" \
    || die "Не удалось установить CDN-сертификат для $CDN_HOST."
  chown root:caddy "$CERT_DIR/$CDN_HOST/key.pem" "$CERT_DIR/$CDN_HOST/fullchain.pem" 2>/dev/null || true
  chmod 640 "$CERT_DIR/$CDN_HOST/key.pem" 2>/dev/null || true
  ok "CDN-сертификат установлен для $CDN_HOST"
}

reconfigure_apply() {
  (( ENABLE_XHTTP )) && ENABLE_XHTTP=1 || ENABLE_XHTTP=0
  (( ENABLE_CDN )) && ENABLE_CDN=1 || ENABLE_CDN=0

  if ! REALITY_MIN_CLIENT_VER="$(normalize_client_version "${REALITY_MIN_CLIENT_VER:-0.0.0}")"; then
    die "REALITY_MIN_CLIENT_VER: нужен вид 0.0.0."
  fi
  if ! XHTTP_TARGET="$(normalize_xhttp_target "${XHTTP_TARGET:-}")"; then
    die "XHTTP_TARGET: нужен host:port, self или local."
  fi
  acme_method_supported "$ACME_METHOD" \
    || die "ACME_METHOD: допустимо auto, dns или http."
  if [[ "$ACME_METHOD" == "dns" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    die "ACME_METHOD=dns требует CLOUDFLARE_API_TOKEN — иначе новые сертификаты не выпустятся."
  fi
  if ! is_safe_path "$SELF_STEAL_ROOT" || ! is_safe_remove_path "$SELF_STEAL_ROOT"; then
    die "Некорректный SELF_STEAL_ROOT: $SELF_STEAL_ROOT"
  fi

  # Флаги транспортов CDN вычисляются из CDN_TRANSPORT, иначе render_caddyfile
  # не добавит маршруты после смены транспорта.
  CDN_WS_ENABLED=0; CDN_XHTTP_ENABLED=0; CDN_GRPC_ENABLED=0
  if (( ENABLE_CDN )); then
    cdn_transport_enabled ws && CDN_WS_ENABLED=1
    cdn_transport_enabled xhttp && CDN_XHTTP_ENABLED=1
    cdn_transport_enabled grpc && CDN_GRPC_ENABLED=1
  fi

  resolve_self_steal_template

  if [[ "${RECONFIGURE_THEME_DIRTY:-0}" == 1 ]]; then
    reconfigure_apply_theme
  fi
  reconfigure_ensure_cdn_cert

  write_env_store
  ok "Настройки сохранены в $ENV_STORE"

  write_config_profile
  write_xray_template

  have caddy || die "caddy не установлен — изменить Caddyfile нельзя."
  render_caddyfile
  caddy fmt --overwrite "$CADDYFILE_PATH" || warn "caddy fmt завершился с ошибкой — продолжаю."
  caddy validate --config "$CADDYFILE_PATH" || die "Caddyfile невалиден после изменений."
  systemctl restart caddy || die "Не удалось перезапустить Caddy."
  sleep 1
  systemctl is-active --quiet caddy || die "Caddy не поднялся после изменений."
  ok "Caddy перезапущен"

  if (( REMNAWAVE_AUTO_SETUP )) && [[ -n "${REMNAWAVE_API_TOKEN:-}" ]]; then
    note "Обновляю Config Profile, ноду и хосты в панели..."
    panel_auto_setup || warn "Авто-обновление панели завершилось с ошибкой — проверьте панель вручную."
  else
    warn "Авто-панель выключена: загрузите $NODE_DIR/Multiselect.json в Config Profiles и обновите хосты вручную."
    warn "Выключенные XHTTP/CDN-хосты сами не удаляются — удалите их в панели, если они больше не нужны."
  fi
  ok "Изменения применены."
}

run_reconfigure() {
  [[ -f "$ENV_STORE" ]] || die "Нет $ENV_STORE: сначала выполните установку."
  has_tty || die "--reconfigure требует интерактивный терминал."
  # shellcheck disable=SC1090
  source "$ENV_STORE"
  ENV_STORE_LOADED=1

  ENABLE_XHTTP="$(parse_bool "${ENABLE_XHTTP:-y}" 0)"
  ENABLE_CDN="$(parse_bool "${ENABLE_CDN:-n}" 0)"
  REMNAWAVE_AUTO_SETUP="$(parse_bool "${REMNAWAVE_AUTO_SETUP:-n}" 0)"
  REALITY_MIN_CLIENT_VER="${REALITY_MIN_CLIENT_VER:-0.0.0}"
  XHTTP_TARGET="${XHTTP_TARGET:-www.gstatic.com:443}"
  ACME_METHOD="${ACME_METHOD:-auto}"
  SELF_STEAL_ROOT="${SELF_STEAL_ROOT:-/var/www/remnanode-self-steal}"
  XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/remnanode/xray}"
  : "${CDN_TRANSPORT:=ws}" "${CDN_HOST:=}" "${CDN_WS_PATH:=/api/v1/stream}"
  : "${CDN_XHTTP_PATH:=/api/v3/sync/c1}" "${CDN_GRPC_PATH:=/api/v4/stream}"
  RECONFIGURE_THEME_DIRTY=0

  banner
  printf '\n %s%s%s\n' "${C_B:-}${C_CYN:-}" "Изменение настроек без переустановки" "${C_RST:-}"
  note "Меняются только выбранные параметры. Домены, NODE_TAG, NODE_IMAGE и CUSTOM_CORE_URL здесь не меняются:"
  note "для смены домена/тега/image запустите установщик заново (или задайте env и перезапустите)."

  local choice__
  while :; do
    reconfigure_print_summary
    printf '\n %sЧто изменить?%s\n' "${C_B:-}" "${C_RST:-}" > /dev/tty
    printf '   1) Тема self-steal\n' > /dev/tty
    printf '   2) XHTTP / CDN (SNI, путь, target, CDN-домен, транспорт)\n' > /dev/tty
    printf '   3) minClientVer REALITY\n' > /dev/tty
    printf '   4) ACME method (для новых сертификатов)\n' > /dev/tty
    printf '   0) Сохранить и применить\n' > /dev/tty
    printf '   q) Выйти без изменений\n' > /dev/tty
    ask choice__ "Выберите пункт" "0"
    case "${choice__,,}" in
      1)
        reconfigure_choose_theme
        RECONFIGURE_THEME_DIRTY=1
        ;;
      2)
        reconfigure_apply_protocols
        ;;
      3)
        ask REALITY_MIN_CLIENT_VER "Минимальная версия клиента REALITY (0.0.0 — совместимо с Mihomo)" "${REALITY_MIN_CLIENT_VER:-0.0.0}"
        while ! is_client_version "$REALITY_MIN_CLIENT_VER"; do
          warn "Нужен вид x.y.z (например 0.0.0 или 26.3.27)."
          ask REALITY_MIN_CLIENT_VER "Минимальная версия клиента REALITY" "0.0.0"
        done
        if [[ "$REALITY_MIN_CLIENT_VER" != "0.0.0" ]]; then
          warn "Значения выше 1.8.2 могут отсечь Mihomo (он представляется 1.8.2)."
        fi
        ;;
      4)
        __acme_default=1
        if [[ "$ACME_METHOD" == "dns" ]]; then __acme_default=2; fi
        if [[ "$ACME_METHOD" == "http" ]]; then __acme_default=3; fi
        ask_choice ACME_METHOD "ACME method" "$__acme_default" \
          "auto: DNS-01 при наличии Cloudflare-токена, иначе HTTP-01" \
          "dns: только DNS-01 (без остановки Caddy)" \
          "http: только HTTP-01 (краткий простой 443/tcp)"
        unset __acme_default
        warn "Уже выпущенные сертификаты продолжат продлеваться прежним способом; новое значение — для новых выпусков/перевыпуска."
        ;;
      0)
        reconfigure_apply
        exit 0
        ;;
      q|quit|exit)
        note "Выход без изменений."
        exit 0
        ;;
      *)
        warn "Введите 0, 1, 2, 3, 4 или q."
        ;;
    esac
  done
}
