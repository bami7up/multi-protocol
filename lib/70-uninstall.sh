# --- --uninstall/--dry-run ---
remove_ufw_comment_rules() {
  local comment="$1" rule_no
  local -a rule_numbers=()
  mapfile -t rule_numbers < <(
    ufw status numbered 2>/dev/null \
      | sed -n "/${comment}/s/^[[:space:]]*\[[[:space:]]*\([0-9]\+\)\].*/\1/p" \
      | sort -rn
  )
  for rule_no in "${rule_numbers[@]}"; do
    run_cmd ufw --force delete "$rule_no" || warn "Не удалось удалить ufw-правило №$rule_no ($comment)."
  done
}

is_safe_remove_path() {
  local p="${1:-}"
  [[ "$p" == /* && "$p" != "/" && "$p" != "/root" && "$p" != "/etc" \
      && "$p" != "/usr" && "$p" != "/var" && "$p" != "/opt" \
      && "$p" != "/home" && "$p" != *"/../"* && "$p" != *"/.." ]]
}

run_cmd() {
  if (( DRY_RUN )); then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

uninstall_node() {
  local bashrc_tmp=""
  is_safe_remove_path "$NODE_DIR" || die "Отказ: небезопасный NODE_DIR для удаления: $NODE_DIR"
  is_safe_remove_path "$CERT_DIR" || die "Отказ: небезопасный CERT_DIR для удаления: $CERT_DIR"
  is_safe_remove_path "$ENV_STORE" || die "Отказ: небезопасный ENV_STORE для удаления: $ENV_STORE"
  is_safe_remove_path "$SELF_STEAL_ROOT" || die "Отказ: небезопасный SELF_STEAL_ROOT для удаления: $SELF_STEAL_ROOT"
  is_safe_remove_path "$XRAY_LOG_DIR" || die "Отказ: небезопасный XRAY_LOG_DIR для удаления: $XRAY_LOG_DIR"
  [[ "$(basename "$ENV_STORE")" == *remnanode* || "$(basename "$ENV_STORE")" == *.env ]] \
    || die "Отказ: ENV_STORE не похож на файл установщика: $ENV_STORE"
  if (( ! DRY_RUN )); then
    confirm "Удалить управляемые компоненты (нода remnanode, Caddyfile, сертификаты, UFW-правила, env-файл)?" "n" \
      || die "Отменено."
  fi
  note "План удаления: $NODE_DIR, $CERT_DIR, $SELF_STEAL_ROOT, $XRAY_LOG_DIR, $ENV_STORE, Caddyfile, UFW-правила."
  note "Пакеты Docker/Caddy/acme.sh/ufw и их данные не удаляются."

  if have docker && docker info >/dev/null 2>&1; then
    if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
      run_cmd docker compose -f "$NODE_DIR/docker-compose.yml" --project-directory "$NODE_DIR" down --remove-orphans \
        || warn "docker compose down завершился с ошибкой."
    else
      run_cmd docker rm -f remnanode || true
    fi
  else
    warn "Docker недоступен — контейнер remnanode не остановлен."
  fi

  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    if (( DRY_RUN )); then
      note "[dry-run] удалить managed-правила UFW (панель → нода, 80/443)"
    else
      remove_managed_ufw_rules || true
    fi
    remove_ufw_comment_rules 'VLESS via Caddy L4'
    remove_ufw_comment_rules 'Hysteria2 QUIC'
    remove_ufw_comment_rules 'acme.sh standalone'
  else
    warn "UFW не активен — правила не трогаю."
  fi

  # WARP снимаем до Caddy: правило fwmark и MSS-clamp не должны пережить
  # удаление, иначе помеченный трафик уходил бы в никуда.
  if [[ -f /etc/systemd/system/remnawave-warp-watchdog.service || -f "$WARP_CONF" ]]; then
    if (( DRY_RUN )); then
      note "[dry-run] снять WARP: wg-quick@$WARP_IFACE, watchdog, ip rule fwmark $WARP_FWMARK, $WARP_CONF"
    else
      warp_disable || warn "Не удалось полностью удалить WARP — проверьте ip rule и ip link."
    fi
  fi

  if have systemctl; then
    run_cmd systemctl stop caddy || true
    run_cmd systemctl disable caddy || true
  fi
  if have apt-mark; then
    run_cmd apt-mark unhold caddy || true
  fi
  run_cmd rm -f /etc/caddy/Caddyfile
  if [[ -d /etc/caddy ]]; then
    run_cmd find /etc/caddy -maxdepth 1 -type f -name 'Caddyfile.backup-*' -delete
  fi
  run_cmd rm -rf -- "$NODE_DIR" "$CERT_DIR" "$SELF_STEAL_ROOT" "$XRAY_LOG_DIR"
  run_cmd rm -f /etc/sysctl.d/99-remnanode.conf /etc/modules-load.d/bbr.conf /etc/security/limits.d/99-remnanode.conf
  run_cmd rm -f /etc/logrotate.d/remnanode-xray
  run_cmd rm -f /var/log/remnanode-setup-*.log

  if [[ -f "$ENV_STORE" ]]; then
    if (( DRY_RUN )); then
      printf '   [dry-run] rm -f %s\n' "$ENV_STORE"
      printf '   [dry-run] убрать source %s из /root/.bashrc\n' "$ENV_STORE"
    else
      rm -f -- "$ENV_STORE"
      if [[ -f /root/.bashrc ]]; then
        bashrc_tmp="$(mktemp /root/.bashrc.XXXXXX)"
        if ( umask 077; grep -vF "source $ENV_STORE" /root/.bashrc > "$bashrc_tmp" ); then
          cat "$bashrc_tmp" > /root/.bashrc
        else
          warn "Не удалось обновить /root/.bashrc — уберите source $ENV_STORE вручную."
        fi
        rm -f "$bashrc_tmp"
      fi
    fi
  fi

  if have sysctl; then
    run_cmd sysctl --system || true
  fi
  ok "Удаление завершено. Caddy/acme.sh/Docker/ufw-пакеты оставлены; при необходимости удалите их вручную."
}
