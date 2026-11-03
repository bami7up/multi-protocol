# --- acme.sh и сертификаты ---
acme_cert_days_left() {
  local d="$1" home="${ACME_HOME:-/root/.acme.sh}" crt end end_epoch
  # Установщик всегда выпускает ec-256 и потом делает --install-cert --ecc.
  # RSA-сертификат старой версии считаем отсутствующим и перевыпускаем, иначе
  # install-cert --ecc упадёт после «пропускаю issue».
  crt="$home/${d}_ecc/${d}.crt"
  [[ -s "$crt" ]] || return 1
  end="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2-)" || return 1
  [[ -n "$end" ]] || return 1
  end_epoch="$(LC_ALL=C date -d "$end" +%s 2>/dev/null)" || return 1
  printf '%s' $((( end_epoch - $(date +%s) ) / 86400 ))
}

issue_cert() {
  local d="$1" listed=0 days
  local -a issue_args=(--issue --standalone -d "$d" --keylength ec-256 \
                        --pre-hook "$ACME_PRE_HOOK" --post-hook "$ACME_POST_HOOK")
  if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$d"; then
    listed=1
  fi
  if (( listed )); then
    if days="$(acme_cert_days_left "$d")" && (( days > 7 )); then
      ok "Сертификат для $d уже выпущен (осталось ${days} дн.) — пропускаю issue"
      return 0
    fi
    warn "Сертификат для $d отсутствует, нечитаем или истекает менее чем через 7 дней — перевыпускаю."
    issue_args+=(--force)
  fi
  if systemctl is-active --quiet caddy; then
    systemctl stop caddy || die "Не удалось освободить порт 80 для ACME."
    CADDY_RESTORE_NEEDED=1
    note "Caddy временно остановлен для ACME standalone challenge."
  fi
  if ss -H -lnt 'sport = :80' 2>/dev/null | grep -q .; then
    ss -H -lntp 'sport = :80' 2>/dev/null | sed 's/^/   /' || true
    die "Порт 80 занят другим процессом — ACME standalone challenge невозможен."
  fi
  if ! "$ACME" "${issue_args[@]}"; then
    warn "Не удалось выпустить сертификат для $d (проверьте DNS/порт 80)."
    return 1
  fi
}

issue_cert_dns() {
  local d="$1" listed=0 days token_hash token_marker token_changed=0
  local -a issue_args=(--issue --dns dns_cf -d "$d" --keylength ec-256)
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] \
    || { warn "Для DNS-01 сертификата $d нужен CLOUDFLARE_API_TOKEN."; return 1; }
  # acme.sh хранит CF_Token в своём конфиге и использует его при продлении.
  # Если токен сменился, валидный сертификат нельзя просто пропускать: cron
  # продолжит ходить старым токеном. Хэш маркера позволяет перевыпустить один
  # раз после ротации, не дожидаясь истечения.
  token_marker="${ACME%/*}/.remnanode-cf-token.sha256"
  token_hash="$(printf '%s' "$CLOUDFLARE_API_TOKEN" | sha256sum | awk '{print $1}')"
  if [[ -f "$token_marker" ]]; then
    [[ "$(cat "$token_marker" 2>/dev/null || true)" == "$token_hash" ]] || token_changed=1
  else
    token_changed=1
  fi
  if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$d"; then
    listed=1
  fi
  if (( listed )); then
    if (( ! token_changed )) && days="$(acme_cert_days_left "$d")" && (( days > 7 )); then
      ok "Сертификат для $d уже выпущен (осталось ${days} дн.) — пропускаю issue"
      return 0
    fi
    if (( token_changed )); then
      warn "Cloudflare-токен изменился — перевыпускаю сертификат $d, чтобы acme.sh сохранил новые креды."
    else
      warn "Сертификат для $d отсутствует, нечитаем или истекает — перевыпускаю через DNS-01."
    fi
    issue_args+=(--force)
  fi
  # dns_cf читает CF_Token; CF_Zone_ID избавляет от повторного поиска зоны.
  # Но он относится к конкретной зоне: для домена из другой зоны (CDN-домен
  # может жить отдельно от доменов ноды) его подставлять нельзя. Запуск в
  # подоболочке не даёт временным CF_* протечь в следующие вызовы.
  if ! (
    export CF_Token="$CLOUDFLARE_API_TOKEN"
    if [[ -n "${CF_ZONE_ID:-}" && -n "${CF_ZONE_NAME:-}" ]] \
        && { [[ "$d" == "$CF_ZONE_NAME" || "$d" == *."$CF_ZONE_NAME" ]]; }; then
      export CF_Zone_ID="$CF_ZONE_ID"
    fi
    "$ACME" "${issue_args[@]}"
  ); then
    warn "Не удалось выпустить сертификат для $d через DNS-01: проверьте права токена (Zone:Read + DNS:Edit) и CLOUDFLARE_ZONE."
    return 1
  fi
  ( umask 077; printf '%s\n' "$token_hash" > "$token_marker" )
}

ACME_PRE_HOOK='systemctl stop caddy >/dev/null 2>&1 || true'
ACME_POST_HOOK='systemctl start caddy >/dev/null 2>&1 || true'

issue_cert_selected() {
  # Единая точка выбора ACME-метода для self-steal и Hysteria2. DNS-01 не
  # останавливает Caddy и не рвёт активные 443/tcp-соединения; HTTP-01 —
  # вынужденный fallback без Cloudflare-токена.
  local d="$1" method
  method="$(acme_method_resolved)"
  case "$method" in
    dns)
      if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        warn "ACME_METHOD=$ACME_METHOD, но CLOUDFLARE_API_TOKEN пуст — DNS-01 невозможен."
        return 1
      fi
      note "ACME для $d: DNS-01 (Caddy не останавливается, 443/tcp не рвётся)"
      if issue_cert_dns "$d"; then
        return 0
      fi
      # auto — это «DNS при возможности»: токен может видеть только зону CDN,
      # а домены ноды жить в другой зоне. Явный dns не откатывается.
      if [[ "$ACME_METHOD" == "dns" ]]; then
        return 1
      fi
      warn "DNS-01 для $d не удался (токен не видит зону?) — откатываюсь на HTTP-01."
      issue_cert "$d"
      ;;
    http)
      warn "ACME для $d: HTTP-01 — Caddy будет кратко остановлен, 443/tcp может прерваться."
      issue_cert "$d"
      ;;
  esac
}

