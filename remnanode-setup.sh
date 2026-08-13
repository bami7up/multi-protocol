#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_COMPOSE=1
MANAGE_FIREWALL=1
RESET_FIREWALL=0
FORCE_DNS=0
ASSUME_YES="${ASSUME_YES:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
SSH_PORT_OVERRIDE=""
NODE_DIR="${NODE_DIR:-/opt/remnanode}"
CERT_DIR="${CERT_DIR:-/etc/remna-certs}"
ENV_STORE="${ENV_STORE:-/root/remnanode.env}"
NODE_IMAGE="${NODE_IMAGE:-remnawave/node:3.1.1}"
SELF_STEAL_TEMPLATE_URL="${SELF_STEAL_TEMPLATE_URL:-https://raw.githubusercontent.com/bami7up/multi-protocol/main/self-steal-site.html}"
XCADDY_VERSION="${XCADDY_VERSION:-v0.4.5}"
CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"
CADDY_L4_VERSION="${CADDY_L4_VERSION:-v0.1.2}"
GO_VERSION="1.25.1"
GO_INSTALL_TMP=""
GO_ARCHIVE_TMP=""
CADDY_RESTORE_NEEDED=0
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/remnanode-setup-$(date +%F-%H%M%S).log"

usage() {
  cat <<'USAGE'
remnanode-setup.sh — установка ноды Remnawave (VLESS + Trojan + Hysteria2 за Caddy L4)

Использование:
  bash remnanode-setup.sh [флаги]

Флаги:
  --no-compose          не трогать docker-compose.yml (только .env + up -d)
  --no-firewall         не настраивать ufw
  --reset-firewall      сбросить существующие правила ufw перед настройкой
  --force-dns           не прерываться при несовпадении DNS
  --ssh-port N          явно указать SSH-порт для правила ufw
  --node-image REF      образ ноды (по умолчанию remnawave/node:3.1.1)
  -y | --yes            авто-подтверждение всех «y/n» вопросов
  --non-interactive     не задавать вопросы: все значения из env/дефолтов
  -h | --help           показать эту справку

Переменные окружения (для --non-interactive / CI):
  BASE_DOMAIN, PREFIX, SELF_STEAL_HOST, XHTTP_SNI, XHTTP_PATH,
  PANEL_IP, NODE_API_PORT, SECRET_KEY, NODE_IMAGE, SELF_STEAL_TEMPLATE_URL,
  XCADDY_VERSION, CADDY_VERSION, CADDY_L4_VERSION
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-compose)  BUILD_COMPOSE=0 ;;
    --no-firewall) MANAGE_FIREWALL=0 ;;
    --reset-firewall) RESET_FIREWALL=1 ;;
    --no-reset-firewall) RESET_FIREWALL=0 ;; # совместимость со старыми командами
    --force-dns)   FORCE_DNS=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --non-interactive) NONINTERACTIVE=1; ASSUME_YES=1 ;;
    --ssh-port)
      SSH_PORT_OVERRIDE="${2:-}"
      [[ "$SSH_PORT_OVERRIDE" =~ ^[0-9]+$ ]] || { echo "--ssh-port требует число" >&2; exit 2; }
      shift ;;
    --node-image)
      NODE_IMAGE="${2:-}"
      [[ -n "$NODE_IMAGE" ]] || { echo "--node-image требует значение" >&2; exit 2; }
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -t 1 || "${FORCE_COLOR:-0}" == 1 ]]; then
  C_RST=$'\033[0m';  C_B=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[38;5;203m'; C_GRN=$'\033[38;5;114m'; C_YLW=$'\033[38;5;221m'
  C_BLU=$'\033[38;5;75m';  C_CYN=$'\033[38;5;80m';  C_MAG=$'\033[38;5;177m'
  C_GRY=$'\033[38;5;245m'; C_WHT=$'\033[38;5;255m'
else
  C_RST=; C_B=; C_DIM=; C_RED=; C_GRN=; C_YLW=; C_BLU=; C_CYN=; C_MAG=; C_GRY=; C_WHT=
fi

RULE='────────────────────────────────────────────────────────────────'
STEP_TOTAL=10

hr()   { printf '%s%s%s\n' "$C_DIM$C_GRY" "$RULE" "$C_RST"; }
log()  { printf ' %s➜%s %s\n'  "$C_BLU$C_B" "$C_RST" "$*"; }
ok()   { printf ' %s✔%s %s\n'  "$C_GRN$C_B" "$C_RST" "$*"; }
warn() { printf ' %s▲%s %s\n'  "$C_YLW$C_B" "$C_RST" "$*"; }
note() { printf '   %s%s%s\n'  "$C_DIM$C_GRY" "$*" "$C_RST"; }
die()  { printf ' %s✖%s %s\n'  "$C_RED$C_B" "$C_RST" "$*" >&2; exit 1; }

step() {
  local cur="$1" title="$2"
  printf '\n%s%s┏━ %s[ %02d / %02d ]%s %s%s%s%s\n' \
    "$C_B" "$C_CYN" "$C_RST$C_B$C_YLW" "$cur" "$STEP_TOTAL" \
    "$C_RST" "$C_B$C_CYN" "$title" "$C_RST" ""
  printf '%s%s┗%s%s%s\n' "$C_B" "$C_CYN" "$C_RST" "$C_DIM$C_GRY" "$RULE${C_RST}"
}

banner() {
  local L="$C_B$C_WHT" T="$C_B$C_MAG" D="$C_DIM$C_GRY" A="$C_B$C_CYN" S="$C_DIM$C_GRY" R="$C_RST"
  printf '%s\n' \
    "${D}╭──────────────────────────────────────────────────────────────╮${R}" \
    "${D}│${R}                                                              ${D}│${R}" \
    "${D}│${R}  ${L}▄█▀▄ ${R}  ${T}██╗      █████╗ ████████╗███████╗██╗  ██╗${R}            ${D}│${R}" \
    "${D}│${R}  ${L}▀ █  ${R}  ${T}██║     ██╔══██╗╚══██╔══╝██╔════╝╚██╗██╔╝${R}            ${D}│${R}" \
    "${D}│${R}  ${L}  █  ${R}  ${T}██║     ███████║   ██║   █████╗   ╚███╔╝ ${R}            ${D}│${R}" \
    "${D}│${R}  ${L}  █▄▟${R}  ${T}██║     ██╔══██║   ██║   ██╔══╝   ██╔██╗ ${R}            ${D}│${R}" \
    "${D}│${R}  ${L}  ▀█▀${R}  ${T}███████╗██║  ██║   ██║   ███████╗██╔╝ ██╗${R}            ${D}│${R}" \
    "${D}│${R}  ${L}     ${R}  ${T}╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝${R}            ${D}│${R}" \
    "${D}│${R}                                                              ${D}│${R}" \
    "${D}│${R}  ${A}REMNAWAVE NODE · VLESS · Trojan · Hysteria2 · Caddy L4${R}      ${D}│${R}" \
    "${D}│${R}  ${S}by Latex · github.com/1atex${R}                                 ${D}│${R}" \
    "${D}╰──────────────────────────────────────────────────────────────╯${R}"
}

kv() { printf '   %s%-14s%s %s%s%s\n' "$C_GRY" "$1" "$C_RST" "$C_B" "$2" "$C_RST"; }

retry() {
  local -i tries="$1" delay="$2"; shift 2
  local -i n=1
  until "$@"; do
    if (( n >= tries )); then
      warn "Команда так и не удалась после ${tries} попыток: $*"
      return 1
    fi
    warn "Попытка ${n}/${tries} не удалась, повтор через ${delay}s: $*"
    sleep "$delay"
    n=$((n + 1))
  done
}

prune_matching_files() {
  local dir="$1" pattern="$2" keep="$3" i
  local -a files=()
  [[ -d "$dir" ]] || return 0
  mapfile -t files < <(
    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | sed 's/^[^ ]* //'
  )
  for ((i = keep; i < ${#files[@]}; i++)); do
    rm -f -- "${files[$i]}"
  done
}

remove_managed_ufw_rules() {
  local rule_no
  local -a rule_numbers=()
  mapfile -t rule_numbers < <(
    ufw status numbered 2>/dev/null \
      | sed -n '/Remnawave panel -> node/s/^[[:space:]]*\[[[:space:]]*\([0-9]\+\)\].*/\1/p' \
      | sort -rn
  )
  for rule_no in "${rule_numbers[@]}"; do
    ufw --force delete "$rule_no" >/dev/null \
      || warn "Не удалось удалить старое управляемое правило ufw №$rule_no."
  done
  if (( ${#rule_numbers[@]} > 0 )); then
    ok "Старые правила доступа панели к Node API удалены: ${#rule_numbers[@]}"
  fi
}

install_go_toolchain() {
  local go_arch go_sha go_root archive
  case "$ARCH" in
    x86_64|amd64)
      go_arch=amd64
      go_sha=7716a0d940a0f6ae8e1f3b3f4f36299dc53e31b16840dbd171254312c41ca12e
      ;;
    aarch64|arm64)
      go_arch=arm64
      go_sha=65a3e34fb2126f55b34e1edfc709121660e1be2dee6bdf405fc399a63a95a87d
      ;;
    *) die "Нет Go toolchain для архитектуры $ARCH." ;;
  esac
  go_root="/opt/remnanode-toolchains/go${GO_VERSION}"
  if [[ -x "$go_root/bin/go" ]] \
      && [[ "$("$go_root/bin/go" version 2>/dev/null)" == "go version go${GO_VERSION} "* ]]; then
    export PATH="$go_root/bin:$PATH"
    ok "Go $GO_VERSION уже установлен в $go_root"
    return
  fi
  [[ ! -e "$go_root" ]] \
    || die "$go_root уже существует, но не содержит исправный Go $GO_VERSION; проверьте каталог вручную."

  mkdir -p /opt/remnanode-toolchains
  GO_INSTALL_TMP="$(mktemp -d /opt/remnanode-toolchains/.go-install.XXXXXX)"
  archive="$(mktemp)"
  GO_ARCHIVE_TMP="$archive"
  retry 3 10 curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" -o "$archive" \
    || die "Не удалось скачать Go $GO_VERSION."
  printf '%s  %s\n' "$go_sha" "$archive" | sha256sum -c - >/dev/null \
    || die "SHA256 архива Go $GO_VERSION не совпал."
  tar -xzf "$archive" -C "$GO_INSTALL_TMP" --strip-components=1 \
    || die "Не удалось распаковать Go $GO_VERSION."
  rm -f "$archive"
  GO_ARCHIVE_TMP=""
  "$GO_INSTALL_TMP/bin/go" version | grep -Fq "go version go${GO_VERSION} " \
    || die "Распакованный Go toolchain имеет неожиданную версию."
  mv "$GO_INSTALL_TMP" "$go_root"
  GO_INSTALL_TMP=""
  export PATH="$go_root/bin:$PATH"
  ok "Установлен проверенный Go $GO_VERSION ($go_arch)"
}

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запускать нужно от root (sudo -i)."; }

is_ipv4() {
  local ip="$1" a b c d extra octet
  IFS=. read -r a b c d extra <<<"$ip"
  [[ -z "$extra" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

is_fqdn() {
  local name="${1%.}" label
  local -a labels
  [[ ${#name} -le 253 && "$name" == *.* ]] || return 1
  IFS=. read -r -a labels <<<"$name"
  (( ${#labels[@]} >= 2 )) || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
  [[ "${labels[-1]}" =~ ^[a-zA-Z]{2,63}$ ]]
}

is_safe_xhttp_path() {
  local pattern='^/[a-zA-Z0-9._~!()*+,;=:@%/-]*$'
  [[ ${#1} -le 2048 && "$1" =~ $pattern ]]
}

apt_wait() {
  local -i waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock          >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock     >/dev/null 2>&1; do
    if (( waited % 60 == 0 )); then
      warn "Ожидаю освобождения apt/dpkg lock (прошло ${waited}s)..."
    fi
    sleep 5
    waited=$((waited + 5))
  done
}
apt_get() { apt_wait; DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    [[ -n "$__default" ]] || die "--non-interactive: нет значения для «$__prompt» (задайте через env)."
    printf -v "$__var" '%s' "$__default"
    note "(auto) $__prompt = $__default"
    return
  fi
  if [[ -n "$__default" ]]; then
    printf ' %s?%s %s %s[%s]%s: ' "$C_MAG$C_B" "$C_RST" "$__prompt" "$C_DIM$C_GRY" "$__default" "$C_RST" > /dev/tty
    IFS= read -r __input < /dev/tty || true
    __input="${__input:-$__default}"
  else
    __input=""
    while [[ -z "$__input" ]]; do
      printf ' %s?%s %s: ' "$C_MAG$C_B" "$C_RST" "$__prompt" > /dev/tty
      IFS= read -r __input < /dev/tty || true
    done
  fi
  printf -v "$__var" '%s' "$__input"
}

# confirm "вопрос" "дефолт(y/n)" -> 0 если да, 1 если нет; уважает --yes/--non-interactive
confirm() {
  local __prompt="$1" __default="${2:-n}" __ans
  if [[ "$ASSUME_YES" == 1 ]]; then
    note "(auto-yes) $__prompt"
    return 0
  fi
  ask __ans "$__prompt (y/n)" "$__default"
  [[ "${__ans,,}" == y* ]]
}

detect_ssh_port() {
  local port=""
  if have sshd; then
    port="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}' || true)"
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    port="$(awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
  fi
  if [[ ! "$port" =~ ^[0-9]+$ && -n "${SSH_CONNECTION:-}" ]]; then
    port="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] || port=22
  printf '%s' "$port"
}

require_root

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

on_err() {
  local ec=$? line=$1 cmd=$2
  printf '\n %s✖ НЕПРЕДВИДЕННЫЙ СБОЙ%s код=%s строка=%s\n   %s%s%s\n' \
    "$C_RED$C_B" "$C_RST" "$ec" "$line" "$C_DIM$C_GRY" "$cmd" "$C_RST" >&2
  printf '   Полный лог: %s\n' "$LOG_FILE" >&2
  exit "$ec"
}

on_exit() {
  local ec=$?
  trap - EXIT
  if [[ -n "${GO_INSTALL_TMP:-}" && -d "$GO_INSTALL_TMP" ]]; then
    rm -rf -- "$GO_INSTALL_TMP"
  fi
  if [[ -n "${GO_ARCHIVE_TMP:-}" && -f "$GO_ARCHIVE_TMP" ]]; then
    rm -f -- "$GO_ARCHIVE_TMP"
  fi
  if [[ "${CADDY_RESTORE_NEEDED:-0}" -eq 1 ]]; then
    if systemctl start caddy >/dev/null 2>&1; then
      CADDY_RESTORE_NEEDED=0
      warn "Caddy восстановлен после прерванной операции."
    else
      printf ' Не удалось восстановить Caddy после ACME; проверьте systemctl status caddy.\n' >&2
    fi
  fi
  exit "$ec"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT

echo
banner
note "Лог сессии: $LOG_FILE"

step 0 "Preflight — ОС, ядро, ресурсы"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  die "Не найден /etc/os-release."
fi
case "${ID:-}" in
  debian|ubuntu) ok "ОС: ${PRETTY_NAME:-$ID}" ;;
  *) die "Поддерживаются только Debian/Ubuntu (обнаружено: ${ID:-неизвестно})." ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64|aarch64|arm64) ok "Архитектура: $ARCH" ;;
  *) die "Неподдерживаемая архитектура: $ARCH." ;;
esac

KREL="$(uname -r)"
KMAJ="${KREL%%.*}"
KMIN="$(printf '%s' "$KREL" | cut -d. -f2)"
[[ "$KMAJ" =~ ^[0-9]+$ ]] || KMAJ=0
[[ "$KMIN" =~ ^[0-9]+$ ]] || KMIN=0
if (( KMAJ > 4 || (KMAJ == 4 && KMIN >= 9) )); then
  ok "Ядро: $KREL (BBR поддерживается)"
else
  warn "Ядро $KREL старое — BBR может быть недоступен."
fi

MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo 0)"
[[ "$MEM_MB" =~ ^[0-9]+$ ]] || MEM_MB=0
if (( MEM_MB < 900 )); then
  warn "RAM ${MEM_MB}MB — маловато, сборка caddy-l4 может свопиться."
else
  ok "RAM: ${MEM_MB}MB"
fi
DISK_MB="$(df -Pm / | awk 'NR==2{print $4}' 2>/dev/null || echo 0)"
[[ "$DISK_MB" =~ ^[0-9]+$ ]] || DISK_MB=0
if (( DISK_MB < 3000 )); then
  warn "Свободно ${DISK_MB}MB на / — Go+Docker могут не влезть."
else
  ok "Свободно на /: ${DISK_MB}MB"
fi

log "Устанавливаю базовые утилиты (curl, ca-certificates, dnsutils)"
retry 3 5 apt_get update -y || warn "apt-get update завершился с ошибкой — продолжаю с текущими списками."
retry 3 5 apt_get install -y curl ca-certificates dnsutils \
  || warn "Не удалось установить базовые утилиты — некоторые проверки будут ограничены."

step 1 "Переменные окружения"

if [[ -f "$ENV_STORE" ]]; then
  if confirm "Найден $ENV_STORE. Загрузить сохранённые переменные?" "y"; then
    # ENV_STORE — намеренно настраиваемый путь.
    # shellcheck disable=SC1090
    source "$ENV_STORE" || warn "Не удалось прочитать $ENV_STORE — продолжаю без него."
    ok "Переменные загружены из $ENV_STORE"
  fi
fi

SERVER_IP=""
if have curl; then
  SERVER_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$SERVER_IP" ]] || SERVER_IP="$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
if is_ipv4 "$SERVER_IP"; then
  ok "Публичный IPv4: $SERVER_IP"
else
  SERVER_IP=""
  warn "Не удалось определить IP (проверка DNS будет мягкой)."
fi

ask BASE_DOMAIN "Базовый домен (напр. example.com)" "${BASE_DOMAIN:-}"
ask PREFIX      "Префикс поддомена (напр. usa)"      "${PREFIX:-usa}"
VLESS_HOST="${PREFIX}1.${BASE_DOMAIN}"
TROJAN_HOST="${PREFIX}2.${BASE_DOMAIN}"
HY_HOST="${PREFIX}3.${BASE_DOMAIN}"
ok "Домены: $VLESS_HOST / $TROJAN_HOST / $HY_HOST"

ACME_EMAIL="admin@${BASE_DOMAIN}"
ok "Email для Let's Encrypt: $ACME_EMAIL"

ask SELF_STEAL_HOST "Домен self-steal для Vision/Reality" "${SELF_STEAL_HOST:-$VLESS_HOST}"
# Обратная совместимость с шаблонами/старыми env: для Vision SNI всегда равен
# домену локального TLS-сайта. Иначе это снова будет обычный внешний REALITY target.
VISION_SNI="$SELF_STEAL_HOST"
ask XHTTP_SNI  "Маскировочный SNI для XHTTP"          "${XHTTP_SNI:-www.gstatic.com}"
ask XHTTP_PATH "Путь XHTTP"                           "${XHTTP_PATH:-/api/v3/sync/r1}"
ask PANEL_IP   "IP панели Remnawave"                  "${PANEL_IP:-}"
ask NODE_API_PORT "Порт ноды для связи с панелью"     "${NODE_API_PORT:-2222}"

is_fqdn "$BASE_DOMAIN"       || die "Некорректный домен: $BASE_DOMAIN"
[[ "$PREFIX" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ && ${#PREFIX} -le 50 ]] \
  || die "Некорректный префикс: $PREFIX"
is_fqdn "$SELF_STEAL_HOST"   || die "Некорректный self-steal домен: $SELF_STEAL_HOST"
is_fqdn "$XHTTP_SNI"         || die "Некорректный XHTTP SNI: $XHTTP_SNI"
is_safe_xhttp_path "$XHTTP_PATH" || die "Некорректный XHTTP path: $XHTTP_PATH"
is_ipv4 "$PANEL_IP"          || die "Некорректный IP панели: $PANEL_IP"
{ [[ "$NODE_API_PORT" =~ ^[0-9]+$ ]] && (( NODE_API_PORT >= 1 && NODE_API_PORT <= 65535 )); } \
  || die "Некорректный порт ноды: $NODE_API_PORT"
case "$NODE_API_PORT" in
  80|443|9443|10443|10444|10445)
    die "Node API port $NODE_API_PORT занят этой схемой; выберите другой, например 2222."
    ;;
esac
ACTIVE_SSH_PORT="${SSH_PORT_OVERRIDE:-$(detect_ssh_port)}"
[[ "$NODE_API_PORT" != "$ACTIVE_SSH_PORT" ]] \
  || die "Node API port $NODE_API_PORT совпадает с SSH-портом; выберите другой порт ноды."
[[ "$SELF_STEAL_HOST" != "$TROJAN_HOST" && "$SELF_STEAL_HOST" != "$HY_HOST" ]] \
  || die "SELF_STEAL_HOST должен отличаться от доменов Trojan/Hysteria2."
[[ "$XHTTP_SNI" != "$SELF_STEAL_HOST" && "$XHTTP_SNI" != "$TROJAN_HOST" ]] \
  || die "XHTTP_SNI конфликтует с SNI другого маршрута Caddy."
[[ "$SELF_STEAL_TEMPLATE_URL" == https://* ]] \
  || die "SELF_STEAL_TEMPLATE_URL должен начинаться с https://"
[[ "$NODE_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]+$ ]] || die "Некорректная ссылка на образ: $NODE_IMAGE"
[[ "$XCADDY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Некорректная версия xcaddy: $XCADDY_VERSION"
[[ "$CADDY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Некорректная версия Caddy: $CADDY_VERSION"
[[ "$CADDY_L4_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Некорректная версия caddy-l4: $CADDY_L4_VERSION"

export SERVER_IP BASE_DOMAIN PREFIX VLESS_HOST TROJAN_HOST HY_HOST ACME_EMAIL \
       SELF_STEAL_HOST VISION_SNI XHTTP_SNI XHTTP_PATH PANEL_IP NODE_API_PORT

( umask 077
  {
    printf 'export SERVER_IP=%q\n' "$SERVER_IP"
    printf 'export BASE_DOMAIN=%q\n' "$BASE_DOMAIN"
    printf 'export PREFIX=%q\n' "$PREFIX"
    printf 'export VLESS_HOST=%q\n' "$VLESS_HOST"
    printf 'export TROJAN_HOST=%q\n' "$TROJAN_HOST"
    printf 'export HY_HOST=%q\n' "$HY_HOST"
    printf 'export ACME_EMAIL=%q\n' "$ACME_EMAIL"
    printf 'export SELF_STEAL_HOST=%q\n' "$SELF_STEAL_HOST"
    printf 'export VISION_SNI=%q\n' "$VISION_SNI"
    printf 'export XHTTP_SNI=%q\n' "$XHTTP_SNI"
    printf 'export XHTTP_PATH=%q\n' "$XHTTP_PATH"
    printf 'export PANEL_IP=%q\n' "$PANEL_IP"
    printf 'export NODE_API_PORT=%q\n' "$NODE_API_PORT"
  } > "$ENV_STORE"
)
grep -q "source $ENV_STORE" /root/.bashrc 2>/dev/null \
  || echo "[ -f $ENV_STORE ] && source $ENV_STORE" >> /root/.bashrc
ok "Переменные сохранены в $ENV_STORE (0600, подхват в .bashrc)"

echo
hr
kv "SERVER_IP"     "$SERVER_IP"
kv "VLESS"         "$VLESS_HOST"
kv "TROJAN"        "$TROJAN_HOST"
kv "HYSTERIA2"     "$HY_HOST"
kv "SELF_STEAL"    "$SELF_STEAL_HOST -> 127.0.0.1:9443"
kv "XHTTP_SNI"     "$XHTTP_SNI"
kv "PANEL_IP"      "$PANEL_IP"
kv "NODE_API_PORT" "$NODE_API_PORT"
hr
echo
confirm "Всё верно, продолжаем?" "y" || die "Отменено пользователем."

step 2 "Проверка DNS и SNI"
DNS_OK=1
declare -A DNS_SEEN=()
for d in "$VLESS_HOST" "$TROJAN_HOST" "$HY_HOST" "$SELF_STEAL_HOST"; do
  [[ "${DNS_SEEN[$d]:-0}" -eq 0 ]] || continue
  DNS_SEEN[$d]=1
  mapfile -t resolved_a < <(dig +short "$d" A 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' | sort -u)
  mapfile -t resolved_aaaa < <(dig +short "$d" AAAA 2>/dev/null | awk '/:/' | sort -u)
  resolved_a_text="$(IFS=,; printf '%s' "${resolved_a[*]:-<нет A-записи>}")"
  resolved_aaaa_text="$(IFS=,; printf '%s' "${resolved_aaaa[*]:-}")"
  if (( ${#resolved_a[@]} == 0 )); then
    warn "$d -> <нет A-записи>"; DNS_OK=0
  elif [[ -z "$SERVER_IP" ]]; then
    note "$d -> $resolved_a_text"
  elif (( ${#resolved_a[@]} == 1 )) && [[ "${resolved_a[0]}" == "$SERVER_IP" ]]; then
    ok "$d -> ${resolved_a[0]}"
  else
    warn "$d -> $resolved_a_text (должна быть единственная A-запись $SERVER_IP)"; DNS_OK=0
  fi
  if (( ${#resolved_aaaa[@]} > 0 )); then
    warn "$d имеет AAAA: $resolved_aaaa_text. Hysteria2 слушает только IPv4; удалите AAAA."; DNS_OK=0
  fi
done
if [[ "$DNS_OK" -eq 0 && "$FORCE_DNS" -eq 0 ]]; then
  confirm "DNS не совпадает — сертификаты могут не выпуститься. Продолжить?" "n" \
    || die "Прервано из-за DNS. Поправьте A-записи или запустите с --force-dns."
fi
proto="$(echo | timeout 8 openssl s_client -connect "$XHTTP_SNI:443" -servername "$XHTTP_SNI" -alpn h2 -tls1_3 -brief 2>&1 \
         | grep -Ei 'Protocol|ALPN' | tr '\n' ' ' || true)"
if [[ -n "$proto" ]]; then
  ok "SNI $XHTTP_SNI: $proto"
else
  warn "SNI $XHTTP_SNI: не удалось проверить TLS1.3/h2"
fi

step 3 "Базовые пакеты и Docker"
retry 3 5 apt_get update -y || warn "apt-get update с ошибкой — продолжаю."
retry 3 5 apt_get install -y curl gnupg debian-keyring debian-archive-keyring apt-transport-https \
                   ca-certificates lsb-release git jq unzip nano htop socat cron openssl \
                   ufw psmisc \
  || die "Не удалось установить базовые пакеты."

DOCKER_RESTART_REQUIRED=0
if ! have docker; then
  retry 3 10 bash -c 'curl -fsSL https://get.docker.com | sh' \
    || die "Не удалось установить Docker через get.docker.com."
  DOCKER_RESTART_REQUIRED=1
else
  ok "Docker уже установлен"
fi

mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "live-restore": true
}
EOF
  DOCKER_RESTART_REQUIRED=1
  ok "Настроена ротация логов Docker (/etc/docker/daemon.json)"
else
  warn "/etc/docker/daemon.json уже есть — не перезаписываю (проверьте log-opts вручную)."
fi
systemctl enable --now docker || die "Не удалось запустить docker.service."
if [[ "$DOCKER_RESTART_REQUIRED" -eq 1 ]]; then
  systemctl restart docker || die "Не удалось применить настройки docker.service."
  ok "Docker перезапущен для применения новой конфигурации"
else
  note "Конфигурация Docker не менялась — restart не требуется."
fi
docker --version || true
docker compose version >/dev/null 2>&1 || die "docker compose plugin недоступен."
ok "Docker готов"

if [[ "$MANAGE_FIREWALL" -eq 1 ]]; then
  step 4 "Firewall (ufw)"
  if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
    SSH_PORT="$SSH_PORT_OVERRIDE"
  else
    SSH_PORT="$ACTIVE_SSH_PORT"
  fi
  ok "SSH-порт для ufw: $SSH_PORT (переопределить: --ssh-port N)"

  if [[ "$RESET_FIREWALL" -eq 1 ]]; then
    warn "--reset-firewall: текущие правила ufw будут стёрты."
    ufw --force reset        >/dev/null || die "ufw reset не удался."
  else
    note "Существующие правила ufw сохранены; нужные правила добавляются поверх."
  fi
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  remove_managed_ufw_rules
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'                        >/dev/null
  ufw allow 443/tcp           comment 'VLESS/Trojan via Caddy L4'  >/dev/null
  ufw allow 443/udp           comment 'Hysteria2 QUIC'             >/dev/null
  ufw allow 80/tcp            comment 'acme.sh standalone'         >/dev/null
  ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp comment 'Remnawave panel -> node' >/dev/null
  ufw --force enable >/dev/null || die "Не удалось включить ufw."
  ok "ufw включён. API-порт $NODE_API_PORT доступен только с $PANEL_IP."
  ufw status numbered | sed 's/^/   /' || true
else
  step 4 "Firewall (пропущен)"
  warn "--no-firewall: убедитесь, что 443 tcp/udp, 80/tcp открыты, а $NODE_API_PORT доступен только панели."
fi

caddy_build_matches() {
  have caddy \
    && [[ "$(caddy version 2>/dev/null | awk '{print $1}')" == "$CADDY_VERSION" ]] \
    && caddy list-modules 2>/dev/null | grep -qE 'layer4' \
    && caddy build-info 2>/dev/null | tr '\t' ' ' \
      | grep -Fq "github.com/mholt/caddy-l4 $CADDY_L4_VERSION"
}

step 5 "Сборка Caddy с модулем layer4"
if ! caddy_build_matches; then
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    retry 3 5 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" \
      || die "Не удалось получить GPG-ключ Caddy."
  fi
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    retry 3 5 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list" \
      || die "Не удалось получить apt-репозиторий Caddy."
  fi
  retry 3 5 apt_get update -y || warn "apt-get update (caddy repo) с ошибкой — продолжаю."
  if have caddy; then
    retry 3 5 apt_get install -y build-essential libcap2-bin \
      || die "Не удалось установить build-essential/libcap2-bin."
  else
    apt-mark unhold caddy >/dev/null 2>&1 || true
    retry 3 5 apt_get install -y caddy build-essential libcap2-bin \
      || die "Не удалось установить caddy/build-essential."
  fi

  install_go_toolchain
  retry 3 10 env GOBIN=/usr/local/bin go install "github.com/caddyserver/xcaddy/cmd/xcaddy@$XCADDY_VERSION" \
    || die "Не удалось установить xcaddy."
  mkdir -p /root/build-caddy-l4
  ( cd /root/build-caddy-l4 && retry 2 10 xcaddy build "$CADDY_VERSION" \
      --with "github.com/mholt/caddy-l4@$CADDY_L4_VERSION" --output ./caddy ) \
    || die "xcaddy build не удался."
  /root/build-caddy-l4/caddy list-modules 2>/dev/null | grep -qE 'layer4' \
    || die "В собранном бинаре нет модулей layer4."

  if systemctl is-active --quiet caddy; then
    systemctl stop caddy || die "Не удалось остановить Caddy перед заменой бинарника."
    CADDY_RESTORE_NEEDED=1
  fi
  cp -a /usr/bin/caddy "/usr/bin/caddy.stock-$(date +%F-%H%M%S)" 2>/dev/null || true
  prune_matching_files /usr/bin 'caddy.stock-*' 3
  install -m 755 /root/build-caddy-l4/caddy /usr/bin/caddy
  setcap cap_net_bind_service=+ep /usr/bin/caddy || warn "setcap не удался — Caddy может не занять :80/:443 без root."
  apt-mark hold caddy >/dev/null 2>&1 || true
  systemctl enable caddy >/dev/null 2>&1 || true
  L4_COUNT="$(caddy list-modules 2>/dev/null | grep -c layer4 || true)"
  ok "Кастомный Caddy $CADDY_VERSION собран (${L4_COUNT:-0} L4-модулей)"
else
  ok "Caddy $CADDY_VERSION + caddy-l4 $CADDY_L4_VERSION уже установлены — сборку пропускаю"
fi
caddy version || true

step 6 "Сертификаты acme.sh (self-steal + Trojan + Hysteria2)"
if ss -lntup 2>/dev/null | grep -q ':80 '; then
  warn "Порт 80 занят — acme.sh standalone может не выпустить сертификаты:"
  ss -lntup 2>/dev/null | grep ':80 ' | sed 's/^/   /' || true
fi
if [[ ! -x /root/.acme.sh/acme.sh ]]; then
  retry 3 10 bash -c "curl -fsSL https://get.acme.sh | sh -s email='$ACME_EMAIL'" \
    || die "Не удалось установить acme.sh."
fi
ACME=/root/.acme.sh/acme.sh
[[ -x "$ACME" ]] || die "acme.sh не найден по пути $ACME."
"$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
"$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || warn "Не удалось выставить CA по умолчанию."

issue_cert() {
  local d="$1"
  if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$d"; then
    ok "Сертификат для $d уже выпущен — пропускаю issue"
  else
    if systemctl is-active --quiet caddy; then
      systemctl stop caddy || die "Не удалось освободить порт 80 для ACME."
      CADDY_RESTORE_NEEDED=1
      note "Caddy временно остановлен для ACME standalone challenge."
    fi
    if ss -H -lnt 'sport = :80' 2>/dev/null | grep -q .; then
      ss -H -lntp 'sport = :80' 2>/dev/null | sed 's/^/   /' || true
      die "Порт 80 занят другим процессом — ACME standalone challenge невозможен."
    fi
    if ! "$ACME" --issue --standalone -d "$d" --keylength ec-256; then
      warn "Не удалось выпустить сертификат для $d (проверьте DNS/порт 80)."
      return 1
    fi
  fi
}
issue_cert "$SELF_STEAL_HOST" || die "Без сертификата $SELF_STEAL_HOST настоящий self-steal невозможен."
issue_cert "$TROJAN_HOST" || die "Не удалось подготовить обязательный сертификат Trojan."
issue_cert "$HY_HOST" || die "Не удалось подготовить обязательный сертификат Hysteria2."

mkdir -p "$CERT_DIR/$SELF_STEAL_HOST" "$CERT_DIR/$TROJAN_HOST" "$CERT_DIR/$HY_HOST"
"$ACME" --install-cert -d "$SELF_STEAL_HOST" --ecc \
  --key-file       "$CERT_DIR/$SELF_STEAL_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem" \
  --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || true" \
  || die "Не удалось установить сертификат self-steal для $SELF_STEAL_HOST."
"$ACME" --install-cert -d "$TROJAN_HOST" --ecc \
  --key-file       "$CERT_DIR/$TROJAN_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$TROJAN_HOST/fullchain.pem" \
  --reloadcmd "docker restart remnanode >/dev/null 2>&1 || true" \
  || die "install-cert для $TROJAN_HOST не удался."
"$ACME" --install-cert -d "$HY_HOST" --ecc \
  --key-file       "$CERT_DIR/$HY_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$HY_HOST/fullchain.pem" \
  --reloadcmd "docker restart remnanode >/dev/null 2>&1 || true" \
  || die "install-cert для $HY_HOST не удался."

for cert_file in \
  "$CERT_DIR/$SELF_STEAL_HOST/key.pem" "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem" \
  "$CERT_DIR/$TROJAN_HOST/key.pem" "$CERT_DIR/$TROJAN_HOST/fullchain.pem" \
  "$CERT_DIR/$HY_HOST/key.pem" "$CERT_DIR/$HY_HOST/fullchain.pem"; do
  [[ -s "$cert_file" ]] || die "Сертификат или ключ отсутствует/пуст: $cert_file"
done

chown -R root:root "$CERT_DIR"
find "$CERT_DIR" -type d -exec chmod 755 {} \; || true
find "$CERT_DIR" -type f -name 'key.pem'       -exec chmod 600 {} \; || true
find "$CERT_DIR" -type f -name 'fullchain.pem' -exec chmod 644 {} \; || true
chown root:caddy "$CERT_DIR/$SELF_STEAL_HOST/key.pem" "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem"
chmod 640 "$CERT_DIR/$SELF_STEAL_HOST/key.pem"
ok "Сертификаты установлены в $CERT_DIR (автопродление — таймер/cron acme.sh)"

step 7 "Caddyfile — SNI-роутинг и локальный self-steal сайт"
SELF_STEAL_ROOT=/var/www/remnanode-self-steal
mkdir -p "$SELF_STEAL_ROOT"
SELF_STEAL_TEMPLATE_TMP="$(mktemp)"
if retry 3 3 curl -fsSL "$SELF_STEAL_TEMPLATE_URL" -o "$SELF_STEAL_TEMPLATE_TMP"; then
  install -m 644 "$SELF_STEAL_TEMPLATE_TMP" "$SELF_STEAL_ROOT/index.html"
  ok "Шаблон закрытого файлообменника установлен"
else
  warn "Не удалось скачать шаблон — устанавливаю минимальную локальную заглушку."
  cat > "$SELF_STEAL_ROOT/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Secure workspace</title></head><body><main><h1>Secure file workspace</h1><form><label>Workspace ID <input autocomplete="off"></label><label>Password <input type="password" autocomplete="off"></label><button type="button">Sign in</button></form></main></body></html>
EOF
fi
rm -f "$SELF_STEAL_TEMPLATE_TMP"
chmod -R a=rX "$SELF_STEAL_ROOT"

cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup-$(date +%F-%H%M%S)" 2>/dev/null || true
prune_matching_files /etc/caddy 'Caddyfile.backup-*' 5
cat > /etc/caddy/Caddyfile <<EOF
{
  auto_https disable_redirects
  layer4 {
    :443 {
      @vision tls sni $SELF_STEAL_HOST
      route @vision {
        proxy 127.0.0.1:10443
      }
      @xhttp tls sni $XHTTP_SNI
      route @xhttp {
        proxy 127.0.0.1:10444
      }
      @trojan tls sni $TROJAN_HOST
      route @trojan {
        proxy 127.0.0.1:10445
      }
      route {
        proxy 127.0.0.1:9443
      }
    }
  }
}

https://$SELF_STEAL_HOST:9443 {
  bind 127.0.0.1
  tls $CERT_DIR/$SELF_STEAL_HOST/fullchain.pem $CERT_DIR/$SELF_STEAL_HOST/key.pem
  root * $SELF_STEAL_ROOT
  header {
    -Server
    Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
  }
  file_server
}
EOF
caddy fmt --overwrite /etc/caddy/Caddyfile || warn "caddy fmt не удался — продолжаю."
caddy validate --config /etc/caddy/Caddyfile || die "Caddyfile невалиден — исправьте SNI/синтаксис."
systemctl restart caddy || die "Не удалось перезапустить Caddy."
sleep 1
if systemctl is-active --quiet caddy; then
  CADDY_RESTORE_NEEDED=0
  ok "Caddy запущен: :443 L4 и локальный TLS-сайт 127.0.0.1:9443"
else
  die "Caddy не поднялся. journalctl -u caddy -n 50"
fi

step 8 "sysctl-тюнинг (BBR/fq, UDP-буферы, fd-лимиты)"
cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
fs.nr_open = 1048576
EOF
modprobe tcp_bbr 2>/dev/null || true
grep -q '^tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl --system >/dev/null 2>&1 || warn "sysctl --system вернул ошибку по части ключей (не критично)."

cat > /etc/security/limits.d/99-remnanode.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
rbuf="$(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')"
if [[ "$cc" == "bbr" ]]; then
  ok "congestion=$cc qdisc=$qd, UDP buf=$rbuf"
else
  warn "BBR не активировался (сейчас: $cc). Возможно нужно новое ядро/перезапуск."
fi

step 9 "Нода Remnawave (compose)"
mkdir -p "$NODE_DIR"
echo
note "Создайте ноду в панели (Nodes -> Add) с IP $SERVER_IP и портом $NODE_API_PORT."
note "Панель выдаст SECRET_KEY (публичный ключ ноды). Вставьте его целиком."
note "Можно как чистое значение (eyJ...), так и строку 'SECRET_KEY=...'."
echo
ask SECRET_RAW "SECRET_KEY из панели" "${SECRET_KEY:-}"

SECRET_VALUE="$SECRET_RAW"
SECRET_VALUE="${SECRET_VALUE#SECRET_KEY=}"
SECRET_VALUE="${SECRET_VALUE#\"}"; SECRET_VALUE="${SECRET_VALUE%\"}"
SECRET_VALUE="${SECRET_VALUE#\'}"; SECRET_VALUE="${SECRET_VALUE%\'}"
SECRET_VALUE="$(printf '%s' "$SECRET_VALUE" | tr -d '[:space:]')"
[[ -n "$SECRET_VALUE" ]] || die "Пустой SECRET_KEY."

if [[ "$BUILD_COMPOSE" -eq 1 ]]; then
  ( umask 077
    cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_API_PORT
SECRET_KEY=$SECRET_VALUE
NODE_IMAGE=$NODE_IMAGE
EOF
  )
  cat > "$NODE_DIR/docker-compose.yml" <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE:-remnawave/node:3.1.1}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
    env_file:
      - .env
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
    volumes:
      - /etc/remna-certs:/etc/remna-certs:ro
EOF
  ok "Записаны $NODE_DIR/.env (0600) и docker-compose.yml"
else
  [[ -f "$NODE_DIR/docker-compose.yml" ]] || die "--no-compose, но $NODE_DIR/docker-compose.yml отсутствует."
  ( umask 077
    {
      echo "NODE_PORT=$NODE_API_PORT"
      echo "SECRET_KEY=$SECRET_VALUE"
      echo "NODE_IMAGE=$NODE_IMAGE"
    } > "$NODE_DIR/.env"
  )
  ok "Обновлён $NODE_DIR/.env (compose оставлен как есть)"
fi

( cd "$NODE_DIR" && retry 3 10 docker compose pull ) || die "docker compose pull не удался."
( cd "$NODE_DIR" && docker compose up -d --remove-orphans ) || die "docker compose up не удался."

log "Жду готовности ноды (до 30s)..."
node_ready=0
for _ in $(seq 1 15); do
  state="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || echo missing)"
  if [[ "$state" == running ]] && ss -H -lnt "sport = :${NODE_API_PORT}" 2>/dev/null | grep -q .; then
    node_ready=1; break
  fi
  sleep 2
done
if [[ "$node_ready" -eq 1 ]]; then
  ok "Нода запущена и слушает API-порт $NODE_API_PORT"
else
  docker logs remnanode --tail 120 2>&1 | sed 's/^/   /' || true
  die "Нода не подтвердила готовность за 30s (state=${state:-?})."
fi
docker ps --filter name=remnanode --format 'table {{.Names}}\t{{.Status}}' | sed 's/^/   /' || true
docker exec remnanode sh -lc \
  'find /etc/remna-certs -type f \( -name "key.pem" -o -name "fullchain.pem" \) -printf "%M %u:%g %p\n" | sort' \
  2>/dev/null | sed 's/^/   /' || warn "Не удалось прочитать сертификаты внутри контейнера (docker logs remnanode)."
ok "Контейнер remnanode запущен"

step 10 "Проверка слушателей и маршрутизации"

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
  has_tcp_listener 443 \
    && has_tcp_listener_at 127.0.0.1 9443 \
    && has_tcp_listener_at 127.0.0.1 10443 \
    && has_tcp_listener_at 127.0.0.1 10444 \
    && has_tcp_listener_at 127.0.0.1 10445 \
    && has_tcp_listener "$NODE_API_PORT" \
    && has_udp_listener 443
}

log "Жду все протокольные слушатели после получения конфигурации от панели (до 60s)..."
listeners_ready=0
for _ in $(seq 1 30); do
  if all_protocol_listeners_ready; then
    listeners_ready=1
    break
  fi
  sleep 2
done

printf '   %s%sTCP listeners%s\n' "$C_B" "$C_MAG" "$C_RST"
ss -lntup 2>/dev/null | grep -E ':443|:9443|:10443|:10444|:10445|:'"$NODE_API_PORT" | sed 's/^/     /' || true
printf '   %s%sUDP listeners (Hysteria2)%s\n' "$C_B" "$C_MAG" "$C_RST"
ss -lnuap 2>/dev/null | grep ':443' | sed 's/^/     /' || true

if [[ "$listeners_ready" -ne 1 ]]; then
  has_tcp_listener 443 || warn "Caddy L4 не слушает TCP/443."
  has_tcp_listener_at 127.0.0.1 9443 || warn "Self-steal сайт не слушает 127.0.0.1:9443."
  has_tcp_listener_at 127.0.0.1 10443 || warn "Vision inbound не слушает 127.0.0.1:10443."
  has_tcp_listener_at 127.0.0.1 10444 || warn "XHTTP inbound не слушает 127.0.0.1:10444."
  has_tcp_listener_at 127.0.0.1 10445 || warn "Trojan inbound не слушает 127.0.0.1:10445."
  has_tcp_listener "$NODE_API_PORT" || warn "Node API не слушает порт $NODE_API_PORT."
  has_udp_listener 443 || warn "Hysteria2 не слушает UDP/443."
  docker logs remnanode --tail 120 2>&1 | sed 's/^/   /' || true
  die "Не все inbound'ы поднялись за 60s. Проверьте назначенный Config Profile в Remnawave."
fi
ok "Все TCP/UDP-слушатели активны"

check_tls_route() {
  local name="$1" sni="$2" output
  printf '   %s%s%s (%s)%s\n' "$C_B" "$C_MAG" "$name" "$sni" "$C_RST"
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

tls_failures=0
for pair in "Vision:$VISION_SNI" "XHTTP:$XHTTP_SNI" "Trojan:$TROJAN_HOST"; do
  name="${pair%%:*}"; sni="${pair#*:}"
  check_tls_route "$name" "$sni" || tls_failures=$((tls_failures + 1))
done
printf '   %s%sSelf-steal target (%s)%s\n' "$C_B" "$C_MAG" "$SELF_STEAL_HOST" "$C_RST"
if self_steal_output="$(timeout 12 openssl s_client -connect 127.0.0.1:9443 \
    -servername "$SELF_STEAL_HOST" -verify_hostname "$SELF_STEAL_HOST" \
    -verify_return_error -brief </dev/null 2>&1)" \
    && grep -Eq 'CONNECTION ESTABLISHED|Protocol version:' <<<"$self_steal_output"; then
  printf '%s\n' "$self_steal_output" | head -8 | sed 's/^/     /'
else
  printf '%s\n' "$self_steal_output" | head -8 | sed 's/^/     /'
  die "Локальный TLS-сайт self-steal не прошёл проверку."
fi
(( tls_failures == 0 )) || die "Не прошли TLS-проверку маршруты: $tls_failures. Установка не считается завершённой."
ok "Все SNI/TLS-маршруты прошли проверку"

prune_matching_files "$LOG_DIR" 'remnanode-setup-*.log' 10

echo
printf '%s%s╭──────────────────────────────────────────────────────────────╮%s\n' "$C_B" "$C_GRN" "$C_RST"
printf '%s%s│%s  %s✔ ГОТОВО%s  Проверьте статус ноды в панели — должна быть online   %s%s│%s\n' \
  "$C_B" "$C_GRN" "$C_RST" "$C_B$C_GRN" "$C_RST" "$C_B$C_GRN" "" "$C_RST"
printf '%s%s╰──────────────────────────────────────────────────────────────╯%s\n' "$C_B" "$C_GRN" "$C_RST"
echo
printf '   %s%sКонфигурация нод-инбаундов (сверьте в панели)%s\n' "$C_B" "$C_MAG" "$C_RST"
kv "Vision/Reality" "SNI $SELF_STEAL_HOST  →  127.0.0.1:10443  (target: 127.0.0.1:9443)"
kv "XHTTP"          "SNI $XHTTP_SNI  path $XHTTP_PATH  →  127.0.0.1:10444"
kv "Trojan (TLS)"   "SNI $TROJAN_HOST  →  127.0.0.1:10445  (cert $CERT_DIR/$TROJAN_HOST)"
kv "Hysteria2"      "UDP/443 напрямую  (cert $CERT_DIR/$HY_HOST)"
kv "Node API"       "$SERVER_IP:$NODE_API_PORT  (только с панели $PANEL_IP)"
kv "Образ ноды"     "$NODE_IMAGE"
echo
kv "Лог установки"   "$LOG_FILE"
kv "Логи ноды"       "docker logs remnanode --tail 120"
kv "Логи Xray"      "docker exec -it remnanode tail -n +1 -f /var/log/xray/current"
kv "Статус Caddy"    "systemctl status caddy --no-pager"
kv "Firewall"        "ufw status numbered"
echo
