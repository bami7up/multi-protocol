#!/usr/bin/env bash
# selfcheck.sh — периодическая проверка работающей ноды multi-protocol.
#
# Проверяет то, что установщик проверяет только в момент установки:
#   * срок сертификатов в CERT_DIR (порог: <14 дней — предупреждение,
#     истёк/осталось <7 — ошибка);
#   * локальный TLS self-steal сайта (127.0.0.1:9443);
#   * доступность CDN-хоста и типичные ошибки Cloudflare 525/526/530
#     (обычно это не продлившийся origin-сертификат или Full (strict));
#   * слушатели 443/tcp, 443/udp, Node API и loopback-порты Xray;
#   * WARP (если включён): активность туннеля, правило fwmark, rp_filter,
#     свежесть хэндшейка;
#   * свободное место на /.
#
# Запуск:
#   bash selfcheck.sh            # читает /root/remnanode.env, если он есть
#   ENV_STORE=/path bash selfcheck.sh
#   bash selfcheck.sh --quiet    # печатать только проблемы
#
# Код возврата: 0 — всё в порядке, 1 — есть предупреждения, 2 — ошибки.
# Скрипт ничего не меняет и не требует токенов: только чтение и сетевые probe.
set -uo pipefail

ENV_STORE="${ENV_STORE:-/root/remnanode.env}"
CERT_DIR="${CERT_DIR:-/etc/remna-certs}"
SELF_STEAL_TLS_PORT="${SELF_STEAL_TLS_PORT:-9443}"
NODE_API_PORT="${NODE_API_PORT:-2222}"
WARP_IFACE="${WARP_IFACE:-warp}"
WARP_FWMARK="${WARP_FWMARK:-255}"
WARP_TABLE="${WARP_TABLE:-51820}"
WARN_DAYS=14
CRIT_DAYS=7
QUIET=0
WARNINGS=0
ERRORS=0

for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'Неизвестный аргумент: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

note() { (( QUIET )) || printf '   %s\n' "$*"; }
ok()   { (( QUIET )) || printf ' ✔ %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf ' ▲ %s\n' "$*" >&2; }
fail() { ERRORS=$((ERRORS + 1)); printf ' ✖ %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ -r "$ENV_STORE" ]]; then
  # ENV_STORE — управляемый установщиком файл; альтернативный путь задаётся явно.
  # shellcheck disable=SC1090
  . "$ENV_STORE"
  note "Переменные загружены из $ENV_STORE"
else
  note "ENV_STORE $ENV_STORE не найден — использую значения по умолчанию/окружение"
fi

CERT_DIR="${CERT_DIR:-/etc/remna-certs}"
NODE_API_PORT="${NODE_API_PORT:-2222}"
SELF_STEAL_TLS_PORT="${SELF_STEAL_TLS_PORT:-9443}"

printf '\n== Сертификаты (%s) ==\n' "$CERT_DIR"
if [[ -d "$CERT_DIR" ]]; then
  found=0
  while IFS= read -r crt; do
    found=1
    domain="$(basename "$(dirname "$crt")")"
    if ! end="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2-)"; then
      fail "$domain: сертификат не читается ($crt)"
      continue
    fi
    end_epoch="$(LC_ALL=C date -d "$end" +%s 2>/dev/null || echo 0)"
    days=$(( (end_epoch - $(date +%s)) / 86400 ))
    if (( days < 0 )); then
      fail "$domain: сертификат истёк ($end)"
    elif (( days < CRIT_DAYS )); then
      fail "$domain: осталось ${days} дн. — срочно проверьте acme.sh --cron"
    elif (( days < WARN_DAYS )); then
      warn "$domain: осталось ${days} дн. — проверьте автопродление acme.sh"
    else
      ok "$domain: ${days} дн."
    fi
  done < <(find "$CERT_DIR" -mindepth 2 -maxdepth 2 -type f -name 'fullchain.pem' 2>/dev/null | sort)
  (( found )) || warn "в $CERT_DIR нет fullchain.pem — проверьте CERT_DIR"
else
  fail "каталог сертификатов $CERT_DIR не найден"
fi

printf '\n== Локальный self-steal TLS ==\n'
if [[ -n "${SELF_STEAL_HOST:-}" ]] && have openssl; then
  if out="$(timeout 10 openssl s_client -connect "127.0.0.1:$SELF_STEAL_TLS_PORT" \
      -servername "$SELF_STEAL_HOST" -verify_hostname "$SELF_STEAL_HOST" \
      -verify_return_error -brief </dev/null 2>&1)" \
      && grep -Eq 'CONNECTION ESTABLISHED|Protocol version:' <<<"$out"; then
    ok "127.0.0.1:$SELF_STEAL_TLS_PORT отвечает валидным TLS для $SELF_STEAL_HOST"
  else
    fail "TLS self-steal не прошёл: $(head -1 <<<"$out")"
  fi
else
  warn "SELF_STEAL_HOST не задан или openssl нет — проверка TLS пропущена"
fi

printf '\n== CDN origin ==\n'
cdn_on="${ENABLE_CDN:-n}"; cdn_on="${cdn_on,,}"
if [[ "$cdn_on" =~ ^(1|y|yes|true|on)$ && -n "${CDN_HOST:-}" ]] && have curl; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$CDN_HOST/" 2>/dev/null || echo 000)"
  case "$code" in
    525|526|530)
      fail "CDN $CDN_HOST вернул $code: проверьте origin-сертификат (DNS-01/продление) и SSL/TLS mode Full (strict)" ;;
    000)
      fail "CDN $CDN_HOST недоступен (таймаут/DNS/TLS)" ;;
    2??|3??)
      ok "CDN $CDN_HOST отвечает $code" ;;
    4??)
      warn "CDN $CDN_HOST отвечает $code — проверьте DNS-запись и CDN-домен" ;;
    *)
      warn "CDN $CDN_HOST отвечает $code — проверьте Cloudflare/origin" ;;
  esac
  if have openssl; then
    if out="$(timeout 10 openssl s_client -connect "127.0.0.1:${CDN_TLS_PORT:-9444}" \
        -servername "$CDN_HOST" -verify_hostname "$CDN_HOST" -verify_return_error -brief \
        </dev/null 2>&1)" \
        && grep -Eq 'CONNECTION ESTABLISHED|Protocol version:' <<<"$out"; then
      ok "origin 127.0.0.1:${CDN_TLS_PORT:-9444} отдаёт валидный TLS для $CDN_HOST"
    else
      fail "origin TLS для $CDN_HOST не прошёл — CDN вернёт 526"
    fi
  fi
else
  note "CDN выключен или CDN_HOST не задан — проверка пропущена"
fi

printf '\n== Слушатели ==\n'
if have ss; then
  for spec in "tcp:443" "udp:443" "tcp:$NODE_API_PORT" \
              "tcp:9443" "tcp:10443" "tcp:10444"; do
    proto="${spec%%:*}"; port="${spec##*:}"
    if [[ "$proto" == tcp ]]; then
      if ss -H -lnt "sport = :$port" 2>/dev/null | grep -q .; then
        ok "TCP/$port слушает"
      else
        fail "TCP/$port не слушает"
      fi
    else
      if ss -H -lnu "sport = :$port" 2>/dev/null | grep -q .; then
        ok "UDP/$port слушает"
      else
        fail "UDP/$port не слушает (Hysteria2?)"
      fi
    fi
  done
else
  warn "ss не установлен — проверка слушателей пропущена"
fi

printf '\n== WARP (исходящий туннель) ==\n'
warp_on="${ENABLE_WARP:-n}"; warp_on="${warp_on,,}"
if [[ "$warp_on" =~ ^(1|y|yes|true|on)$ ]] && have systemctl; then
  iface="${WARP_IFACE:-warp}"
  mark="${WARP_FWMARK:-255}"
  table="${WARP_TABLE:-51820}"
  if systemctl is-active --quiet "wg-quick@$iface" 2>/dev/null; then
    ok "туннель $iface активен"
  else
    fail "wg-quick@$iface не активен — AI-сервисы пойдут с реального IP (remnawave-warp start)"
  fi
  # Пропажа правила — самая коварная поломка: туннель «активен», хэндшейк
  # свежий, а помеченные пакеты Xray уходят мимо него.
  if have ip && ip rule show 2>/dev/null \
      | grep -q "fwmark 0x$(printf '%x' "$mark") lookup ${table}"; then
    ok "правило fwmark $mark → table $table на месте"
  else
    fail "нет правила fwmark $mark → table $table (трафик Xray идёт мимо WARP)"
  fi
  rp_all="$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 0)"
  if [[ "$rp_all" == 1 ]]; then
    fail "rp_filter=1 (strict): обратный трафик туннеля будет теряться"
  else
    ok "rp_filter=${rp_all:-?} (обратный трафик проходит)"
  fi
  if have wg; then
    hs="$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
    if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then
      age=$(( $(date +%s) - hs ))
      if (( age > 180 )); then
        warn "хэндшейк $age s назад — watchdog переключит endpoint (remnawave-warp log)"
      else
        ok "хэндшейк ${age}s назад"
      fi
    else
      fail "хэндшейка нет — endpoint заблокирован или туннель не поднялся"
    fi
  fi
elif [[ "$warp_on" =~ ^(1|y|yes|true|on)$ ]]; then
  warn "systemctl нет — проверка WARP пропущена"
else
  note "WARP выключен (ENABLE_WARP=n) — проверка пропущена"
fi

printf '\n== Диск ==\n'
if have df; then
  use="$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  avail="$(df -Ph / | awk 'NR==2{print $4}')"
  if [[ "$use" =~ ^[0-9]+$ ]] && (( use >= 90 )); then
    fail "занято ${use}% на / (свободно $avail) — проверьте логи и docker system df"
  elif [[ "$use" =~ ^[0-9]+$ ]] && (( use >= 80 )); then
    warn "занято ${use}% на / (свободно $avail)"
  else
    ok "занято ${use}% на / (свободно $avail)"
  fi
else
  warn "df не установлен — проверка диска пропущена"
fi

printf '\n== Итог ==\n'
if (( ERRORS > 0 )); then
  printf ' ✖ ошибок: %d, предупреждений: %d\n' "$ERRORS" "$WARNINGS"
  exit 2
elif (( WARNINGS > 0 )); then
  printf ' ▲ предупреждений: %d\n' "$WARNINGS"
  exit 1
fi
printf ' ✔ всё в порядке\n'
exit 0
