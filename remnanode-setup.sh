#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_COMPOSE=1
MANAGE_FIREWALL=1
RESET_FIREWALL=0
FORCE_DNS=0
# 1 — оставить инструменты сборки (Go, xcaddy, build-essential, кэши) после
# установки Caddy: нужно, только если Caddy предстоит пересобирать на этом сервере.
KEEP_BUILD_TOOLS="${KEEP_BUILD_TOOLS:-0}"
# Ставим build-essential сами (1) или он уже был в системе (0): чистим только своё.
BUILD_ESSENTIAL_ADDED=0
ASSUME_YES="${ASSUME_YES:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
SSH_PORT_OVERRIDE=""
# Cloudflare: "" — судить по CLOUDFLARE_API_TOKEN, 1 — требовать (--cloudflare),
# 0 — запретить (--no-cloudflare).
CF_MODE_SETTING=""
CF_MODE=0
CF_CURL_CFG=""
CF_ZONE_ID=""
CF_ZONE_NAME=""
# Как появилась A-запись CDN-хоста: "cloudflare" — установщик создал
# проксируемую запись сам, "manual"/"" — запись должен создать пользователь.
# Значение показывается в сводке, чтобы отсутствие записи не было тихим.
CDN_DNS_MANAGED=""
# Быстрый режим мастера (--quick / QUICK_SETUP=y): только 5 вопросов —
# домен, токен Cloudflare, домен панели, токен панели и IP панели.
# Поддомены, CDN, пути, тема фасада и порт ноды выбираются автоматически.
# QUICK_SETUP_SETTING: "" — решать по env/сохранённому/вопросу, 1 — --quick,
# 0 — --advanced. ENV_STORE_LOADED отличает свежую установку от повторной
# (случайные значения генерируются только на свежей).
QUICK_SETUP_SETTING=""
QUICK_SETUP_ENV_PRESENT=0
[[ -n "${QUICK_SETUP:-}" ]] && QUICK_SETUP_ENV_PRESENT=1
QUICK_SETUP="${QUICK_SETUP:-}"
ENV_STORE_LOADED=0
# Remnawave Panel API: автоматическая настройка панели (профили, ноды, хосты, шаблоны).
REMNAWAVE_PANEL_URL="${REMNAWAVE_PANEL_URL:-}"
REMNAWAVE_API_TOKEN="${REMNAWAVE_API_TOKEN:-}"
REMNAWAVE_AUTO_SETUP="${REMNAWAVE_AUTO_SETUP:-n}"
PANEL_CURL_CFG=""
# Префикс ручных поддоменов (<prefix>1/<prefix>3) и имён объектов в панели.
# Дефолт нужен и в Cloudflare-режиме: раньше при чистой установке PREFIX был
# не задана вовсе и валидация падала с unbound variable под set -u.
PREFIX="${PREFIX:-usa}"
# Шаблон подписки: standard (весь трафик через VPN) или split (только RU/частные сети через VPN).
XRAY_TEMPLATE_CHOICE="${XRAY_TEMPLATE_CHOICE:-standard}"
NODE_DIR="${NODE_DIR:-/opt/remnanode}"
CERT_DIR="${CERT_DIR:-/etc/remna-certs}"
ENV_STORE="${ENV_STORE:-/root/remnanode.env}"
NODE_IMAGE="${NODE_IMAGE:-remnawave/node:latest}"
# Темы фасада self-steal: файлы self-steal-templates/<тема>.html в репозитории.
# Дефолт — прежний «файлообменник», чтобы поведение не менялось без запроса.
# Базу URL шаблонов фасада можно переопределить (свой форк, тег или коммит):
SELF_STEAL_RAW_BASE="${SELF_STEAL_RAW_BASE:-https://raw.githubusercontent.com/bami7up/multi-protocol/main}"
SELF_STEAL_TEMPLATES=(vaultdrop mail cloud admin docs)
# Тема задана явно (env/--self-steal-template)? Тогда быстрый режим не вправе
# заменять её случайной на свежей установке.
SELF_STEAL_TEMPLATE_EXPLICIT=0
[[ -n "${SELF_STEAL_TEMPLATE:-}" ]] && SELF_STEAL_TEMPLATE_EXPLICIT=1
SELF_STEAL_TEMPLATE="${SELF_STEAL_TEMPLATE:-vaultdrop}"
# Явный URL (свой фасад) важнее имени темы; проверяется при разборе переменных.
SELF_STEAL_TEMPLATE_URL="${SELF_STEAL_TEMPLATE_URL:-}"
SELF_STEAL_THEME_USED=0
# VLESS за CDN: инбаунды слушают только loopback и без своего TLS — публичный
# TLS терминирует CDN, а TLS между CDN и origin — Caddy с сертификатом для
# CDN-хоста. HTTP-01 такой сертификат не выпустит (за прокси на :80 отвечает
# CDN), поэтому используется ACME DNS-01 тем же токеном Cloudflare.
ENABLE_CDN="${ENABLE_CDN:-n}"
CDN_TRANSPORT="${CDN_TRANSPORT:-ws}"
CDN_HOST="${CDN_HOST:-}"
CDN_WS_PATH="${CDN_WS_PATH:-/api/v1/stream}"
CDN_XHTTP_PATH="${CDN_XHTTP_PATH:-/api/v3/sync/c1}"
# gRPC: serviceName начинается со слэша, поэтому Caddy выделяет его префиксом
# пути (@grpccdn), а сам трафик уходит в Xray по h2c (HTTP/2 без TLS).
CDN_GRPC_PATH="${CDN_GRPC_PATH:-/api/v4/stream}"
CDN_WS_ENABLED=0
CDN_XHTTP_ENABLED=0
CDN_GRPC_ENABLED=0
CDN_WS_PORT=10446
CDN_XHTTP_PORT=10447
CDN_GRPC_PORT=10448
CDN_TLS_PORT=9444
# Шаблон Config Profile: из него установщик сохраняет готовый Multiselect.json.
MULTISELECT_TEMPLATE_URL="${MULTISELECT_TEMPLATE_URL:-https://raw.githubusercontent.com/bami7up/multi-protocol/main/Multiselect.json}"
XCADDY_VERSION="${XCADDY_VERSION:-v0.4.7}"
CADDY_VERSION="${CADDY_VERSION:-v2.11.7}"
CADDY_L4_VERSION="${CADDY_L4_VERSION:-v0.1.2}"
# Go для сборки Caddy. Caddy >= v2.11.6 требует Go >= 1.26 (release notes
# v2.11.6: «Go 1.26 is now the minimum version for building Caddy and plugins»),
# поэтому берём самую старую из поддерживаемых линий — 1.26 (Go сопровождает две
# последние) и последний её патч: он содержит исправления безопасности stdlib,
# а сам Caddy слушает публичные 80/443. Версия, архив и SHA256 меняются вместе.
GO_VERSION="1.26.9"
GO_INSTALL_TMP=""
GO_ARCHIVE_TMP=""
CADDY_RESTORE_NEEDED=0
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/remnanode-setup-$(date +%F-%H%M%S).log"
# Каталог самого скрипта: при запуске из клона репозитория шаблоны берутся
# локально, а не из сети (при `bash <(...)` каталога нет — скачаем по URL).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /nonexistent)"

usage() {
  cat <<'USAGE'
remnanode-setup.sh — установка ноды Remnawave (VLESS + Hysteria2 за Caddy L4)

Использование:
  bash remnanode-setup.sh [флаги]

Флаги:
  --no-compose          не трогать docker-compose.yml (только .env + up -d)
  --no-firewall         не настраивать ufw
  --reset-firewall      сбросить существующие правила ufw перед настройкой
  --no-reset-firewall   не сбрасывать ufw (по умолчанию; для совместимости)
  --force-dns           не прерываться при несовпадении DNS
  --keep-build-tools    не удалять Go, xcaddy, build-essential и кэши сборки после Caddy
                        (по умолчанию удаляются; нужно, только если Caddy будет пересобираться)
  --ssh-port N          явно указать SSH-порт для правила ufw
  --node-image REF      образ ноды (по умолчанию remnawave/node:latest)
  --self-steal-template T
                        тема фасада self-steal (vaultdrop, mail, cloud, admin, docs)
  --xray-template T     шаблон подписки: standard (весь трафик через VPN) или split
  --cloudflare          создать A-записи через Cloudflare API
  --no-cloudflare       не использовать Cloudflare, даже если токен в env
  --panel-url URL       URL панели Remnawave (напр. https://panel.example.com)
  --api-token TOKEN     API токен панели для авто-настройки
  --quick               быстрый режим мастера: 5 вопросов, остальное — авто/случайно
  --advanced            расширенный режим мастера: все вопросы (как раньше)
  -y | --yes            авто-подтверждение всех «y/n» вопросов
  --non-interactive     не задавать вопросы: все значения из env/дефолтов
  -h | --help           показать эту справку

Переменные окружения (для --non-interactive / CI):
  BASE_DOMAIN, PREFIX, SELF_STEAL_HOST, XHTTP_SNI, XHTTP_PATH, ENABLE_XHTTP,
  ENABLE_CDN, CDN_HOST, CDN_TRANSPORT, CDN_WS_PATH, CDN_XHTTP_PATH, CDN_GRPC_PATH,
  PANEL_IP, NODE_API_PORT, SECRET_KEY, NODE_IMAGE,
  SELF_STEAL_TEMPLATE, SELF_STEAL_TEMPLATE_URL, MULTISELECT_TEMPLATE_URL,
  SELF_STEAL_RAW_BASE, XRAY_TEMPLATE_CHOICE,
  XCADDY_VERSION, CADDY_VERSION, CADDY_L4_VERSION,
  CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE,
  REMNAWAVE_PANEL_URL, REMNAWAVE_API_TOKEN, REMNAWAVE_AUTO_SETUP,
  QUICK_SETUP, SERVER_IP, NODE_DIR, CERT_DIR, ENV_STORE, KEEP_BUILD_TOOLS

Логические переменные (ENABLE_XHTTP, ENABLE_CDN, REMNAWAVE_AUTO_SETUP, QUICK_SETUP, KEEP_BUILD_TOOLS) понимают
y/yes/1/true/on и n/no/0/false/off в любом регистре; пустое значение означает ответ по умолчанию.
Значение SERVER_IP (в том числе из сохранённого env-файла) важнее автодетекта:
задайте его, если нода за NAT или внешние сервисы определения IP недоступны.

Интерактивный мастер сначала спросит режим:
  быстрый (рекомендуется): всего 5 вопросов — домен, токен Cloudflare,
    домен панели (полным URL: https://panel.example.com), токен панели
    и IP панели; поддомены, CDN, пути, тема и порт ноды — автоматически;
  расширенный: прежние 4 блока вопросов со всеми настройками.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-compose)  BUILD_COMPOSE=0 ;;
    --no-firewall) MANAGE_FIREWALL=0 ;;
    --reset-firewall) RESET_FIREWALL=1 ;;
    --no-reset-firewall) RESET_FIREWALL=0 ;; # совместимость со старыми командами
    --force-dns)   FORCE_DNS=1 ;;
    --keep-build-tools) KEEP_BUILD_TOOLS=1 ;;
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
    --self-steal-template)
      SELF_STEAL_TEMPLATE_EXPLICIT=1
      SELF_STEAL_TEMPLATE="${2:-}"
      [[ -n "$SELF_STEAL_TEMPLATE" ]] || { echo "--self-steal-template требует значение (тема фасада)" >&2; exit 2; }
      shift ;;
    --xray-template)
      XRAY_TEMPLATE_CHOICE="${2:-}"
      [[ -n "$XRAY_TEMPLATE_CHOICE" ]] || { echo "--xray-template требует значение (standard или split)" >&2; exit 2; }
      shift ;;
    --node-tag)
      NODE_TAG="${2:-}"
      [[ -n "$NODE_TAG" ]] || { echo "--node-tag требует значение (например NL1)" >&2; exit 2; }
      shift ;;
    --panel-url)
      REMNAWAVE_PANEL_URL="${2:-}"
      [[ -n "$REMNAWAVE_PANEL_URL" ]] || { echo "--panel-url требует значение" >&2; exit 2; }
      shift ;;
    --api-token)
      REMNAWAVE_API_TOKEN="${2:-}"
      [[ -n "$REMNAWAVE_API_TOKEN" ]] || { echo "--api-token требует значение" >&2; exit 2; }
      shift ;;
    --cloudflare)    CF_MODE_SETTING=1 ;;
    --no-cloudflare) CF_MODE_SETTING=0 ;;
    --quick)         QUICK_SETUP_SETTING=1 ;;
    --advanced)      QUICK_SETUP_SETTING=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ "$CF_MODE_SETTING" == 1 ]]; then
  CF_MODE=1
elif [[ "$CF_MODE_SETTING" == 0 ]]; then
  CF_MODE=0
elif [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  CF_MODE=1
fi

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

hr()   { printf '%s%s%s\n' "${C_DIM:-}${C_GRY:-}" "$RULE" "${C_RST:-}"; }
log()  { printf ' %s➜%s %s\n'  "$C_BLU$C_B" "${C_RST:-}" "$*"; }
ok()   { printf ' %s✔%s %s\n'  "$C_GRN$C_B" "${C_RST:-}" "$*"; }
warn() { printf ' %s▲%s %s\n'  "$C_YLW$C_B" "${C_RST:-}" "$*"; }
note() { printf '   %s%s%s\n'  "${C_DIM:-}${C_GRY:-}" "$*" "${C_RST:-}"; }
die()  { printf ' %s✖%s %s\n'  "$C_RED$C_B" "${C_RST:-}" "$*" >&2; exit 1; }

step() {
  local cur="$1" title="$2"
  printf '\n%s%s┏━ %s[ %02d / %02d ]%s %s%s%s%s\n' \
    "${C_B:-}" "${C_CYN:-}" "$C_RST$C_B$C_YLW" "$cur" "$STEP_TOTAL" \
    "${C_RST:-}" "${C_B:-}${C_CYN:-}" "$title" "${C_RST:-}" ""
  printf '%s%s┗%s%s%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" "${C_DIM:-}${C_GRY:-}" "$RULE${C_RST}"
}

banner() {
  local L="$C_B$C_WHT" T="${C_B:-}${C_MAG:-}" D="${C_DIM:-}${C_GRY:-}" A="${C_B:-}${C_CYN:-}" S="${C_DIM:-}${C_GRY:-}" R="${C_RST:-}"
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
    "${D}│${R}  ${A}REMNAWAVE NODE · VLESS · Hysteria2 · Caddy L4${R}      ${D}│${R}" \
    "${D}│${R}  ${S}by Latex · github.com/1atex${R}                                 ${D}│${R}" \
    "${D}╰──────────────────────────────────────────────────────────────╯${R}"
}

kv() { printf '   %s%-14s%s %s%s%s\n' "${C_GRY:-}" "$1" "${C_RST:-}" "${C_B:-}" "$2" "${C_RST:-}"; }

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
  local rule_no removed=0
  local -a rule_numbers=()
  mapfile -t rule_numbers < <(
    ufw status numbered 2>/dev/null \
      | sed -n '/Remnawave panel -> node/s/^[[:space:]]*\[[[:space:]]*\([0-9]\+\)\].*/\1/p' \
      | sort -rn
  )
  for rule_no in "${rule_numbers[@]}"; do
    if ufw --force delete "$rule_no" >/dev/null; then
      removed=$((removed + 1))
    else
      warn "Не удалось удалить старое управляемое правило ufw №$rule_no."
    fi
  done
  if (( removed > 0 )); then
    ok "Старые правила доступа панели к Node API удалены: $removed"
  fi
}

install_go_toolchain() {
  local go_arch go_sha go_root archive
  # SHA256 официальных архивов go${GO_VERSION}.linux-<arch>.tar.gz (сверены с
  # https://go.dev/dl/ через docker-library/golang, <линия>/<дистрибутив>/Dockerfile).
  # При смене GO_VERSION хеши нужно обновить: проверка идёт до распаковки архива.
  case "$ARCH" in
    x86_64|amd64)
      go_arch=amd64
      go_sha=42d158b4d8f7b61ac0a830567c940a86098fb7aac52e467a5ebec03ef5cc2f8d
      ;;
    aarch64|arm64)
      go_arch=arm64
      go_sha=4a97373d49fcacdcf3694fea368a500b00ee3e963974f3e7514132717632f052
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

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fq 'install ok installed'
}

# Чистка за собой. На малых VPS диск ценен, а после сборки Caddy остаются
# инструменты, которые ноде не нужны: Go-тулчейн (сотни МБ), кэш сборки и
# модулей Go, xcaddy, копия собранного бинарника и build-essential с зависимостями.
# Если Caddy понадобится пересобрать, установщик скачает всё заново.
# Функция идемпотентна и безопасна при сбое: отсутствующие пути пропускаются.
remove_build_leftovers() {
  local go_bin="/opt/remnanode-toolchains/go${GO_VERSION}/bin/go" p
  local removed=0
  [[ "$KEEP_BUILD_TOOLS" == 1 ]] && return 0
  # Очищаем кэши именно нашим тулчейном: системный go (если есть) не трогаем.
  if [[ -x "$go_bin" ]]; then
    "$go_bin" clean -modcache >/dev/null 2>&1 || true
    "$go_bin" clean -cache >/dev/null 2>&1 || true
    removed=1
  fi
  for p in /root/build-caddy-l4 /usr/local/bin/xcaddy /opt/remnanode-toolchains; do
    if [[ -e "$p" ]]; then
      rm -rf -- "$p"
      removed=1
    fi
  done
  # Молчим, если удалять было нечего: функция вызывается и при выходе (on_exit).
  if (( removed == 1 )); then
    note "Инструменты сборки Caddy удалены: Go, кэши сборки и модулей, xcaddy"
  fi
}

# build-essential ставится только для сборки. Удаляем его, лишь если он появился
# при установке: пакет, который был в системе до нас, не трогаем.
remove_build_packages() {
  [[ "$KEEP_BUILD_TOOLS" == 1 ]] && return 0
  if [[ "$BUILD_ESSENTIAL_ADDED" == 1 ]] && pkg_installed build-essential; then
    # Сообщение об успехе — только после успешного purge: иначе установщик
    # рапортовал об удалении пакета, который остался в системе.
    if apt_get purge -y build-essential >/dev/null 2>&1; then
      apt_get autoremove --purge -y >/dev/null 2>&1 || true
      ok "build-essential и его зависимости удалены (нужны были только для сборки)"
    else
      warn "Не удалось удалить build-essential — при необходимости уберите вручную (apt-get purge build-essential)."
    fi
  fi
}

# Финальная уборка: архивы .deb и индексы apt, неиспользуемые (dangling) образы
# Docker от прежних версий образа ноды. Работающие образы и установленные пакеты
# не затрагиваются. Индексы apt восстанавливаются через apt-get update.
cleanup_system_leftovers() {
  apt_get clean >/dev/null 2>&1 || true
  rm -rf -- /var/lib/apt/lists/* 2>/dev/null || true
  if have docker && docker info >/dev/null 2>&1; then
    docker image prune -f >/dev/null 2>&1 || true
  fi
  ok "Очистка завершена. Свободно на /: $(df -Pm / | awk 'NR==2{print $4}' 2>/dev/null || echo '?') МБ"
}

have() { command -v "$1" >/dev/null 2>&1; }
# has_tty: есть ли управляющий терминал для интерактивных вопросов
has_tty() { { : >/dev/tty; } 2>/dev/null; }
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

is_ipv6() {
  local ip="$1" part rest
  local -a parts=()
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ "$ip" != *:::* ]] || return 1
  # сжатие "::" допустимо только один раз
  if [[ "$ip" == *"::"* ]]; then
    rest="${ip#*::}"
    [[ "$rest" != *"::"* ]] || return 1
  fi
  IFS=: read -r -a parts <<<"$ip"
  (( ${#parts[@]} <= 8 )) || return 1
  for part in "${parts[@]}"; do
    [[ ${#part} -le 4 ]] || return 1
  done
  if [[ "$ip" == *"::"* ]]; then
    # Одинарный ":" не может ни начинать, ни заканчивать адрес: единственное
    # допустимое сжатие — "::" (сам адрес "::" проходит обе проверки).
    [[ "$ip" == ::* || "$ip" != :* ]] || return 1
    [[ "$ip" == *:: || "$ip" != *: ]] || return 1
  else
    # Без сжатия "::" адрес обязан состоять ровно из 8 групп и не начинаться
    # либо заканчиваться двоеточием — иначе «висячие» одинарные двоеточия
    # (":1:2:3:4:5:6:7" и "1:2:3:4:5:6:7:") ошибочно проходили бы валидацию.
    (( ${#parts[@]} == 8 )) || return 1
    [[ "$ip" != :* && "$ip" != *: ]] || return 1
  fi
}

is_private_ipv4() {
  # Локальные, loopback, link-local и CGNAT-адреса: публичный IP, определённый
  # как один из них, означает сервер за NAT — сравнение с DNS будет неверным.
  local ip="$1"
  [[ "$ip" == 10.* || "$ip" == 127.* || "$ip" == 192.168.* \
      || "$ip" == 169.254.* || "$ip" == 0.* ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  return 1
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
  # TLD — только буквами либо в punycode (xn--...): иначе домены вроде
  # example.xn--p1ai отвергались бы как некорректные.
  [[ "${labels[-1]}" =~ ^([a-zA-Z]{2,63}|xn--[a-zA-Z0-9-]{2,59})$ ]]
}

is_safe_xhttp_path() {
  local pattern='^/[a-zA-Z0-9._~!()*+,;=:@%/-]*$'
  [[ ${#1} -le 2048 && "$1" =~ $pattern ]]
}

# ——— Cloudflare: автоматические A-записи с осмысленными случайными именами ———
# Поддомены собираются из двух словарей как «прилагательное-существительное»:
# в отличие от usa1/usa3 нумерация не выдаёт связь между записями, а четыре
# разных слова делают два хоста визуально непохожими друг на друга.
CF_HOST_ADJ=(quiet brisk amber coral golden vivid mellow crisp gentle lofty lucid nimble placid rugged serene slender sturdy tranquil azure bright clever frosty misty silken snowy sober solid sunny tidy wavy warm wild windy zesty merry prime rapid calm jolly mild)
CF_HOST_NOUN=(otter lantern drift fern ridge cove beacon birch cinder clover dune ember falcon fjord flare forest garnet glade granite grove hazel heron iris jade jetty juniper kelp lagoon laurel lilac linen lotus maple mesa moss nectar nickel olive onyx orbit pebble pewter pine prairie quartz quarry raven reef rivet ruby sage shale shore sienna spruce stone thistle tide timber topaz valley velvet willow zenith zephyr)
CF_API_BASE="https://api.cloudflare.com/client/v4"

# Индекс [0, n) из криптографически случайных байтов (не $RANDOM).
cf_rand_index() {
  local n="${1:-}" raw
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  raw="$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d '[:space:]')"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' $(( raw % n ))
}

# N случайных hex-символов из /dev/urandom — суффиксы случайных путей
# транспортов в быстром режиме (путь не должен быть одинаковым у всех нод).
random_hex() {
  local n="${1:-8}" bytes hex
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  bytes=$(( (n + 1) / 2 ))
  hex="$(od -An -N"$bytes" -tx1 </dev/urandom 2>/dev/null | tr -d '[:space:]')"
  [[ "$hex" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s' "${hex:0:$n}"
}

# Случайный API-подобный путь вида <префикс>/<8 hex> для транспортов.
gen_random_api_path() {
  local prefix="${1:-/api/v3/sync}" suffix
  suffix="$(random_hex 8)" || return 1
  printf '%s/%s' "$prefix" "$suffix"
}

# Уникальный CDN-поддомен для каждой ноды: cdn-<6 hex>.<базовый домен>.
# Поддомен первого уровня (*.example.com) покрывается бесплатным Universal SSL
# Cloudflare (в отличие от <rand>.cdn.example.com, требующего платный ACM) и не
# конфликтует при размещении нескольких нод на одном базовом домене.
gen_cdn_host() {
  local base="${1:-${BASE_DOMAIN:-}}" suffix=""
  [[ -n "$base" ]] || return 1
  suffix="$(random_hex 6 2>/dev/null || true)"
  [[ -n "$suffix" ]] || suffix="node01"
  printf 'cdn-%s.%s' "$suffix" "$base"
}

# Случайный порт Node API для быстрого режима: диапазон 11000–59999 не
# пересекается с портами схемы (80/443/9443/9444/10443–10448), а SSH-порт
# дополнительно исключается, если его удалось определить.
random_node_port() {
  local idx port guard=0 ssh_port=""
  if declare -F detect_ssh_port >/dev/null 2>&1; then
    ssh_port="$(detect_ssh_port 2>/dev/null || true)"
  fi
  while (( guard < 50 )); do
    idx="$(cf_rand_index 49000)" || return 1
    port=$(( 11000 + idx ))
    if [[ "$port" != "$ssh_port" && "$port" != "${SSH_PORT_OVERRIDE:-}" ]]; then
      printf '%s' "$port"
      return 0
    fi
    guard=$((guard + 1))
  done
  return 1
}

# Приводит короткую ссылку на образ (например, «latest» или «3.1.1», в т. ч.
# из старых env-файлов) к полному репозиторию remnawave/node:<тег>. Без слэша
# Docker ищет library/<имя> в Docker Hub и падает с
# «pull access denied for latest, repository does not exist».
normalize_node_image() {
  local img="${1:-}"
  img="$(printf '%s' "$img" | tr -d '[:space:]')"
  if [[ -z "$img" ]]; then
    printf 'remnawave/node:latest'
  elif [[ "$img" != */* ]]; then
    if [[ "$img" == @sha256:* ]]; then
      printf 'remnawave/node%s' "$img"
    elif [[ "$img" == *:* || "$img" == *@* ]]; then
      printf 'remnawave/%s' "$img"
    else
      printf 'remnawave/node:%s' "$img"
    fi
  else
    printf '%s' "$img"
  fi
}

# Домен, как его вводят люди (https://Example.COM/, www.example.com.),
# приводим к чистому виду example.com: без схемы, www, путей, порта и
# хвостовой точки. Валидацию не делаем — её выполнит is_fqdn у вызывающего.
normalize_domain_input() {
  local d="${1:-}"
  d="$(printf '%s' "$d" | tr -d '[:space:]')"
  d="${d,,}"
  d="${d#https://}"
  d="${d#http://}"
  d="${d%%/*}"
  d="${d%%:*}"
  d="${d%.}"
  d="${d#www.}"
  printf '%s' "$d"
}

# URL панели приводим к виду https://panel.example.com: схему добавляем,
# если её нет (панель почти всегда за HTTPS), хвостовой слэш срезаем.
# Возврат 1 — из ввода нельзя получить осмысленный URL.
normalize_panel_url() {
  local u="${1:-}" rest host
  u="$(printf '%s' "$u" | tr -d '[:space:]')"
  [[ -n "$u" ]] || return 1
  case "$u" in
    http://*|https://*) ;;
    *://*) return 1 ;;
    *) u="https://$u" ;;
  esac
  u="${u%/}"
  rest="${u#*://}"
  # Разрешён только origin без пути: иначе запросы API пойдут по неверному URL.
  [[ "$rest" != */* ]] || return 1
  if [[ "$rest" == \[* ]]; then
    host="${rest%%]*}"
    host="${host#\[}"
    is_ipv6 "$host" || return 1
  else
    host="${rest%%/*}"
    host="${host%%:*}"
    { is_fqdn "$host" || is_ipv4 "$host"; } || return 1
  fi
  printf '%s' "$u"
}

# Хост из URL панели (без схемы, порта и пути) — чтобы определить IP панели.
panel_url_host() {
  local rest="${1:-}" host
  rest="${rest#*://}"
  if [[ "$rest" == \[* ]]; then
    host="${rest%%]*}"
    printf '%s' "${host#\[}"
    return 0
  fi
  host="${rest%%/*}"
  host="${host%%:*}"
  printf '%s' "$host"
}

# Первый IPv4 хоста по DNS (сам IPv4 возвращается как есть): дефолт для
# PANEL_IP, чтобы пользователь не вводил адрес панели второй раз.
resolve_ipv4_host() {
  local host="${1:-}" ip
  [[ -n "$host" ]] || return 1
  if is_ipv4 "$host"; then
    printf '%s' "$host"
    return 0
  fi
  have dig || return 1
  ip="$(dig +short "$host" A 2>/dev/null \
        | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}')"
  is_ipv4 "$ip" || return 1
  printf '%s' "$ip"
}

# Два непохожих хоста «прилагательное-существительное.BASE_DOMAIN»:
# прилагательные и существительные не повторяются, поэтому хосты различаются
# в обеих частях. В stdout — ровно две строки.
cf_make_hosts() {
  local base="${1:-}" a1 a2 n1 n2 guard=0
  [[ -n "$base" ]] || return 1
  while :; do
    a1="$(cf_rand_index "${#CF_HOST_ADJ[@]}")" || return 1
    a2="$(cf_rand_index "${#CF_HOST_ADJ[@]}")" || return 1
    n1="$(cf_rand_index "${#CF_HOST_NOUN[@]}")" || return 1
    n2="$(cf_rand_index "${#CF_HOST_NOUN[@]}")" || return 1
    if (( a1 != a2 && n1 != n2 )); then break; fi
    guard=$((guard + 1))
    (( guard < 20 )) || return 1
  done
  printf '%s-%s.%s\n%s-%s.%s\n' \
    "${CF_HOST_ADJ[$a1]}" "${CF_HOST_NOUN[$n1]}" "$base" \
    "${CF_HOST_ADJ[$a2]}" "${CF_HOST_NOUN[$n2]}" "$base"
}

# Сохранённый в прошлый раз хост переиспользуем, только если он валиден и лежит
# в текущем BASE_DOMAIN: при смене базового домена старые имена бессмысленны.
cf_valid_saved_host() {
  local host="${1:-}" base="${2:-}"
  [[ -n "$host" && -n "$base" ]] || return 1
  is_fqdn "$host" && [[ "$host" == *".$base" ]]
}

# cf_api METHOD PATH [JSON-ТЕЛО] → JSON в stdout. Токен уходит не в argv, а
# через файл конфигурации curl (-K), поэтому его не видно в ps и в логе.
cf_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS --max-time 20 -X "$method" -K "$CF_CURL_CFG" -H "Content-Type: application/json")
  if [[ -n "$body" ]]; then args+=(-d "$body"); fi
  curl "${args[@]}" "$CF_API_BASE$path"
}

cf_json_success() {
  jq -e '.success == true' >/dev/null 2>&1 <<<"$1"
}
cf_json_error() {
  local msg
  msg="$(jq -r '.errors[0].message // empty' <<<"$1" 2>/dev/null)"
  printf '%s' "${msg:-неизвестная ошибка Cloudflare API}"
}

# Токен не должен попадать ни в argv curl (видно в ps), ни в лог: он живёт
# во временном файле 0600, который curl читает через -K.
cf_curl_cfg_init() {
  CF_CURL_CFG="$(mktemp)"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" > "$CF_CURL_CFG" )
}

# Проверяет, что Cloudflare API принимает токен и видит зону BASE_DOMAIN.
# Возвращает 0 при успехе, 1 при ошибке API/токена и 2 если зона не найдена.
cf_check_token_zone() {
  local resp zone_id
  cf_curl_cfg_init
  resp="$(cf_api GET "/zones?name=${CLOUDFLARE_ZONE:-$BASE_DOMAIN}&status=active" 2>/dev/null || true)"
  [[ -n "$CF_CURL_CFG" ]] && rm -f "$CF_CURL_CFG"
  CF_CURL_CFG=""
  [[ -n "$resp" ]] || return 1
  cf_json_success "$resp" || return 1
  zone_id="$(jq -r '.result[0].id // empty' <<<"$resp" 2>/dev/null)"
  [[ -n "$zone_id" ]] || return 2
}

# cf_upsert_a ZONE_ID HOST [proxied] — создать A-запись или обновить
# существующую на текущий SERVER_IP. По умолчанию запись DNS-only
# (proxied=false): оранжевое облако ломает и REALITY, и прямой Hysteria2
# (см. README, Cloudflare и DNS-only записи). Исключение — CDN-хост: там
# проксирование и есть весь смысл, поэтому для него передаётся «proxied».
cf_upsert_a() {
  local zone="$1" host="$2" mode="${3:-dns-only}" resp id
  local body
  if [[ "$mode" == proxied ]]; then
    body="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":true}' "$host" "$SERVER_IP")"
  else
    body="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":false}' "$host" "$SERVER_IP")"
  fi
  resp="$(cf_api GET "/zones/$zone/dns_records?type=A&name=$host")" \
    || die "Cloudflare API недоступен при чтении записи $host (сеть/HTTP)."
  cf_json_success "$resp" || die "Cloudflare API (чтение $host): $(cf_json_error "$resp")"
  id="$(jq -r '.result[0].id // empty' <<<"$resp")"
  if [[ -n "$id" ]]; then
    resp="$(cf_api PUT "/zones/$zone/dns_records/$id" "$body")" \
      || die "Cloudflare API недоступен при обновлении $host."
  else
    resp="$(cf_api POST "/zones/$zone/dns_records" "$body")" \
      || die "Cloudflare API недоступен при создании $host."
  fi
  cf_json_success "$resp" || die "Cloudflare API (запись $host): $(cf_json_error "$resp")"
  if [[ "$mode" == proxied ]]; then
    ok "Cloudflare: A-запись $host → $SERVER_IP (проксируется CDN, proxied=on)"
  else
    ok "Cloudflare: A-запись $host → $SERVER_IP (DNS only, proxied=off)"
  fi
}

# cf_a_exists ZONE_ID HOST → 0, если A-запись уже есть (иначе 1; die при ошибке API).
cf_a_exists() {
  local resp
  resp="$(cf_api GET "/zones/$1/dns_records?type=A&name=$2")" \
    || die "Cloudflare API недоступен при проверке $2."
  cf_json_success "$resp" || die "Cloudflare API (проверка $2): $(cf_json_error "$resp")"
  [[ -n "$(jq -r '.result[0].id // empty' <<<"$resp")" ]]
}

# Точка входа CF-режима: токен → зона → либо переиспользуем сохранённые хосты
# (идемпотентный повторный запуск), либо генерируем свободные случайные —
# и только потом создаём/обновляем обе A-записи и ждём их в DNS.
cf_setup_hosts() {
  have jq || die "Для режима Cloudflare нужен jq — он не установился на шаге 0."
  have curl || die "Для режима Cloudflare нужен curl."
  is_ipv4 "$SERVER_IP" \
    || die "Режим Cloudflare требует публичный IPv4 (SERVER_IP) для A-записей, но он не определён. Задайте SERVER_IP через env."
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] \
    || die "Режим Cloudflare требует токен: задайте CLOUDFLARE_API_TOKEN."
  local zone_name="${CLOUDFLARE_ZONE:-$BASE_DOMAIN}"
  is_fqdn "$zone_name" || die "Некорректное имя зоны Cloudflare: $zone_name"

  cf_curl_cfg_init

  local resp zone_id
  resp="$(cf_api GET "/zones?name=${zone_name}&status=active")" \
    || die "Cloudflare API недоступен (сеть или HTTP-ошибка)."
  cf_json_success "$resp" || die "Cloudflare API (зоны): $(cf_json_error "$resp")"
  zone_id="$(jq -r '.result[0].id // empty' <<<"$resp")"
  [[ -n "$zone_id" ]] \
    || die "Токен не видит зону $zone_name: нужны права Zone:Read и Zone:DNS:Edit; если BASE_DOMAIN — поддомен, задайте CLOUDFLARE_ZONE."
  # Идентификатор и имя зоны нужны и после cf_setup_hosts: cf_setup_cdn_host
  # переиспользует зону для проксируемой записи CDN-хоста, если тот в ней лежит.
  CF_ZONE_ID="$zone_id"
  CF_ZONE_NAME="$zone_name"
  ok "Cloudflare: зона $zone_name найдена"

  local -a cand=()
  if cf_valid_saved_host "${VLESS_HOST:-}" "$BASE_DOMAIN" \
      && cf_valid_saved_host "${HY_HOST:-}" "$BASE_DOMAIN"; then
    ok "Cloudflare: переиспользую хосты из сохранённых переменных: $VLESS_HOST / $HY_HOST"
  else
    local tries=0 found=0
    while (( tries < 5 )); do
      cand=()
      mapfile -t cand < <(cf_make_hosts "$BASE_DOMAIN")
      # Свободность проверяем до создания: случайное имя не должно
      # затереть чужую запись в зоне.
      if (( ${#cand[@]} == 2 )) \
          && ! cf_a_exists "$zone_id" "${cand[0]}" \
          && ! cf_a_exists "$zone_id" "${cand[1]}"; then
        VLESS_HOST="${cand[0]}"
        HY_HOST="${cand[1]}"
        found=1
        break
      fi
      tries=$((tries + 1))
    done
    (( found == 1 )) \
      || die "Не удалось подобрать свободные имена поддоменов в зоне $zone_name за 5 попыток."
    ok "Cloudflare: сгенерированы непохожие хосты: $VLESS_HOST / $HY_HOST"
  fi

  cf_upsert_a "$zone_id" "$VLESS_HOST"
  if [[ "$HY_HOST" != "$VLESS_HOST" ]]; then
    cf_upsert_a "$zone_id" "$HY_HOST"
  fi

  # Записи созданы — дожидаемся, пока резолвер их увидит, чтобы шаг 2
  # не засомневался в DNS, который мы только что настроили сами.
  if have dig; then
    local d i resolved=0
    for i in $(seq 1 10); do
      resolved=1
      for d in "$VLESS_HOST" "$HY_HOST"; do
        dig +short "$d" A 2>/dev/null \
          | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' \
          | grep -qxF "$SERVER_IP" || resolved=0
      done
      if (( resolved == 1 )); then break; fi
      sleep 3
    done
    if (( resolved == 1 )); then
      ok "A-записи уже видны резолверу"
    else
      warn "A-записи созданы, но ещё не резолвятся — шаг проверки DNS может предупредить."
    fi
  fi

  note "Готовый Config Profile с этими хостами сохраняется на шаге 1; в Hosts панели хосты впишите вручную (README, раздел Cloudflare)."
  rm -f "$CF_CURL_CFG"
  CF_CURL_CFG=""
}

# cf_zone_id_for_host HOST → id зоны в stdout (пустая строка и возврат 1,
# если токен не видит ни одной подходящей зоны или API недоступен). Зону
# ищем суффиксами хоста от длинного к короткому: для cdn.sub.example.com
# спрашиваем sub.example.com, затем example.com. Явный CLOUDFLARE_ZONE,
# накрывающий хост, спрашиваем первым.
cf_zone_id_for_host() {
  local host="${1:-}" zone resp id
  host="${host%.}"
  local -a candidates=()
  if [[ -n "${CLOUDFLARE_ZONE:-}" ]] \
      && { [[ "$host" == "$CLOUDFLARE_ZONE" ]] || [[ "$host" == *".${CLOUDFLARE_ZONE}" ]]; }; then
    candidates+=("$CLOUDFLARE_ZONE")
  fi
  zone="$host"
  while [[ "$zone" == *.* ]]; do
    candidates+=("$zone")
    zone="${zone#*.}"
  done
  for zone in "${candidates[@]}"; do
    resp="$(cf_api GET "/zones?name=${zone}&status=active")" || return 1
    cf_json_success "$resp" || return 1
    id="$(jq -r '.result[0].id // empty' <<<"$resp")"
    if [[ -n "$id" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done
  return 1
}

# Точка входа для CDN-хоста: проксируемая A-запись (оранжевое облако)
# через Cloudflare API. Намеренно НЕ зависит от CF_MODE: режим авто-ДНС
# блока 1 отвечает только за случайные хосты VLESS/Hysteria2, а CDN
# включается позже (блок 3) и токен там спрашивают отдельно. Раньше
# создание записи гейтилось на CF_MODE, поэтому при ответе «n» в блоке 1
# CDN-домен молча не создавался вообще, хотя токен для DNS-01 был введён.
# Исходы без создания (--no-cloudflare, нет токена, токен не видит зону)
# не останавливают установку, но обязаны быть громкими: CDN_DNS_MANAGED
# остаётся "manual" и показывается в сводке как действие для пользователя.
cf_setup_cdn_host() {
  CDN_DNS_MANAGED="manual"
  if [[ "${CF_MODE_SETTING:-}" == "0" ]]; then
    warn "CDN: A-запись для $CDN_HOST не создаю (--no-cloudflare): создайте вручную проксируемую A-запись $CDN_HOST → $SERVER_IP (оранжевое облако), иначе CDN не заработает."
    return 0
  fi
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    warn "CDN: нет CLOUDFLARE_API_TOKEN — A-запись для $CDN_HOST не создана: создайте вручную проксируемую A-запись $CDN_HOST → $SERVER_IP (оранжевое облако), иначе CDN не заработает."
    return 0
  fi
  have jq || die "Для создания A-записи CDN-хоста через Cloudflare нужен jq — он не установился на шаге 0."
  have curl || die "Для создания A-записи CDN-хоста через Cloudflare нужен curl."
  is_ipv4 "$SERVER_IP" \
    || die "Для A-записи CDN-хоста $CDN_HOST нужен публичный IPv4 (SERVER_IP), но он не определён. Задайте SERVER_IP через env."

  cf_curl_cfg_init
  local zone_id=""
  if [[ -n "${CF_ZONE_ID:-}" && -n "${CF_ZONE_NAME:-}" ]] \
      && { [[ "$CDN_HOST" == "$CF_ZONE_NAME" ]] || [[ "$CDN_HOST" == *".${CF_ZONE_NAME}" ]]; }; then
    zone_id="$CF_ZONE_ID"
    log "CDN: домен $CDN_HOST лежит в уже найденной зоне $CF_ZONE_NAME — создаю запись в ней"
  else
    zone_id="$(cf_zone_id_for_host "$CDN_HOST")" || zone_id=""
  fi
  if [[ -z "$zone_id" ]]; then
    rm -f "$CF_CURL_CFG"
    CF_CURL_CFG=""
    warn "CDN: токен Cloudflare не видит зону домена $CDN_HOST — A-запись не создана: создайте вручную проксируемую A-запись $CDN_HOST → $SERVER_IP (оранжевое облако) или проверьте права токена (Zone:Read) и CLOUDFLARE_ZONE. Без записи CDN не заработает."
    return 0
  fi
  cf_upsert_a "$zone_id" "$CDN_HOST" proxied
  rm -f "$CF_CURL_CFG"
  CF_CURL_CFG=""
  CDN_DNS_MANAGED="cloudflare"
}

# ——— self-steal: темы фасада ———
# Имя темы → URL шаблона в репозитории. Пустая тема означает, что пользователь
# задал SELF_STEAL_TEMPLATE_URL явно: свой фасад всегда важнее темы.
# Возвращает 1 на неизвестной теме — вызывающая сторона сама решает, как
# сообщить об этом (важно показать список доступных тем).
self_steal_template_url() {
  local theme="$1" known
  if [[ -z "$theme" ]]; then
    printf '%s\n' "$SELF_STEAL_TEMPLATE_URL"
    return 0
  fi
  for known in "${SELF_STEAL_TEMPLATES[@]}"; do
    if [[ "$known" == "$theme" ]]; then
      printf '%s/self-steal-templates/%s.html\n' "$SELF_STEAL_RAW_BASE" "$known"
      return 0
    fi
  done
  return 1
}

# Доступные темы — для подсказки об опечатке и для тестов (чтобы они не
# зависели от внутреннего массива с темами).
self_steal_template_list() {
  printf '%s\n' "${SELF_STEAL_TEMPLATES[@]}"
}

# CDN_TRANSPORT → включённые транспорты CDN. "both" (ws + xhttp) оставлен для
# совместимости со старыми env-файлами, "all" — все три транспорта. Функцию
# используют и промпты, и фильтр профиля, поэтому она вынесена отдельно.
# Вызывается как cdn_transport_enabled ws|xhttp|grpc; комментарий не пишется
# в строку с `{`: юнит-тест извлекает функцию по шаблону "скобка в конце строки".
cdn_transport_enabled() {
  case "$CDN_TRANSPORT:$1" in
    ws:ws | xhttp:xhttp | grpc:grpc | both:ws | both:xhttp | all:ws | all:xhttp | all:grpc)
      return 0
      ;;
  esac
  return 1
}

# ——— Config Profile (Multiselect.json) ———
# Панель отдаёт ноде серверный конфиг Xray из Config Profile, поэтому установщик
# сохраняет готовый файл: с подставленными хостами и без inbound'а XHTTP, когда
# XHTTP в selfsteal выключен. Иначе профиль разошёлся бы с Caddyfile и нода
# слушала бы порт 10444, к которому ничего не маршрутизируется.
#
# multiselect_filter — чистый фильтр: JSON шаблона на stdin, адаптированный JSON
# в stdout. Значения берутся из переменных установщика, поэтому функцию целиком
# покрывает tests/installer-funcs-checks.sh (на шаблоне из репозитория).
multiselect_filter() {
  # Набор включённых транспортов в виде JSON-массива для jq.
  local transports="" t
  for t in ws xhttp grpc; do
    if cdn_transport_enabled "$t"; then
      transports+="\"$t\","
    fi
  done
  transports="[${transports%,}]"
  jq --arg vision "$SELF_STEAL_HOST" \
     --arg hy "$HY_HOST" \
     --arg xsni "$XHTTP_SNI" \
     --arg xpath "$XHTTP_PATH" \
     --arg wspath "$CDN_WS_PATH" \
     --arg xhpath "$CDN_XHTTP_PATH" \
     --arg grpcpath "$CDN_GRPC_PATH" \
     --arg certdir "$CERT_DIR" \
     --argjson transports "$transports" \
     --argjson xhttp "$ENABLE_XHTTP" \
     --argjson cdn "$ENABLE_CDN" '
    # Транспорт CDN-инбаунда по его тегу (у остальных инбаундов — null).
    def cdn_transport(tag):
      if tag == "VLESS_CDN_WS" then "ws"
      elif tag == "VLESS_CDN_XHTTP" then "xhttp"
      elif tag == "VLESS_CDN_GRPC" then "grpc"
      else null end;
    .inbounds |= (
      map(select(
        # XHTTP в selfsteal выключен — убираем REALITY_XHTTP (и любой другой
        # xhttp-инбаунд), кроме CDN-инбаундов: у них своё условие ниже.
        (if $xhttp == 1 or (.tag | startswith("VLESS_CDN_"))
         then true
         else (.tag != "REALITY_XHTTP" and (.streamSettings.network // "") != "xhttp")
         end)
        and
        # CDN выключен — CDN-инбаундов быть не должно; включён — остаются только
        # те, что выбраны транспортом (ws, xhttp, grpc или их сочетания).
        # Транспорт фиксируется в $tr до пайпа: внутри `$transports | …` точка
        # уже указывает на массив транспортов, и `.tag` упал бы на нём.
        (if cdn_transport(.tag) == null then true
         else ($cdn == 1
               and (cdn_transport(.tag) as $tr
                    | ($transports | index($tr) != null)))
         end)
      ))
      | map(
          if .tag == "REALITY_VISION" then
            .streamSettings.realitySettings.serverNames = [$vision]
          elif .tag == "REALITY_XHTTP" then
            .streamSettings.realitySettings.serverNames = [$xsni]
            | .streamSettings.realitySettings.target = ($xsni + ":443")
            | .streamSettings.xhttpSettings.path = $xpath
          elif .tag == "HYSTERIA2" then
            .streamSettings.tlsSettings.serverName = $hy
            | .streamSettings.tlsSettings.certificates[0].keyFile = ($certdir + "/" + $hy + "/key.pem")
            | .streamSettings.tlsSettings.certificates[0].certificateFile = ($certdir + "/" + $hy + "/fullchain.pem")
          elif .tag == "VLESS_CDN_WS" then
            .streamSettings.wsSettings.path = $wspath
          elif .tag == "VLESS_CDN_XHTTP" then
            .streamSettings.xhttpSettings.path = $xhpath
          elif .tag == "VLESS_CDN_GRPC" then
            .streamSettings.grpcSettings.serviceName = $grpcpath
          else . end
        )
    )
  '
}

write_config_profile() {
  local src="" tmp="" out="$NODE_DIR/Multiselect.json"
  if ! have jq; then
    warn "jq недоступен — Config Profile не сохранён: возьмите Multiselect.json из репозитория вручную."
    return 0
  fi
  # Локальная копия шаблона рядом со скриптом главнее сети: запуск из клона
  # репозитория и тесты не должны зависеть от GitHub.
  if [[ -r "$SCRIPT_DIR/Multiselect.json" ]]; then
    src="$SCRIPT_DIR/Multiselect.json"
  else
    tmp="$(mktemp)"
    if retry 3 3 curl -fsSL "$MULTISELECT_TEMPLATE_URL" -o "$tmp"; then
      src="$tmp"
    else
      rm -f "$tmp"
      warn "Не удалось скачать $MULTISELECT_TEMPLATE_URL — Config Profile не сохранён (возьмите Multiselect.json из репозитория)."
      return 0
    fi
  fi
  mkdir -p "$NODE_DIR"
  # Сохраняем уже сгенерированные ключи REALITY при повторном запуске, чтобы не
  # ломать выданные подписки; для пустых privateKey/shortIds генерируем X25519
  # ключ (совместимый с Xray REALITY и resolveInboundAndPublicKey в Remnawave).
  local existing_reality='{}'
  if [[ -s "$out" ]]; then
    existing_reality="$(jq -c '
      [ .inbounds[]? | select(.streamSettings.realitySettings? != null)
        | select((.streamSettings.realitySettings.privateKey // "") != "")
        | { key: .tag, value: {
              privateKey: .streamSettings.realitySettings.privateKey,
              shortIds: (
                if ((.streamSettings.realitySettings.shortIds // []) | map(select(length > 0)) | length) > 0
                then (.streamSettings.realitySettings.shortIds | map(select(length > 0)))
                else [] end
              )
            } } ] | from_entries
    ' "$out" 2>/dev/null || echo '{}')"
  fi
  # Пишем через временный файл: jq не должен оставить обрезанный профиль.
  if multiselect_filter < "$src" > "$out.tmp" && [[ -s "$out.tmp" ]]; then
    if jq --argjson saved "$existing_reality" '
      .inbounds |= map(
        if (.streamSettings.realitySettings? != null) and (($saved[.tag] // null) != null) then
          .streamSettings.realitySettings.privateKey = $saved[.tag].privateKey
          | if (($saved[.tag].shortIds | length) > 0) then
              .streamSettings.realitySettings.shortIds = $saved[.tag].shortIds
            else . end
        else . end
      )
    ' "$out.tmp" > "$out.tmp2" && [[ -s "$out.tmp2" ]]; then
      mv -f "$out.tmp2" "$out.tmp"
    else
      rm -f "$out.tmp2"
    fi
    if have openssl; then
      local rtag rpriv rsid
      while IFS= read -r rtag; do
        [[ -n "$rtag" ]] || continue
        rpriv="$(openssl genpkey -algorithm X25519 -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=[:space:]' || true)"
        rsid="$(od -An -N4 -tx1 </dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "$rpriv" && -n "$rsid" ]]; then
          if jq --arg t "$rtag" --arg pk "$rpriv" --arg sid "$rsid" '
            .inbounds |= map(
              if .tag == $t then
                .streamSettings.realitySettings.privateKey = $pk
                | if (((.streamSettings.realitySettings.shortIds // []) | map(select(length > 0)) | length) == 0) then
                    .streamSettings.realitySettings.shortIds = [$sid]
                  else . end
              else . end
            )
          ' "$out.tmp" > "$out.tmp2" && [[ -s "$out.tmp2" ]]; then
            mv -f "$out.tmp2" "$out.tmp"
          else
            rm -f "$out.tmp2"
          fi
        fi
      done < <(jq -r '.inbounds[]? | select(.streamSettings.realitySettings? != null) | select((.streamSettings.realitySettings.privateKey // "") == "") | .tag' "$out.tmp" 2>/dev/null || true)
    fi
    install -m 644 "$out.tmp" "$out"
    rm -f "$out.tmp" "$tmp"
    local profile_inbounds="Vision/Reality + Hysteria2"
    if (( ENABLE_XHTTP )); then
      profile_inbounds="Vision/Reality + XHTTP + Hysteria2"
    fi
    if (( ENABLE_CDN )); then
      profile_inbounds+=" + CDN ($CDN_TRANSPORT)"
    fi
    ok "Config Profile сохранён: $out ($profile_inbounds)"
  else
    rm -f "$out.tmp" "$tmp"
    warn "Не удалось адаптировать шаблон Config Profile — используйте Multiselect.json из репозитория."
  fi
  return 0
}

write_xray_template() {
  local src="" out="$NODE_DIR/Xray_template.json"
  local choice="${XRAY_TEMPLATE_CHOICE:-standard}"
  # Нормализуем: standard или split — остальное считаем standard для безопасности
  if [[ "${choice,,}" == "split" ]]; then
    choice="split"
  else
    choice="standard"
  fi
  if [[ "$choice" == "split" ]]; then
    src="$SCRIPT_DIR/Xray_template_split.json"
    if [[ ! -r "$src" ]]; then
      src="$SCRIPT_DIR/../Xray_template_split.json"
    fi
    # Если запускаем не из репозитория, пробуем скачать
    if [[ ! -r "$src" ]]; then
      local tmp2
      tmp2="$(mktemp)"
      if retry 3 3 curl -fsSL "${SELF_STEAL_RAW_BASE}/Xray_template_split.json" -o "$tmp2" 2>/dev/null; then
        src="$tmp2"
      else
        rm -f "$tmp2"
        warn "Не удалось подготовить шаблон split — используйте Xray_template_split.json из репозитория."
        return 0
      fi
    fi
  else
    src="$SCRIPT_DIR/Xray_template.json"
    if [[ ! -r "$src" ]]; then
      src="$SCRIPT_DIR/../Xray_template.json"
    fi
    if [[ ! -r "$src" ]]; then
      local tmp2
      tmp2="$(mktemp)"
      if retry 3 3 curl -fsSL "${SELF_STEAL_RAW_BASE}/Xray_template.json" -o "$tmp2" 2>/dev/null; then
        src="$tmp2"
      else
        rm -f "$tmp2"
        warn "Не удалось подготовить шаблон standard — используйте Xray_template.json из репозитория."
        return 0
      fi
    fi
  fi
  mkdir -p "$NODE_DIR"
  if [[ -s "$src" ]]; then
    local xtag=""
    if declare -F panel_node_tag >/dev/null 2>&1; then
      xtag="$(panel_node_tag)"
    else
      xtag="$(printf '%s' "${VLESS_HOST%%.*}" | tr 'a-z-' 'A-Z_' | tr -cd 'A-Z0-9_:')"
      [[ -n "$xtag" ]] || xtag="NODE"
    fi
    sed \
      -e "s/\"balancerTag\": \"USA\"/\"balancerTag\": \"$xtag\"/g" \
      -e "s/\"tag\": \"USA\"/\"tag\": \"$xtag\"/g" \
      -e "s/\"pattern\": \"\\^USA\\$\"/\"pattern\": \"^${xtag}\$\"/g" \
      "$src" > "$out.tmp"
    install -m 644 "$out.tmp" "$out"
    rm -f "$out.tmp" "${tmp2:-}" 2>/dev/null || true
    if [[ "$choice" == "split" ]]; then
      ok "Шаблон подписки сохранён: $out (split-routing, тег $xtag)"
    else
      ok "Шаблон подписки сохранён: $out (standard — весь трафик через VPN, тег $xtag)"
    fi
  fi
  return 0
}

# ——— Авто-настройка панели через API (если выбран REMNAWAVE_AUTO_SETUP) ———
# Короткий детерминированный идентификатор текущей ноды (из VLESS_HOST или PREFIX).
panel_node_slug() {
  local raw=""
  if [[ -n "${VLESS_HOST:-}" ]]; then
    raw="${VLESS_HOST%%.*}"
  else
    raw="${PREFIX:-node}"
  fi
  raw="${raw//[^A-Za-z0-9_-]/_}"
  raw="${raw#_}"; raw="${raw%_}"
  [[ -n "$raw" ]] || raw="node"
  printf '%s' "$raw"
}

# Уникальный тег балансировки скрытых хостов этой ноды (формат Remnawave 3.x:
# ^[A-Z0-9_:]{1,36}$). У каждой ноды свой тег и свой XRAY_JSON шаблон, чтобы
# подписка не смешивала хосты разных нод под общим тегом «USA».
panel_node_tag() {
  local raw="${NODE_TAG:-}"
  if [[ -z "$raw" ]]; then
    raw="$(panel_node_slug)"
  fi
  raw="$(printf '%s' "$raw" | tr 'a-z-' 'A-Z_' | tr -cd 'A-Z0-9_:')"
  while [[ "$raw" == _* ]]; do raw="${raw#_}"; done
  while [[ "$raw" == *_ ]]; do raw="${raw%_}"; done
  raw="${raw:0:32}"
  [[ -n "$raw" ]] || raw="NODE"
  printf '%s' "$raw"
}

# Имя Config Profile: API разрешает только буквы, цифры, пробелы, «_» и «-»
# (точки из домена запрещены), длина 2–30 символов. Без штампа даты: повторный
# запуск в другой день обязан находить и обновлять профиль этой же ноды, а не
# плодить дубликаты и натыкаться на уникальность тегов inbound'ов в БД панели.
panel_profile_name() {
  local base="${BASE_DOMAIN:-auto}" host_part="" name
  base="${base//[^A-Za-z0-9_-]/-}"
  if [[ -n "${VLESS_HOST:-}" ]]; then
    host_part="${VLESS_HOST%%.*}"
    host_part="${host_part//[^A-Za-z0-9_-]/-}"
    name="multi-${host_part}-${base}"
  else
    name="multi-${base}"
  fi
  name="${name:0:30}"
  while [[ "$name" == *- ]]; do name="${name%-}"; done
  [[ ${#name} -ge 2 ]] || name="multi-node"
  printf '%s' "$name"
}

# Имя ноды в панели (3–30 символов, уникально в таблице nodes).
panel_node_name() {
  local name
  if [[ -n "${VLESS_HOST:-}" ]]; then
    name="node-${VLESS_HOST}"
  else
    name="node-${PREFIX:-auto}-${BASE_DOMAIN:-local}"
  fi
  name="${name:0:30}"
  while [[ "$name" == *- || "$name" == *. ]]; do name="${name%?}"; done
  [[ ${#name} -ge 3 ]] || name="node-auto"
  printf '%s' "$name"
}

# Возвращает каноническое базовое имя тега inbound'а независимо от суффикса ноды
# (например, REALITY_VISION_QUIET_OTTER → REALITY_VISION).
panel_canonical_inbound_tag() {
  local tag="${1:-}" base
  for base in REALITY_VISION REALITY_XHTTP HYSTERIA2 VLESS_CDN_WS VLESS_CDN_XHTTP VLESS_CDN_GRPC; do
    if [[ "$tag" == "$base" || "$tag" == "${base}_"* ]]; then
      printf '%s' "$base"
      return 0
    fi
  done
  printf '%s' "$tag"
}

# Подготавливает JSON Config Profile для отправки в Panel API:
#  1) переиспользует существующие REALITY privateKey/shortIds и теги этой же ноды;
#  2) гарантирует непустой X25519 privateKey + shortIds у всех REALITY inbound'ов
#     (панель Remnawave не генерирует ключи на сервере — с пустым privateKey Xray
#     не поднимает слушатели и подписка не выдаёт pbk);
#  3) обходит глобальный @@unique([tag]) в таблице config_profile_inbounds: если
#     базовый тег уже занят другим профилем в панели (вторая нода или старый
#     профиль), добавляет к тегам детерминированный суффикс текущей ноды.
panel_prepare_profile_for_api() {
  local profile_name="$1" profile_json="$2"
  local resp work_json saved_map='{}' other_tags='[]' slug suffix try_suffix n
  resp="$(panel_api GET "/config-profiles" 2>/dev/null || true)"

  saved_map="$(jq -c --arg n "$profile_name" '
    ((.response // .data // .)
      | if type=="object" and has("configProfiles") then .configProfiles
        elif type=="array" then .
        else [] end)
    | map(select(.name == $n))[0] // {}
    | [ (.config.inbounds // [])[]?
        | {
            tag: .tag,
            base: (
              if (.tag | startswith("REALITY_VISION")) then "REALITY_VISION"
              elif (.tag | startswith("REALITY_XHTTP")) then "REALITY_XHTTP"
              elif (.tag | startswith("HYSTERIA2")) then "HYSTERIA2"
              elif (.tag | startswith("VLESS_CDN_WS")) then "VLESS_CDN_WS"
              elif (.tag | startswith("VLESS_CDN_XHTTP")) then "VLESS_CDN_XHTTP"
              elif (.tag | startswith("VLESS_CDN_GRPC")) then "VLESS_CDN_GRPC"
              else .tag end
            ),
            privateKey: (.streamSettings.realitySettings.privateKey // ""),
            shortIds: ((.streamSettings.realitySettings.shortIds // []) | map(select(length > 0)))
          }
        | { key: .base, value: { tag: .tag, privateKey: .privateKey, shortIds: .shortIds } }
      ] | from_entries
  ' <<<"$resp" 2>/dev/null || echo '{}')"

  other_tags="$(jq -c --arg n "$profile_name" '
    ((.response // .data // .)
      | if type=="object" and has("configProfiles") then .configProfiles
        elif type=="array" then .
        else [] end)
    | map(select(.name != $n))
    | [ .[] | ((.inbounds // [])[]?.tag // empty), ((.config.inbounds // [])[]?.tag // empty) ]
    | unique
  ' <<<"$resp" 2>/dev/null || echo '[]')"

  work_json="$(jq -c --argjson saved "$saved_map" '
    .inbounds |= map(
      . as $inb
      | ($saved[$inb.tag] // null) as $prev
      | if $prev != null then
          .tag = ($prev.tag // .tag)
          | if (.streamSettings.realitySettings? != null) and (($prev.privateKey // "") != "") then
              .streamSettings.realitySettings.privateKey = $prev.privateKey
              | if (($prev.shortIds | length) > 0) then
                  .streamSettings.realitySettings.shortIds = $prev.shortIds
                else . end
            else . end
        else . end
    )
  ' <<<"$profile_json" 2>/dev/null || printf '%s' "$profile_json")"

  # Проверяем коллизию тегов с чужими профилями в панели.
  if jq -e --argjson other "$other_tags" '
    [ .inbounds[]?.tag ] | any(. as $t | ($other | index($t)) != null)
  ' <<<"$work_json" >/dev/null 2>&1; then
    slug="$(panel_node_slug | tr 'a-z-' 'A-Z_')"
    slug="${slug:0:16}"
    suffix="_${slug}"
    for n in 0 2 3 4 5 6 7 8 9; do
      if (( n == 0 )); then try_suffix="$suffix"; else try_suffix="${suffix}_${n}"; fi
      if ! jq -e --argjson other "$other_tags" --arg s "$try_suffix" '
        [ .inbounds[]?.tag
          | (if startswith("REALITY_VISION") then "REALITY_VISION"
             elif startswith("REALITY_XHTTP") then "REALITY_XHTTP"
             elif startswith("HYSTERIA2") then "HYSTERIA2"
             elif startswith("VLESS_CDN_WS") then "VLESS_CDN_WS"
             elif startswith("VLESS_CDN_XHTTP") then "VLESS_CDN_XHTTP"
             elif startswith("VLESS_CDN_GRPC") then "VLESS_CDN_GRPC"
             else . end) + $s
        ] | any(. as $t | ($other | index($t)) != null)
      ' <<<"$work_json" >/dev/null 2>&1; then
        suffix="$try_suffix"
        break
      fi
    done
    work_json="$(jq -c --arg s "$suffix" '
      .inbounds |= map(
        .tag = (
          (if (.tag | startswith("REALITY_VISION")) then "REALITY_VISION"
           elif (.tag | startswith("REALITY_XHTTP")) then "REALITY_XHTTP"
           elif (.tag | startswith("HYSTERIA2")) then "HYSTERIA2"
           elif (.tag | startswith("VLESS_CDN_WS")) then "VLESS_CDN_WS"
           elif (.tag | startswith("VLESS_CDN_XHTTP")) then "VLESS_CDN_XHTTP"
           elif (.tag | startswith("VLESS_CDN_GRPC")) then "VLESS_CDN_GRPC"
           else .tag end) + $s
        )
      )
    ' <<<"$work_json" 2>/dev/null || printf '%s' "$work_json")"
  fi

  # Страховка: если в Multiselect.json остались пустые ключи REALITY — генерируем.
  if have openssl; then
    local rtag rpriv rsid
    while IFS= read -r rtag; do
      [[ -n "$rtag" ]] || continue
      rpriv="$(openssl genpkey -algorithm X25519 -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=[:space:]' || true)"
      rsid="$(od -An -N4 -tx1 </dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -n "$rpriv" && -n "$rsid" ]]; then
        work_json="$(jq -c --arg t "$rtag" --arg pk "$rpriv" --arg sid "$rsid" '
          .inbounds |= map(
            if .tag == $t then
              .streamSettings.realitySettings.privateKey = $pk
              | if (((.streamSettings.realitySettings.shortIds // []) | map(select(length > 0)) | length) == 0) then
                  .streamSettings.realitySettings.shortIds = [$sid]
                else . end
            else . end
          )
        ' <<<"$work_json" 2>/dev/null || printf '%s' "$work_json")"
      fi
    done < <(jq -r '.inbounds[]? | select(.streamSettings.realitySettings? != null) | select((.streamSettings.realitySettings.privateKey // "") == "") | .tag' <<<"$work_json" 2>/dev/null || true)
  fi

  printf '%s' "$work_json"
}

# Результат функции, которая печатает диагностику (ok/warn) и лишь последней
# строкой — значение. Подоболочка $(...) смешивает их, поэтому значение берём
# ТОЛЬКО при успешном коде возврата: иначе текст предупреждения
# («▲ Не удалось создать…») стал бы uuid профиля и ушёл в URL запросов.
panel_result_uuid() {
  local out="${1:-}" rc="${2:-1}"
  (( rc == 0 )) || return 0
  printf '%s' "$out" | tail -1 | tr -d '[:space:]'
}

# panel_fetch_node_secret — получить SECRET_KEY ноды через Remnawave Panel API (GET /keygen).
# В Remnawave 3.x поле называется secretKey, в старых 2.x — pubKey.
# Возвращает чистый base64 ключ или пустую строку при ошибке.
panel_fetch_node_secret() {
  local resp key
  resp="$(panel_api_retry GET "/keygen" 2>/dev/null || true)"
  if panel_api_success "$resp"; then
    key="$(jq -r '.response.secretKey // .response.pubKey // .data.secretKey // .data.pubKey // .secretKey // .pubKey // empty' <<<"$resp" 2>/dev/null || true)"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    if [[ -n "$key" && "$key" != "null" ]]; then
      printf '%s' "$key"
      return 0
    fi
  fi
  return 1
}

# Обёртка для panel_upsert_host: в успешном случае молчим (функция печатает
# uuid в stdout — в консоли он не нужен), при ошибке показываем диагностику
# целиком и возвращаем ненулевой код, чтобы вызывающий её посчитал.
panel_try_host() {
  local out="" rc=0
  out="$(panel_upsert_host "$@" 2>/dev/null)" || rc=$?
  if (( rc != 0 )) && [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  fi
  return "$rc"
}

panel_find_profile_by_name() {
  local name="$1" resp uuid
  resp="$(panel_api GET "/config-profiles" 2>/dev/null || true)"
  # Remnawave 3.x: {response:{total, configProfiles:[...]}}; старые версии — массив
  uuid="$(jq -r --arg n "$name" '
    (.response // .data // .)
    | if type=="object" and has("configProfiles") then .configProfiles
      elif type=="array" then .
      else [] end
    | .[] | select(.name==$n) | .uuid // empty' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$uuid"
}

panel_get_inbounds() {
  local profile_uuid="$1" resp
  resp="$(panel_api GET "/config-profiles/$profile_uuid/inbounds" 2>/dev/null || true)"
  # Иногда панель отдаёт inbounds в /config-profiles/{uuid}, фолбэк
  if ! jq -e '.. | objects | has("uuid") and has("tag")' >/dev/null 2>&1 <<<"$resp"; then
    resp="$(panel_api GET "/config-profiles/$profile_uuid" 2>/dev/null || true)"
  fi
  # Выводим строки uuid|tag
  jq -r '.. | objects | select(has("uuid") and has("tag")) | "\(.uuid)|\(.tag)"' <<<"$resp" 2>/dev/null | sort -u
}

# Ищет существующую ноду в панели. В БД Remnawave уникален сам address (IP), а не
# пара (address, port), плюс уникально имя name — поэтому при смене порта ноды
# поиск по старому (address && port) не находил запись и POST /nodes падал с 409.
panel_find_node_by_address() {
  local addr="$1" port="${2:-}" expected_name="${3:-}" resp uuid
  resp="$(panel_api GET "/nodes" 2>/dev/null || true)"
  uuid="$(jq -r --arg a "$addr" --arg p "$port" --arg n "$expected_name" '
    ((.response // .data // .)
      | if type=="object" and has("nodes") then .nodes
        elif type=="array" then .
        else [] end) as $nodes
    | (
        [ $nodes[]? | select(.address == $a) | .uuid // empty ]
        + (if $n != "" then [ $nodes[]? | select(.name == $n) | .uuid // empty ] else [] end)
      )
    | map(select(length > 0))[0] // empty
  ' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$uuid"
}

panel_find_host_by_remark() {
  local remark="$1" resp uuid
  resp="$(panel_api GET "/hosts" 2>/dev/null || true)"
  uuid="$(jq -r --arg r "$remark" '
    (.response // .data // .)
    | if type=="object" and has("hosts") then .hosts
      elif type=="array" then .
      else [] end
    | .[] | select(.remark==$r) | .uuid // empty' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$uuid"
}

panel_upsert_config_profile() {
  local profile_name="$1" profile_json="$2"
  local existing_uuid payload resp result_uuid
  profile_json="$(panel_prepare_profile_for_api "$profile_name" "$profile_json")"
  existing_uuid="$(panel_find_profile_by_name "$profile_name" || true)"
  payload="$(jq -n --arg name "$profile_name" --argjson config "$profile_json" '{name: $name, config: $config}' 2>/dev/null || true)"
  if [[ -z "$payload" ]]; then
    warn "Не удалось собрать payload для Config Profile $profile_name"
    return 1
  fi
  if [[ -n "$existing_uuid" ]]; then
    # PATCH — полный replace, нужен uuid + config + name.
    # В актуальном API маршрут коллекционный: PATCH /config-profiles, uuid в теле.
    local patch_payload
    patch_payload="$(jq -n --arg uuid "$existing_uuid" --arg name "$profile_name" --argjson config "$profile_json" '{uuid: $uuid, name: $name, config: $config}' 2>/dev/null || true)"
    resp="$(panel_api_retry PATCH "/config-profiles" "$patch_payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      result_uuid="$existing_uuid"
      ok "Config Profile обновлён: $profile_name ($result_uuid)"
    else
      # Фолбэк для версий, где uuid передаётся в пути
      resp="$(panel_api_retry PATCH "/config-profiles/$existing_uuid" "$patch_payload" 2>/dev/null || true)"
      if panel_api_success "$resp"; then
        result_uuid="$existing_uuid"
        ok "Config Profile обновлён: $profile_name ($result_uuid)"
      else
        warn "Не удалось обновить Config Profile $profile_name: $(panel_api_error "$resp")"
        return 1
      fi
    fi
  else
    resp="$(panel_api_retry POST "/config-profiles" "$payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      result_uuid="$(jq -r '.response.uuid // .response.id // .data.uuid // .uuid // .id // empty' <<<"$resp" 2>/dev/null || true)"
      if [[ -z "$result_uuid" ]]; then result_uuid="(created)"; fi
      ok "Config Profile создан: $profile_name ($result_uuid)"
    else
      # Попытка создать без retry если ошибка 4xx с сообщением о дубликате — ищем снова
      if grep -qi "already exists\|duplicate\|conflict" <<<"$(panel_api_error "$resp")"; then
        existing_uuid="$(panel_find_profile_by_name "$profile_name" || true)"
        if [[ -n "$existing_uuid" ]]; then
          ok "Config Profile найден после конфликта дубликата: $profile_name ($existing_uuid)"
          result_uuid="$existing_uuid"
        else
          warn "Не удалось создать Config Profile (дубликат): $(panel_api_error "$resp")"
          return 1
        fi
      else
        warn "Не удалось создать Config Profile: $(panel_api_error "$resp")"
        return 1
      fi
    fi
  fi
  printf '%s' "$result_uuid"
}

panel_upsert_node() {
  local profile_uuid="$1" profile_inbounds_csv="$2" # comma-separated uuids
  local node_name
  node_name="$(panel_node_name)"
  local existing_uuid resp result_uuid
  existing_uuid="$(panel_find_node_by_address "$SERVER_IP" "$NODE_API_PORT" "$node_name" || true)"
  # Собираем activeInbounds как массив UUID
  local inbounds_json
  inbounds_json="$(printf '%s' "$profile_inbounds_csv" | jq -R 'split(",") | map(select(length>0))' 2>/dev/null || echo '[]')"
  local payload
  payload="$(jq -n --arg name "$node_name" --arg address "$SERVER_IP" --argjson port "$NODE_API_PORT" --arg uuid "$profile_uuid" --argjson inbounds "$inbounds_json" '{name: $name, address: $address, port: $port, countryCode: "XX", configProfile: {activeConfigProfileUuid: $uuid, activeInbounds: $inbounds}}' 2>/dev/null || true)"
  if [[ -z "$payload" ]]; then warn "Не удалось собрать payload ноды"; return 1; fi
  if [[ -n "$existing_uuid" ]]; then
    # PATCH существующей
    local patch_payload
    patch_payload="$(jq -n --arg uuid "$existing_uuid" --arg name "$node_name" --arg address "$SERVER_IP" --argjson port "$NODE_API_PORT" --arg prof "$profile_uuid" --argjson inbs "$inbounds_json" '{uuid: $uuid, name: $name, address: $address, port: $port, configProfile: {activeConfigProfileUuid: $prof, activeInbounds: $inbs}}' 2>/dev/null || true)"
    resp="$(panel_api_retry PATCH "/nodes" "$patch_payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      result_uuid="$existing_uuid"
      ok "Нода обновлена: $node_name ($result_uuid) → профиль $profile_uuid"
    else
      # Фолбэк для версий, где uuid передаётся в пути
      resp="$(panel_api_retry PATCH "/nodes/$existing_uuid" "$patch_payload" 2>/dev/null || true)"
      if panel_api_success "$resp"; then
        result_uuid="$existing_uuid"
        ok "Нода обновлена: $node_name ($result_uuid)"
      else
        warn "Не удалось обновить ноду: $(panel_api_error "$resp")"
        return 1
      fi
    fi
    # Если нода раньше отключалась панелью из-за пустого профиля — включаем обратно.
    panel_api POST "/nodes/$result_uuid/actions/enable" '{}' >/dev/null 2>&1 || true
  else
    resp="$(panel_api_retry POST "/nodes" "$payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      result_uuid="$(jq -r '.response.uuid // .data.uuid // .uuid // empty' <<<"$resp" 2>/dev/null || true)"
      if [[ -z "$result_uuid" ]]; then result_uuid="(created)"; fi
      ok "Нода создана: $node_name ($result_uuid) → профиль $profile_uuid"
    else
      warn "Не удалось создать ноду: $(panel_api_error "$resp")"
      note "Создайте вручную: Nodes → Management → + (IP $SERVER_IP, порт $NODE_API_PORT, профиль $profile_uuid)"
      return 1
    fi
  fi
  printf '%s' "$result_uuid"
}

# Инициирует немедленный запуск/синхронизацию Xray на ноде после старта контейнера
# remnanode (POST /nodes/{uuid}/actions/restart с {"forceRestart":false}), чтобы
# панель сразу отправила конфиг Xray и подняла слушатели к шагу 10.
panel_trigger_node_start() {
  local node_uuid="${1:-}" resp
  [[ -n "$node_uuid" && "$node_uuid" != "(created)" ]] || return 0
  if [[ -z "${REMNAWAVE_PANEL_URL:-}" || -z "${REMNAWAVE_API_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ -z "${PANEL_CURL_CFG:-}" || ! -f "$PANEL_CURL_CFG" ]]; then
    panel_curl_cfg_init
  fi
  if [[ -z "${PANEL_STATE_DIR:-}" ]]; then
    panel_state_init
  fi
  resp="$(panel_api_retry POST "/nodes/$node_uuid/actions/restart" '{"forceRestart":false}' 2>/dev/null || true)"
  if panel_api_success "$resp"; then
    ok "Панель запустила синхронизацию Xray с нодой ($node_uuid)"
  fi
  return 0
}

panel_upsert_host() {
  local profile_uuid="$1" inbound_uuid="$2" remark="$3" address="$4" port="$5" extra_json="${6:-}"
  local existing_uuid resp payload result_uuid
  existing_uuid="$(panel_find_host_by_remark "$remark" || true)"
  # Базовый payload
  payload="$(jq -n --arg r "$remark" --arg a "$address" --argjson p "$port" --arg pu "$profile_uuid" --arg iu "$inbound_uuid" '{remark: $r, address: $a, port: $p, inbound: {configProfileUuid: $pu, configProfileInboundUuid: $iu}}' 2>/dev/null || true)"
  # Добавляем extra (securityLayer, sni, path, tag и т.п.) если переданы
  if [[ -n "$extra_json" && "$extra_json" != "null" ]]; then
    payload="$(jq --argjson e "$extra_json" '. * $e' <<<"$payload" 2>/dev/null || echo "$payload")"
  fi
  if [[ -z "$payload" ]]; then warn "Не удалось собрать payload хоста $remark"; return 1; fi
  if [[ -n "$existing_uuid" ]]; then
    local patch_payload
    patch_payload="$(jq --arg uuid "$existing_uuid" '. + {uuid: $uuid}' <<<"$payload" 2>/dev/null || true)"
    resp="$(panel_api_retry PATCH "/hosts" "$patch_payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      ok "Хост обновлён: $remark → $address:$port (inbound $inbound_uuid)"
      result_uuid="$existing_uuid"
    else
      resp="$(panel_api_retry PATCH "/hosts/$existing_uuid" "$patch_payload" 2>/dev/null || true)"
      if panel_api_success "$resp"; then
        ok "Хост обновлён: $remark"
        result_uuid="$existing_uuid"
      else
        warn "Не удалось обновить хост $remark: $(panel_api_error "$resp")"
        return 1
      fi
    fi
  else
    resp="$(panel_api_retry POST "/hosts" "$payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      result_uuid="$(jq -r '.response.uuid // .data.uuid // .uuid // empty' <<<"$resp" 2>/dev/null || true)"
      ok "Хост создан: $remark → $address:$port"
    else
      # Дубликат remark — пробуем найти снова
      if grep -qi "already exists\|duplicate\|conflict" <<<"$(panel_api_error "$resp")"; then
        existing_uuid="$(panel_find_host_by_remark "$remark" || true)"
        if [[ -n "$existing_uuid" ]]; then
          ok "Хост найден после дубликата: $remark ($existing_uuid)"
          result_uuid="$existing_uuid"
        else
          warn "Не удалось создать хост $remark: $(panel_api_error "$resp")"
          return 1
        fi
      else
        warn "Не удалось создать хост $remark: $(panel_api_error "$resp")"
        return 1
      fi
    fi
  fi
  printf '%s' "$result_uuid"
}

panel_upsert_internal_squad() {
  local -a inbounds=("$@")
  local resp squad_uuid existing_json inbounds_json merged_json payload create_payload
  resp="$(panel_api GET "/internal-squads" 2>/dev/null || true)"
  inbounds_json="$(printf '%s\n' "${inbounds[@]}" | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]')"
  # Remnawave 3.x: {response:{total, internalSquads:[...]}}; старые версии — массив
  squad_uuid="$(jq -r '
    (.response // .data // .)
    | if type=="object" and has("internalSquads") then .internalSquads
      elif type=="array" then .
      else [] end
    | .[0].uuid // empty' <<<"$resp" 2>/dev/null || true)"
  if [[ -z "$squad_uuid" ]]; then
    create_payload="$(jq -n --argjson inbounds "$inbounds_json" '{name: "Default-Squad", inbounds: $inbounds}' 2>/dev/null || true)"
    if [[ -n "$create_payload" ]]; then
      resp="$(panel_api_retry POST "/internal-squads" "$create_payload" 2>/dev/null || true)"
      if panel_api_success "$resp"; then
        squad_uuid="$(jq -r '.response.uuid // .data.uuid // empty' <<<"$resp" 2>/dev/null || true)"
        ok "Internal Squad создан: Default-Squad (${squad_uuid:-ok})"
        return 0
      fi
    fi
    note "Internal Squad не найден — создайте его вручную и включите inbound'ы"
    return 0
  fi
  # PATCH заменяет массив inbound'ов целиком — объединяем с уже включёнными, чтобы
  # не отвязать другие ноды панели.
  existing_json="$(jq -c '
    (.response // .data // .)
    | if type=="object" and has("internalSquads") then .internalSquads
      elif type=="array" then .
      else [] end
    | [ .[0].inbounds[]? | if type=="object" then (.uuid // empty) else . end | select(length > 0) ]
  ' <<<"$resp" 2>/dev/null || echo '[]')"
  merged_json="$(jq -n -c --argjson a "$existing_json" --argjson b "$inbounds_json" '($a + $b) | unique' 2>/dev/null || printf '%s' "$inbounds_json")"
  payload="$(jq -n --arg uuid "$squad_uuid" --argjson inbounds "$merged_json" '{uuid: $uuid, inbounds: $inbounds}' 2>/dev/null || true)"
  resp="$(panel_api_retry PATCH "/internal-squads" "$payload" 2>/dev/null || true)"
  if panel_api_success "$resp"; then
    ok "Internal Squad обновлён: добавлены inbound'ы ($squad_uuid)"
  else
    resp="$(panel_api_retry PATCH "/internal-squads/$squad_uuid" "$payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      ok "Internal Squad обновлён (fallback): $squad_uuid"
    else
      warn "Не удалось обновить Internal Squad: $(panel_api_error "$resp") — включите inbound'ы вручную"
    fi
  fi
}

# Шаблоны в репозитории комментированы (JSON5), а Panel API принимает только
# строгий JSON. Убираем //-комментарии вне строк и висячие запятые перед }/].
# Важно: используем print с пустым ORS вместо printf "%s%s" — в mawk на
# Debian/Ubuntu буфер sprintf ограничен 8192 байтами и обнуляет Xray_template_split.json.
json5_to_json() {
  awk '
    {
      line=$0; out=""; instr=0; esc=0;
      for (i=1; i<=length(line); i++) {
        c=substr(line,i,1);
        if (instr) {
          out=out c;
          if (esc) esc=0;
          else if (c=="\\") esc=1;
          else if (c=="\"") instr=0;
        } else if (c=="\"") {
          instr=1; out=out c;
        } else if (c=="/" && substr(line,i,2)=="//") {
          break;
        } else {
          out=out c;
        }
      }
      buf=buf out "\n";
    }
    END {
      res="";
      while (match(buf, /,[ \t\r\n]*[}\]]/)) {
        m=substr(buf,RSTART,RLENGTH);
        sub(/^,[ \t\r\n]*/,"",m);
        res=res substr(buf,1,RSTART-1) m;
        buf=substr(buf,RSTART+RLENGTH);
      }
      ORS="";
      print res;
      print buf;
    }
  '
}

panel_find_subscription_template_uuid() {
  local tname="$1" resp code
  resp="$(panel_api GET "/subscription-templates" 2>/dev/null || true)"
  code="$(panel_api_code)"
  if ! panel_api_success "$resp" && [[ "$code" == "404" ]]; then
    resp="$(panel_api GET "/templates" 2>/dev/null || true)"
  fi
  jq -r --arg n "$tname" '
    (.response // .data // .)
    | if type=="object" and has("templates") then .templates
      elif type=="array" then .
      else [] end
    | .[]
    | select((.templateType == null) or (.templateType == "XRAY_JSON"))
    | select(.name==$n or .templateName==$n)
    | .uuid // empty' <<<"$resp" 2>/dev/null | head -1 || true
}

panel_upsert_subscription_template() {
  local choice="$1"
  local src="$NODE_DIR/Xray_template.json"
  local tname node_slug node_tag
  PANEL_TEMPLATE_UUID=""
  node_slug="$(panel_node_slug)"
  node_tag="$(panel_node_tag)"
  if [[ "${choice,,}" == "split" ]]; then
    tname="XRAY split ${node_slug}"
  else
    tname="XRAY standard ${node_slug}"
  fi
  if [[ ! -r "$src" ]] && declare -F write_xray_template >/dev/null 2>&1; then
    write_xray_template || true
  fi
  if [[ ! -r "$src" ]]; then
    warn "Шаблон подписки не найден: $src — не удалось загрузить XRAY_JSON шаблон в панель"
    return 1
  fi
  local content
  content="$(json5_to_json < "$src" 2>/dev/null | jq -c --arg tag "$node_tag" '
    (.routing.rules[]? | select(.balancerTag == "USA") | .balancerTag) = $tag
    | (.routing.balancers[]? | select(.tag == "USA") | .tag) = $tag
    | (.remnawave.injectHosts[]? | select(.selector.pattern == "^USA$") | .selector.pattern) = ("^" + $tag + "$")
  ' 2>/dev/null || true)"
  if [[ -z "$content" || "$content" == "null" ]]; then
    warn "Шаблон подписки $src не является корректным JSON — загрузите вручную: Templates → XRAY_JSON"
    return 1
  fi
  # Проверяем дубликат по имени. Remnawave 3.x: {response:{total, templates:[...]}}
  local resp existing_uuid code
  existing_uuid="$(panel_find_subscription_template_uuid "$tname")"
  if [[ -n "$existing_uuid" ]]; then
    local patch_payload
    patch_payload="$(jq -n --arg uuid "$existing_uuid" --argjson tmpl "$content" '{uuid: $uuid, templateJson: $tmpl}' 2>/dev/null || true)"
    resp="$(panel_api_retry PATCH "/subscription-templates" "$patch_payload" 2>/dev/null || true)"
    if panel_api_success "$resp"; then
      PANEL_TEMPLATE_UUID="$existing_uuid"
      ok "Шаблон подписки обновлён: $tname ($existing_uuid)"
      return 0
    fi
    warn "Шаблон подписки $tname ($existing_uuid) найден, но содержимое не обновлено: $(panel_api_error "$resp")"
    PANEL_TEMPLATE_UUID="$existing_uuid"
    return 1
  fi
  # POST создаёт имя и тип XRAY_JSON; содержимое загружается отдельным PATCH.
  local payload resp2 created_uuid content_payload
  payload="$(jq -n --arg name "$tname" '{name: $name, templateType: "XRAY_JSON"}' 2>/dev/null || true)"
  resp2="$(panel_api_retry POST "/subscription-templates" "$payload" 2>/dev/null || true)"
  code="$(panel_api_code)"
  if ! panel_api_success "$resp2" && [[ "$code" == "404" ]]; then
    resp2="$(panel_api_retry POST "/templates" "$payload" 2>/dev/null || true)"
    code="$(panel_api_code)"
  fi
  if ! panel_api_success "$resp2" && grep -qi "already exists\|duplicate\|conflict" <<<"$(panel_api_error "$resp2")"; then
    created_uuid="$(panel_find_subscription_template_uuid "$tname")"
  elif panel_api_success "$resp2"; then
    created_uuid="$(jq -r '.response.uuid // .data.uuid // .uuid // empty' <<<"$resp2" 2>/dev/null || true)"
    if [[ -z "$created_uuid" ]]; then
      created_uuid="$(panel_find_subscription_template_uuid "$tname")"
    fi
  else
    warn "Не удалось создать шаблон подписки $tname: $(panel_api_error "$resp2")"
    if [[ "$code" == "403" ]]; then
      note "Добавьте API-токену право subscription-template:* (Settings → API Tokens) или выдайте полный доступ *, затем перезапустите установщик."
    fi
    note "Без XRAY_JSON шаблона в подписке не работает балансировка скрытых хостов (файл шаблона: $src)."
    return 1
  fi

  if [[ -n "$created_uuid" ]]; then
    content_payload="$(jq -n --arg uuid "$created_uuid" --argjson tmpl "$content" '{uuid: $uuid, templateJson: $tmpl}' 2>/dev/null || true)"
    resp2="$(panel_api_retry PATCH "/subscription-templates" "$content_payload" 2>/dev/null || true)"
    if panel_api_success "$resp2"; then
      PANEL_TEMPLATE_UUID="$created_uuid"
      ok "Шаблон подписки создан: $tname ($created_uuid)"
      return 0
    fi
    warn "Шаблон подписки создан ($created_uuid), но не удалось загрузить JSON: $(panel_api_error "$resp2")"
    note "Вставьте $src вручную в Templates → $tname или перезапустите установщик."
    PANEL_TEMPLATE_UUID="$created_uuid"
    return 1
  fi

  warn "Шаблон подписки $tname создан без UUID — привяжите его к видимому хосту вручную (Templates → XRAY_JSON)"
  return 1
}

panel_auto_setup() {
  PANEL_NODE_UUID=""
  PANEL_TEMPLATE_UUID=""
  if (( ! REMNAWAVE_AUTO_SETUP )); then
    return 0
  fi
  if [[ -z "${REMNAWAVE_PANEL_URL:-}" || -z "${REMNAWAVE_API_TOKEN:-}" ]]; then
    warn "Авто-настройка панели включена, но не задан URL или токен — пропускаю."
    return 0
  fi
  if ! have jq || ! have curl; then
    warn "Для авто-настройки нужен jq и curl — пропускаю."
    return 0
  fi
  if [[ -z "${PANEL_CURL_CFG:-}" || ! -f "$PANEL_CURL_CFG" ]]; then
    panel_curl_cfg_init
  fi
  # HTTP-код запросов живёт в PANEL_STATE_DIR. Каталог обязан существовать в
  # родительской оболочке: panel_api вызывается через $(...) и созданный внутри
  # подоболочки каталог потерялся бы вместе с кодом (та же ошибка, из-за которой
  # «не удалось подключиться» появлялось при рабочем токене).
  if [[ -z "${PANEL_STATE_DIR:-}" ]]; then
    panel_state_init
  fi
  # Нормализуем URL (убираем хвостовой слэш)
  REMNAWAVE_PANEL_URL="${REMNAWAVE_PANEL_URL%/}"
  log "Авто-настройка панели Remnawave через API ($REMNAWAVE_PANEL_URL)..."

  local profile_json="" profile_uuid="" profile_name=""
  # API разрешает в имени только буквы, цифры, «_», «-» и пробелы: точки из
  # домена недопустимы, поэтому имя санируется и ограничивается 30 символами.
  profile_name="$(panel_profile_name)"

  if [[ -r "$NODE_DIR/Multiselect.json" ]]; then
    profile_json="$(cat "$NODE_DIR/Multiselect.json" 2>/dev/null || true)"
  fi
  if [[ -z "$profile_json" ]]; then
    warn "Config Profile не найден: $NODE_DIR/Multiselect.json — пропускаю авто-настройку"
    return 0
  fi
  # 1) Config Profile upsert
  local profile_out="" profile_rc=0
  profile_out="$(panel_upsert_config_profile "$profile_name" "$profile_json" 2>/dev/null)" \
    || profile_rc=$?
  profile_uuid="$(panel_result_uuid "$profile_out" "$profile_rc")"
  # Вывод функции перехвачен ради uuid — при ошибке показываем его целиком,
  # иначе причина («HTTP 403», «HTTP 500») пропадёт из лога.
  if (( profile_rc != 0 )) && [[ -n "$profile_out" ]]; then
    printf '%s\n' "$profile_out"
  fi
  # "(created)" — профиль создан, но API не вернул uuid: ищем по имени.
  if [[ -z "$profile_uuid" || "$profile_uuid" == "(created)" ]]; then
    profile_uuid="$(panel_find_profile_by_name "$profile_name" || true)"
  fi
  if [[ -z "$profile_uuid" ]]; then
    warn "Не удалось определить UUID Config Profile — хосты/нода не будут созданы автоматически"
    note "Создайте вручную: Config Profiles → Create → вставьте $NODE_DIR/Multiselect.json"
    return 1
  fi
  kv "Panel: Config Profile" "$profile_name ($profile_uuid)"

  # 2) Собираем inbounds профиля (ключуем по каноническому имени тега, чтобы
  # суффикс второй ноды не мешал привязке хостов).
  local inbounds_raw="" canon_tag=""
  inbounds_raw="$(panel_get_inbounds "$profile_uuid" 2>/dev/null || true)"
  declare -A INBOUND_UUID_BY_TAG=()
  while IFS='|' read -r uuid tag; do
    [[ -n "$uuid" && -n "$tag" ]] || continue
    canon_tag="$(panel_canonical_inbound_tag "$tag")"
    INBOUND_UUID_BY_TAG["$canon_tag"]="$uuid"
  done <<<"$inbounds_raw"

  if (( ${#INBOUND_UUID_BY_TAG[@]} == 0 )); then
    warn "Не удалось получить inbound'ы профиля $profile_uuid — нода/хосты будут созданы без привязки"
    note "Проверьте панель: Config Profiles → $profile_name → inbounds"
  else
    ok "Профиль содержит inbound'ы: ${!INBOUND_UUID_BY_TAG[*]}"
  fi

  # 3) Нода — собираем все inbound uuid для activeInbounds
  local inbounds_csv=""
  for tag in "${!INBOUND_UUID_BY_TAG[@]}"; do
    if [[ -n "$inbounds_csv" ]]; then inbounds_csv+=","; fi
    inbounds_csv+="${INBOUND_UUID_BY_TAG[$tag]}"
  done
  local node_uuid="" node_out="" node_rc=0 node_failed=0
  if [[ -n "$inbounds_csv" ]]; then
    node_out="$(panel_upsert_node "$profile_uuid" "$inbounds_csv" 2>/dev/null)" \
      || node_rc=$?
    node_uuid="$(panel_result_uuid "$node_out" "$node_rc")"
    if (( node_rc != 0 )) && [[ -n "$node_out" ]]; then
      printf '%s\n' "$node_out"
    fi
    if [[ "$node_uuid" == "(created)" ]]; then
      node_uuid="$(panel_find_node_by_address "$SERVER_IP" "$NODE_API_PORT" "$(panel_node_name)" || true)"
    elif [[ -z "$node_uuid" ]]; then
      node_failed=1
    fi
    if [[ -n "$node_uuid" ]]; then
      PANEL_NODE_UUID="$node_uuid"
      kv "Panel: Node" "$node_uuid ($SERVER_IP:$NODE_API_PORT)"
    fi
  fi

  # 4) Шаблон подписки загружаем до хостов, чтобы привязать его к видимому
  # виртуальному хосту подписки (xrayJsonTemplateUuid). Без этого шаблона
  # скрытые хосты не попадают в балансировщик подписки.
  local template_failed=0
  panel_upsert_subscription_template "$XRAY_TEMPLATE_CHOICE" || template_failed=1

  # 5) Хосты — скрытые рабочие (tags=[<node_tag>], isHidden=true для балансировщика
  # Xray_template.json этой ноды) + видимая оболочка подписки. В Remnawave 3.x допустимы
  # только securityLayer: DEFAULT | TLS | NONE («REALITY» вызывает HTTP 400).
  local host_count=0 host_failed=0 host_label="$PREFIX" node_tag extra
  node_tag="$(panel_node_tag)"
  if (( CF_MODE )) && [[ -n "${VLESS_HOST:-}" ]]; then
    host_label="${VLESS_HOST%%.*}"
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[REALITY_VISION]:-}" ]]; then
    extra="$(jq -n -c --arg sni "$SELF_STEAL_HOST" --arg tag "$node_tag" '{securityLayer:"DEFAULT", sni:$sni, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[REALITY_VISION]}" "VLESS Vision $host_label" "$VLESS_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[REALITY_XHTTP]:-}" && -n "$XHTTP_SNI" ]]; then
    extra="$(jq -n -c --arg sni "$XHTTP_SNI" --arg path "$XHTTP_PATH" --arg tag "$node_tag" '{securityLayer:"DEFAULT", sni:$sni, path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[REALITY_XHTTP]}" "VLESS XHTTP $host_label" "$VLESS_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[HYSTERIA2]:-}" ]]; then
    extra="$(jq -n -c --arg sni "$HY_HOST" --arg tag "$node_tag" '{securityLayer:"DEFAULT", sni:$sni, alpn:"h3", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[HYSTERIA2]}" "Hysteria2 $host_label" "$HY_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  # CDN хосты (внешний TLS терминирует CDN → securityLayer="TLS")
  if [[ -n "${INBOUND_UUID_BY_TAG[VLESS_CDN_WS]:-}" ]]; then
    extra="$(jq -n -c --arg host "$CDN_HOST" --arg path "${CDN_WS_PATH:-/api/v1/stream}" --arg tag "$node_tag" '{securityLayer:"TLS", sni:$host, host:$host, path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[VLESS_CDN_WS]}" "VLESS CDN WS $host_label" "$CDN_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[VLESS_CDN_XHTTP]:-}" ]]; then
    extra="$(jq -n -c --arg host "$CDN_HOST" --arg path "${CDN_XHTTP_PATH:-/api/v3/sync/c1}" --arg tag "$node_tag" '{securityLayer:"TLS", sni:$host, host:$host, path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[VLESS_CDN_XHTTP]}" "VLESS CDN XHTTP $host_label" "$CDN_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[VLESS_CDN_GRPC]:-}" ]]; then
    extra="$(jq -n -c --arg host "$CDN_HOST" --arg path "${CDN_GRPC_PATH:-/api/v4/stream}" --arg tag "$node_tag" '{securityLayer:"TLS", sni:$host, alpn:"h2", path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[VLESS_CDN_GRPC]}" "VLESS CDN gRPC $host_label" "$CDN_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  # Видимый виртуальный хост-оболочка для подписки (подключает XRAY_JSON шаблон)
  if [[ -n "${INBOUND_UUID_BY_TAG[REALITY_VISION]:-}" ]]; then
    if [[ -n "${PANEL_TEMPLATE_UUID:-}" ]]; then
      extra="$(jq -n -c --arg sni "$SELF_STEAL_HOST" --arg tmpl "$PANEL_TEMPLATE_UUID" '{securityLayer:"DEFAULT", sni:$sni, fingerprint:"chrome", tags:[], isHidden:false, xrayJsonTemplateUuid:$tmpl}')"
    else
      extra="$(jq -n -c --arg sni "$SELF_STEAL_HOST" '{securityLayer:"DEFAULT", sni:$sni, fingerprint:"chrome", tags:[], isHidden:false}')"
    fi
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[REALITY_VISION]}" "VPN $host_label" "$VLESS_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if (( host_count > 0 )); then
    ok "Хосты созданы/обновлены: $host_count шт. (проверьте Hosts в панели)"
  fi

  # 6) Internal Squad — объединить существующие и новые inbound'ы (или создать отряд)
  if (( ${#INBOUND_UUID_BY_TAG[@]} > 0 )); then
    local -a squad_inbounds=()
    for tag in "${!INBOUND_UUID_BY_TAG[@]}"; do squad_inbounds+=("${INBOUND_UUID_BY_TAG[$tag]}"); done
    panel_upsert_internal_squad "${squad_inbounds[@]}" || true
  fi

  if (( host_failed > 0 || node_failed || template_failed )); then
    local details=""
    if (( node_failed )); then details="нода не создана/не обновлена"; fi
    if (( template_failed )); then details="${details:+$details, }шаблон подписки XRAY не создан"; fi
    if (( host_failed > 0 )); then details="${details:+$details, }хостов с ошибкой: $host_failed"; fi
    warn "Авто-настройка панели завершена с ошибками: $details — проверьте Templates/Hosts/Nodes в панели и права токена (включая subscription-template:*)"
    return 1
  fi
  ok "Авто-настройка панели завершена: профиль=$profile_name, нода=$SERVER_IP:$NODE_API_PORT, шаблон=$PANEL_TEMPLATE_UUID, хостов=$host_count"
  return 0
}

apt_wait() {
  local -i waited=0
  # fuser приходит из пакета psmisc: он есть в списке базовых утилит шага 0, но
  # первый apt-get (update) идёт до их установки. Без fuser все проверки
  # блокировки молча ничего не делают (вывод перенаправлен в /dev/null), поэтому
  # ставим psmisc сами — напрямую apt-get, без apt_get, чтобы не уйти в рекурсию.
  # Если поставить не удалось (например, dpkg-lock держит другой процесс), просто
  # продолжаем: apt-get ниже сам подождёт освобождения блокировки.
  if ! have fuser; then
    if have apt-get; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y psmisc >/dev/null 2>&1 || true
    fi
    have fuser || return 0
  fi
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
  has_tty || die "Нет /dev/tty для вопроса «$__prompt». Запустите с --non-interactive и переменными окружения."
  if [[ -n "$__default" ]]; then
    printf ' %s?%s %s %s[%s]%s: ' "${C_MAG:-}${C_B:-}" "${C_RST:-}" "$__prompt" "${C_DIM:-}${C_GRY:-}" "$__default" "${C_RST:-}" > /dev/tty
    IFS= read -r __input < /dev/tty || true
    __input="${__input:-$__default}"
  else
    __input=""
    while [[ -z "$__input" ]]; do
      printf ' %s?%s %s: ' "${C_MAG:-}${C_B:-}" "${C_RST:-}" "$__prompt" > /dev/tty
      IFS= read -r __input < /dev/tty || true
    done
  fi
  printf -v "$__var" '%s' "$__input"
}

# ask_secret — как ask, но значение не печатается никогда: секреты не попадают
# ни на экран, ни в установочный лог (например SECRET_KEY ноды).
ask_secret() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input=""
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    [[ -n "$__default" ]] || die "--non-interactive: нет значения для «$__prompt» (задайте через env)."
    printf -v "$__var" '%s' "$__default"
    note "(auto) $__prompt = <скрыто, символов: ${#__default}>"
    return
  fi
  has_tty || die "Нет /dev/tty для ввода «$__prompt». Запустите с --non-interactive и переменными окружения."
  while [[ -z "$__input" ]]; do
    printf ' %s?%s %s (ввод скрыт): ' "${C_MAG:-}${C_B:-}" "${C_RST:-}" "$__prompt" > /dev/tty
    IFS= read -rs __input < /dev/tty || true
    printf '\n' > /dev/tty
  done
  printf -v "$__var" '%s' "$__input"
}

# parse_bool [значение] [дефолт] → 0|1 в stdout. Логические переменные приходят
# из трёх источников: интерактивного ответа, переменных окружения и сохранённого
# /root/remnanode.env (установщик прежних версий писал туда «1»), поэтому все
# распространённые написания должны пониматься одинаково, а мусор — не выключать
# функцию молча: вызывающий сам решает, что делать (см. ask_bool).
parse_bool() {
  local val="${1:-}" def="${2:-0}"
  case "${val,,}" in
    1|y|yes|true|on)  printf '1' ;;
    0|n|no|false|off) printf '0' ;;
    *)                printf '%s' "$def" ;;
  esac
}

# bool_yn 0|1 → y|n: так флаги записываются в /root/remnanode.env, чтобы файл
# читался человеком и одинаково понимался любым парсером (y* → включено).
bool_yn() {
  if [[ "${1:-0}" == 1 ]]; then
    printf 'y'
  else
    printf 'n'
  fi
}

# ask_bool VAR PROMPT DEFAULT(y/n) — вопрос с нормализацией ответа к 0/1.
# Непонятный ответ переспрашивается (или останавливает установку в
# --non-interactive), а не трактуется как «нет»: иначе опечатка тихо выключала бы
# CDN или XHTTP.
ask_bool() {
  local __var="$1" __prompt="$2" __default __val __tries=0
  __default="$(parse_bool "${3:-n}" 0)"
  while :; do
    ask "$__var" "$__prompt (y/n)" "$(bool_yn "$__default")"
    __val="${!__var}"
    case "${__val,,}" in
      1|y|yes|true|on|0|n|no|false|off)
        printf -v "$__var" '%s' "$(parse_bool "$__val" "$__default")"
        return 0
        ;;
    esac
    __tries=$((__tries + 1))
    (( __tries < 5 )) || die "Не понял ответ «$__val» на вопрос «$__prompt»: нужен y или n."
    warn "Ответ «$__val» не похож на y/n — введите y или n."
  done
}

# Флаги авто-режимов приходят и из env (например, ASSUME_YES=y в CI): приводим их
# к 0/1 тем же разбором, что и остальные логические переменные. Флаг командной
# строки главнее: -y/--yes уже выставил 1 выше, и нормализация это не отменит.
ASSUME_YES="$(parse_bool "${ASSUME_YES:-0}" 0)"
NONINTERACTIVE="$(parse_bool "${NONINTERACTIVE:-0}" 0)"
KEEP_BUILD_TOOLS="$(parse_bool "${KEEP_BUILD_TOOLS:-0}" 0)"

# confirm "вопрос" "дефолт(y/n)" -> 0 если да, 1 если нет; уважает --yes/--non-interactive
confirm() {
  local __prompt="$1" __default="${2:-n}" __ans
  if [[ "$ASSUME_YES" == 1 ]]; then
    note "(auto-yes) $__prompt"
    return 0
  fi
  # Ответ нормализуется тем же ask_bool: «1», «yes» и «y» здесь равнозначны, а
  # непонятный ответ переспрашивается, а не читается как «нет».
  ask_bool __ans "$__prompt" "$__default"
  [[ "$__ans" == 1 ]]
}

# ask_choice VAR PROMPT DEFAULT_NUM "вариант1: описание" "вариант2: описание" ...
# Понятный выбор из списка для обычного пользователя — нумерованное меню.
ask_choice() {
  local __var="$1" __prompt="$2" __default="$3"
  shift 3
  local -a __opts=("$@")
  local __i __input __choice __key
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    [[ -n "$__default" ]] || die "--non-interactive: нет значения для «$__prompt» (задайте через env)."
    # В авто-режиме __default — номер варианта, берём ключ по номеру
    if [[ "$__default" =~ ^[0-9]+$ ]] && (( __default >= 1 && __default <= ${#__opts[@]} )); then
      __key="${__opts[$((__default-1))]%%:*}"
      printf -v "$__var" '%s' "$__key"
    else
      printf -v "$__var" '%s' "$__default"
    fi
    note "(auto) $__prompt = ${!__var}"
    return
  fi
  has_tty || die "Нет /dev/tty для вопроса «$__prompt». Запустите с --non-interactive и переменными окружения."
  {
    printf '\n'
    printf ' %s%s%s\n' "${C_B:-}${C_CYN:-}" "$__prompt" "${C_RST:-}"
    printf ' %s%s%s\n' "${C_DIM:-}${C_GRY:-}" "$RULE" "${C_RST:-}"
    for __i in "${!__opts[@]}"; do
      __key="${__opts[$__i]%%:*}"
      __choice="${__opts[$__i]#*:}"
      if [[ "$__key" == "${__opts[$__i]}" ]]; then __choice="$__key"; fi
      if (( __i + 1 == __default )); then
        printf '   %s%s %d)%s %s %s[по умолчанию]%s\n' "${C_B:-}${C_GRN:-}" "${C_RST:-}" "$((__i+1))" "${C_B:-}" "$__choice" "${C_DIM:-}${C_GRY:-}" "${C_RST:-}"
      else
        printf '   %s %d)%s %s\n' "${C_GRY:-}" "$((__i+1))" "${C_RST:-}" "$__choice"
      fi
    done
    printf ' %s%s%s\n' "${C_DIM:-}${C_GRY:-}" "$RULE" "${C_RST:-}"
  } > /dev/tty
  while :; do
    printf ' %s?%s Выберите номер [%s]: ' "${C_MAG:-}${C_B:-}" "${C_RST:-}" "$__default" > /dev/tty
    IFS= read -r __input < /dev/tty || true
    __input="${__input:-$__default}"
    if [[ "$__input" =~ ^[0-9]+$ ]] && (( __input >= 1 && __input <= ${#__opts[@]} )); then
      __key="${__opts[$((__input-1))]%%:*}"
      printf -v "$__var" '%s' "$__key"
      return
    fi
    warn "Введите число от 1 до ${#__opts[@]}." > /dev/tty
  done
}

# ——— Remnawave Panel API: автоматическая настройка ———
panel_curl_cfg_init() {
  local token
  # Токен — JWT/base64url без пробелов; случайно вставленный пробел или
  # перевод строки в заголовке сделал бы его невалидным.
  token="$(printf '%s' "${REMNAWAVE_API_TOKEN:-}" | tr -d '[:space:]')"
  # Повторный ввод токена не должен оставлять прежний файл с секретом в /tmp.
  if [[ -n "${PANEL_CURL_CFG:-}" && -f "${PANEL_CURL_CFG}" ]]; then
    rm -f -- "$PANEL_CURL_CFG"
  fi
  PANEL_CURL_CFG="$(mktemp)"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$token" > "$PANEL_CURL_CFG" )
  panel_state_init
}

# panel_api вызывают из $(...), а переменные, выставленные в подоболочке, до
# вызывающего не доходят. Поэтому HTTP-код и ошибку curl храним в файлах:
# иначе panel_api_success всегда видел пустой код и ЛЮБОЙ ответ панели считал
# ошибкой — даже 200 с валидным токеном («не удалось подключиться»).
PANEL_HTTP_BODY=""
PANEL_HTTP_CODE_FILE=""
PANEL_HTTP_ERROR_FILE=""

# Пути берутся из приватного каталога PANEL_STATE_DIR: его создаёт
# родительская оболочка, а подоболочки $(...) наследуют путь. Поэтому HTTP-код,
# записанный внутри panel_api, читается вызывающим.
panel_http_code_file() {
  if [[ -n "${PANEL_HTTP_CODE_FILE:-}" ]]; then
    printf '%s' "$PANEL_HTTP_CODE_FILE"
  elif [[ -n "${PANEL_STATE_DIR:-}" ]]; then
    printf '%s' "$PANEL_STATE_DIR/code"
  fi
}

panel_http_error_file() {
  if [[ -n "${PANEL_HTTP_ERROR_FILE:-}" ]]; then
    printf '%s' "$PANEL_HTTP_ERROR_FILE"
  elif [[ -n "${PANEL_STATE_DIR:-}" ]]; then
    printf '%s' "$PANEL_STATE_DIR/error"
  fi
}

panel_state_init() {
  # Приватный каталог создаётся в родительской оболочке (panel_curl_cfg_init),
  # а подоболочки $(...) наследуют его путь: поэтому HTTP-код, записанный
  # внутри panel_api, читается снаружи. Предсказуемых имён в /tmp нет —
  # установщик работает от root, и symlink-атака исключена.
  if [[ -z "${PANEL_STATE_DIR:-}" ]]; then
    PANEL_STATE_DIR="$(mktemp -d)"
  fi
  PANEL_HTTP_CODE_FILE="${PANEL_HTTP_CODE_FILE:-$PANEL_STATE_DIR/code}"
  PANEL_HTTP_ERROR_FILE="${PANEL_HTTP_ERROR_FILE:-$PANEL_STATE_DIR/error}"
  ( umask 077; : > "$PANEL_HTTP_CODE_FILE"; : > "$PANEL_HTTP_ERROR_FILE" )
}

panel_api_code() {
  local code="" code_file
  code_file="$(panel_http_code_file)"
  if [[ -r "$code_file" ]]; then
    code="$(tr -d '[:space:]' < "$code_file" 2>/dev/null || true)"
  fi
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s' "$code"
}

# Тело ответа — в stdout, HTTP-код — в PANEL_HTTP_CODE_FILE,
# ошибка транспорта curl — в PANEL_HTTP_ERROR_FILE.
panel_api() {
  local method="$1" path="$2" body="${3:-}"
  local url="${REMNAWAVE_PANEL_URL%/}/api$path"
  local -a args=(-sS --max-time 25 -X "$method" -K "$PANEL_CURL_CFG" -H "Content-Type: application/json" -w "\n%{http_code}")
  local body_file=""
  if [[ -n "$body" ]]; then
    body_file="$(mktemp)"
    printf '%s' "$body" > "$body_file"
    args+=(--data-binary "@$body_file")
  fi
  panel_state_init
  local raw rc code err_file err_text
  err_file="$(mktemp)"
  # Присваивание в условии: иначе set -e завершит установщик на сетевой
  # ошибке curl раньше, чем мы сохраним её текст для пользователя.
  if raw="$(curl "${args[@]}" "$url" 2>"$err_file")"; then rc=0; else rc=$?; fi
  err_text="$(tr '\n' ' ' < "$err_file" 2>/dev/null | cut -c1-300 || true)"
  rm -f "$err_file" "${body_file:-}"
  # Последняя строка — HTTP код, остальное — тело
  code="${raw##*$'\n'}"
  if [[ "$code" =~ ^[0-9]{3}$ ]]; then
    raw="${raw%$'\n'*}"
  else
    code="000"
  fi
  # Ненулевой код возврата curl означает, что HTTP-ответа не было вовсе
  # (DNS, TLS, таймаут): даже «000» от -w в этом случае не доверяем.
  if (( rc != 0 )); then code="000"; fi
  printf '%s' "$code" > "$(panel_http_code_file)"
  printf '%s' "$err_text" > "$(panel_http_error_file)"
  PANEL_HTTP_BODY="$raw"
  printf '%s' "$raw"
}

panel_api_success() {
  # Код должен быть 2xx и JSON без errors
  if ! [[ "$(panel_api_code)" =~ ^2[0-9]{2}$ ]]; then return 1; fi
  # Успешный ответ панели содержит либо response, либо success:true, и не содержит ошибок
  local body="${1:-$PANEL_HTTP_BODY}"
  if jq -e '.success == false' >/dev/null 2>&1 <<<"$body"; then return 1; fi
  if jq -e '.errors and (.errors|length>0)' >/dev/null 2>&1 <<<"$body"; then return 1; fi
  jq -e '.response != null or .success == true or .data != null or has("response") or has("data")' >/dev/null 2>&1 <<<"$body"
}

panel_api_error() {
  local msg code api_code body="${1:-$PANEL_HTTP_BODY}" error_file=""
  code="$(panel_api_code)"
  if [[ "$code" == "000" ]]; then
    error_file="$(panel_http_error_file)"
    if [[ -n "$error_file" && -r "$error_file" ]]; then
      msg="$(tr -s '[:space:]' ' ' < "$error_file" 2>/dev/null | cut -c1-240 || true)"
    fi
    if [[ -n "${msg// /}" ]]; then
      printf 'нет соединения: %s' "$msg"
    else
      printf 'нет соединения с панелью (проверьте домен, DNS/TLS и доступность)'
    fi
    return 0
  fi
  if grep -qi '<html\|<!doctype' <<<"$body"; then
    printf 'панель вернула HTML вместо JSON (HTTP %s) — вероятно, Cloudflare/WAF или страница входа' "$code"
    return 0
  fi
  # Пробуем достать человекочитаемую ошибку (Remnawave 3.x: message + code)
  msg="$(jq -r '.message // .error // .errors[0].message // .errors[0] // empty' <<<"$body" 2>/dev/null)"
  api_code="$(jq -r 'if (.code|type)=="string" or (.code|type)=="number" then .code else empty end' <<<"$body" 2>/dev/null)"
  if [[ -n "$msg" && "$msg" != "null" ]]; then
    if [[ -n "$api_code" && "$api_code" != "null" ]]; then
      printf '%s (код %s, HTTP %s)' "$msg" "$api_code" "$code"
    else
      printf '%s (HTTP %s)' "$msg" "$code"
    fi
  elif [[ "$code" =~ ^2[0-9]{2}$ ]]; then
    printf 'ответ панели не похож на ожидаемый JSON (HTTP %s)' "$code"
  else
    printf 'неизвестная ошибка Panel API (HTTP %s)' "$code"
  fi
}

# Причина неудачной проверки — для понятной подсказки в мастере.
PANEL_CONN_REASON=""
PANEL_CONN_DETAIL=""
PANEL_CONN_CODE=""

panel_check_connection() {
  local resource resp code denied=""
  PANEL_CONN_REASON=""; PANEL_CONN_DETAIL=""; PANEL_CONN_CODE=""
  # Проверяем чтение всех разделов, которые нужны автонастройке: токен может
  # иметь право на профили/ноды/хосты, но не на subscription-templates
  # (в Remnawave 3.x право называется subscription-template:*), без которого не
  # создастся XRAY_JSON шаблон и в подписке не заработают скрытые хосты.
  for resource in config-profiles nodes hosts internal-squads subscription-templates; do
    resp="$(panel_api GET "/$resource")"
    code="$(panel_api_code)"
    if panel_api_success "$resp"; then continue; fi
    # HTML вместо JSON — это не API панели, а прокси/страница входа: права
    # токена тут ни при чём, поэтому 403/401 от Cloudflare не путаем с API.
    if grep -qi '<html\|<!doctype' <<<"$resp"; then
      PANEL_CONN_CODE="$code"
      PANEL_CONN_DETAIL="$(panel_api_error "$resp")"
      PANEL_CONN_REASON="not-json"
      return 1
    fi
    if [[ "$code" == "403" ]]; then
      denied+="${denied:+, }$resource"
      continue
    fi
    PANEL_CONN_CODE="$code"
    PANEL_CONN_DETAIL="$(panel_api_error "$resp")"
    case "$code" in
      000) PANEL_CONN_REASON="network" ;;
      401) PANEL_CONN_REASON="unauthorized" ;;
      404) PANEL_CONN_REASON="not-found" ;;
      5[0-9][0-9]) PANEL_CONN_REASON="server" ;;
      4[0-9][0-9]) PANEL_CONN_REASON="bad-request" ;;
      *)   PANEL_CONN_REASON="not-json" ;;
    esac
    return 1
  done
  if [[ -n "$denied" ]]; then
    PANEL_CONN_REASON="scope"
    PANEL_CONN_CODE="403"
    PANEL_CONN_DETAIL="нет доступа на чтение: $denied"
    return 1
  fi
  return 0
}

# Человеческое объяснение к PANEL_CONN_REASON: 401 — токен, 403 — права,
# 404 — адрес, 000 — сеть, 2xx без JSON — Cloudflare/страница входа.
panel_connection_hint() {
  local reason="${PANEL_CONN_REASON:-}" detail="${PANEL_CONN_DETAIL:-}"
  case "$reason" in
    network)
      detail="${detail#нет соединения: }"
      printf 'Нет соединения с %s: %s. Проверьте домен, DNS, сертификат и доступность панели с этого сервера.' \
        "${REMNAWAVE_PANEL_URL:-панелью}" "$detail" ;;
    unauthorized)
      printf 'Панель доступна, но токен отклонён (HTTP 401): %s. Создайте новый токен в Settings → API Tokens; SECRET_KEY ноды и пароль администратора не подходят.' "$detail" ;;
    scope)
      printf 'Панель доступна, но токену не хватает прав (HTTP 403): %s. Нужны чтение И запись для config-profiles, nodes, hosts, internal-squads, subscription-template (выдайте config-profiles:*, nodes:*, hosts:*, internal-squads:*, subscription-template:*, keygen:* или полный доступ *).' "$detail" ;;
    not-found)
      printf 'По адресу %s нет API панели (HTTP 404): %s. Укажите корень панели без пути: https://panel.example.com (порт — если он нестандартный).' "${REMNAWAVE_PANEL_URL:-?}" "$detail" ;;
    server)
      printf 'Панель ответила ошибкой сервера (HTTP %s): %s. Проверьте, что панель запущена, и её логи.' "${PANEL_CONN_CODE:-5xx}" "$detail" ;;
    not-json)
      printf 'Панель ответила HTTP %s, но это не JSON API: %s. Обычно так отвечает Cloudflare Access, страница входа или неверный домен.' "${PANEL_CONN_CODE:-?}" "$detail" ;;
    bad-request)
      printf 'Панель отклонила запрос (HTTP %s): %s.' "${PANEL_CONN_CODE:-?}" "$detail" ;;
    *)
      printf 'Проверка панели не удалась: %s' "$detail" ;;
  esac
}

# Повтор с бэкофом для сетевых сбоев панели (000/5xx/429)
panel_api_retry() {
  local tries=3 delay=5 n=1 resp code
  while :; do
    resp="$(panel_api "$@" || true)"
    code="$(panel_api_code)"
    if panel_api_success "$resp"; then
      printf '%s' "$resp"
      return 0
    fi
    # Не ретраим 4xx кроме 429
    if [[ "$code" =~ ^4[0-9]{2}$ && "$code" != "429" ]]; then
      printf '%s' "$resp"
      return 1
    fi
    if (( n >= tries )); then
      printf '%s' "$resp"
      return 1
    fi
    # Предупреждение — в stderr: тело ответа, которое вернёт функция, должно
    # оставаться чистым JSON, даже когда её вызывают через $(...).
    warn "Panel API $1 $2 → HTTP $code, повтор $n/$tries через ${delay}s" >&2
    sleep "$delay"
    n=$((n+1))
    delay=$((delay*2))
  done
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

# Один экземпляр установщика: параллельный запуск мог бы одновременно
# переписывать Caddyfile, .env и правила ufw.
mkdir -p /run/lock
exec 9>/run/lock/remnanode-setup.lock
flock -n 9 || die "Установщик уже запущен другим процессом (лок: /run/lock/remnanode-setup.lock)."

mkdir -p "$LOG_DIR"
# В логе — адреса и детали инфраструктуры, поэтому файл создаётся сразу с 0600:
# без umask tee создал бы его читаемым для всех (umask по умолчанию 022).
( umask 077; : > "$LOG_FILE" )
exec > >(tee -a "$LOG_FILE") 2>&1

on_err() {
  local ec=$? line=$1 cmd=$2
  printf '\n %s✖ НЕПРЕДВИДЕННЫЙ СБОЙ%s код=%s строка=%s\n   %s%s%s\n' \
    "$C_RED$C_B" "${C_RST:-}" "$ec" "$line" "${C_DIM:-}${C_GRY:-}" "$cmd" "${C_RST:-}" >&2
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
  if [[ -n "${CF_CURL_CFG:-}" && -f "$CF_CURL_CFG" ]]; then
    rm -f -- "$CF_CURL_CFG"
  fi
  if [[ -n "${PANEL_CURL_CFG:-}" && -f "$PANEL_CURL_CFG" ]]; then
    rm -f -- "$PANEL_CURL_CFG"
  fi
  if [[ -n "${PANEL_STATE_DIR:-}" && -d "$PANEL_STATE_DIR" ]]; then
    rm -rf -- "$PANEL_STATE_DIR"
  fi
  # При сбое сборка не доходит до штатной очистки: убираем тулчейн и кэши здесь,
  # чтобы неудачная попытка не оставляла сотни МБ на диске. Пакеты apt не трогаем.
  remove_build_leftovers >/dev/null 2>&1 || true
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

# Документированный минимум — Debian 11 / Ubuntu 20.04: на более старых
# установщик формально запустится, но пакеты и репозитории могут отказать —
# предупреждаем вместо молчаливого отказа на середине шага.
if [[ "${ID:-}" == debian ]] && dpkg --compare-versions "${VERSION_ID:-0}" lt 11 2>/dev/null; then
  warn "Debian ${VERSION_ID} ниже поддерживаемого минимума (11) — некоторые шаги могут отказать."
elif [[ "${ID:-}" == ubuntu ]] && dpkg --compare-versions "${VERSION_ID:-0}" lt 20.04 2>/dev/null; then
  warn "Ubuntu ${VERSION_ID} ниже поддерживаемого минимума (20.04) — некоторые шаги могут отказать."
fi

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

log "Устанавливаю базовые утилиты (curl, ca-certificates, dnsutils, jq, psmisc)"
retry 3 5 apt_get update -y || warn "apt-get update завершился с ошибкой — продолжаю с текущими списками."
# psmisc нужен для fuser в apt_wait: без него ожидание apt/dpkg lock не работает.
retry 3 5 apt_get install -y curl ca-certificates dnsutils jq psmisc \
  || warn "Не удалось установить базовые утилиты — некоторые проверки будут ограничены."

step 1 "Мастер установки — отвечаем на вопросы"

if [[ -f "$ENV_STORE" ]]; then
  if confirm "Найден $ENV_STORE. Загрузить сохранённые переменные?" "y"; then
    # ENV_STORE — намеренно настраиваемый путь.
    # shellcheck disable=SC1090
    if source "$ENV_STORE"; then
      ENV_STORE_LOADED=1
      ok "Переменные загружены из $ENV_STORE"
    else
      warn "Не удалось прочитать $ENV_STORE — продолжаю без него."
    fi
  fi
fi
# Нормализуем флаги из ENV_STORE (там y/n, логика ожидает 0/1). Повторный запуск
# без этого ломал (( CF_MODE )) и (( REMNAWAVE_AUTO_SETUP )).
CF_MODE="$(parse_bool "${CF_MODE:-0}" 0)"
QUICK_SETUP="$(parse_bool "${QUICK_SETUP:-n}" 0)"
REMNAWAVE_AUTO_SETUP="$(parse_bool "${REMNAWAVE_AUTO_SETUP:-n}" 0)"
ENABLE_XHTTP="$(parse_bool "${ENABLE_XHTTP:-y}" 0)"
ENABLE_CDN="$(parse_bool "${ENABLE_CDN:-n}" 0)"

# Короткое объяснение для новичка: что сейчас будет.
if has_tty; then
{
  printf '\n'
  printf ' %s%s Добро пожаловать в мастер установки! %s\n' "${C_B:-}${C_CYN:-}" "${C_RST:-}" ""
  printf ' %sБыстрый режим задаст всего 5 вопросов; расширенный — все настройки по блокам.%s\n' "${C_DIM:-}${C_GRY:-}" "${C_RST:-}"
  printf ' %sЕсли не знаете что ответить — жмите Enter для значения по умолчанию.%s\n' "${C_DIM:-}${C_GRY:-}" "${C_RST:-}"
  printf '\n'
} > /dev/tty 2>/dev/null || true
fi

# Цвета могут быть не определены в тестах — задаём пустые значения чтобы set -u не падал
: "${C_B:=}" "${C_CYN:=}" "${C_GRN:=}" "${C_RST:=}" "${C_DIM:=}" "${C_GRY:=}" "${C_MAG:=}" "${C_BLU:=}" "${C_YLW:=}" "${C_RED:=}" "${C_WHT:=}"
# SERVER_IP нужен для A-записей Cloudflare и для сверки DNS. Значение из env (в
# том числе из сохранённого env-файла) приоритетнее автодетекта: за NAT внешние
# сервисы могут быть недоступны, а README и текст ошибки обещают возможность
# задать адрес вручную. Приватный адрес для A-записей не годится — его заменяет
# автодетект с предупреждением.
if is_ipv4 "${SERVER_IP:-}"; then
  if is_private_ipv4 "$SERVER_IP"; then
    warn "SERVER_IP=$SERVER_IP выглядит приватным — для A-записей нужен публичный IPv4, определяю автоматически."
    SERVER_IP=""
  else
    ok "Публичный IPv4 (SERVER_IP из env): $SERVER_IP"
  fi
fi
if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP=""
  if have curl; then
    SERVER_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    [[ -n "$SERVER_IP" ]] || SERVER_IP="$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  if is_ipv4 "$SERVER_IP"; then
    ok "Публичный IPv4: $SERVER_IP"
    if is_private_ipv4 "$SERVER_IP"; then
      warn "Определённый адрес $SERVER_IP выглядит приватным — вероятно, сервер за NAT. Сравнение A-записей с ним будет непоказательным; сверяйте DNS вручную или продолжайте с --force-dns."
    fi
  else
    SERVER_IP=""
    warn "Не удалось определить IP (проверка DNS будет мягкой). Задайте SERVER_IP через env."
  fi
fi

# Выбор режима мастера. Приоритет: --quick/--advanced → env QUICK_SETUP →
# сохранённый env-файл → вопрос. В --non-interactive вопрос не задаётся:
# быстрый режим включается только явно (QUICK_SETUP=y/--quick), чтобы
# существующие CI-запуски не меняли поведение молча.
if [[ -n "$QUICK_SETUP_SETTING" ]]; then
  QUICK_SETUP="$QUICK_SETUP_SETTING"
elif [[ "$NONINTERACTIVE" == 1 ]] || (( QUICK_SETUP_ENV_PRESENT )) \
    || { (( ENV_STORE_LOADED )) && grep -q '^export QUICK_SETUP=' "$ENV_STORE" 2>/dev/null; }; then
  : # QUICK_SETUP уже нормализован из env/сохранённых переменных (дефолт 0)
else
  SETUP_MODE="quick"
  ask_choice SETUP_MODE "Режим установки" "1" \
    "quick: Быстрая автоустановка — всего 5 вопросов (домен, токены, панель), остальное автоматически (рекомендуется)" \
    "advanced: Расширенная настройка — все вопросы по блокам, полный ручной контроль"
  if [[ "$SETUP_MODE" == "quick" ]]; then QUICK_SETUP=1; else QUICK_SETUP=0; fi
fi
if (( QUICK_SETUP )); then
  [[ "$CF_MODE_SETTING" != "0" ]] \
    || die "Быстрый режим требует Cloudflare (поддомены и CDN создаются через API): уберите --no-cloudflare или запустите с --advanced."
  ok "Режим: быстрая автоустановка — спрошу только домен, токен Cloudflare, домен/IP/токен панели"
  note "Поддомены, CDN-домен, пути транспортов, тема фасада и порт ноды выберутся автоматически"
  note "(случайно, где это уместно) и сохранятся — повторный запуск их не изменит."
else
  log "Режим: расширенная настройка (все вопросы по блокам)"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# БЛОК 1/4: Домен и автоматическое создание поддоменов
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if (( QUICK_SETUP )); then
  if has_tty; then printf '\n %s%s━━━ Быстрая автоустановка: домен и Cloudflare ━━━%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" > /dev/tty 2>/dev/null || true; fi
else
  if has_tty; then printf '\n %s%s━━━ Блок 1/4: Домены и DNS ━━━%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" > /dev/tty 2>/dev/null || true; fi
fi
note "Базовый домен — ваш домен в Cloudflare. Пишите просто домен: без https://, без www и без слэшей."
note "На его основе создаются поддомены для протоколов."
ask BASE_DOMAIN "Базовый домен (напр. example.com)" "${BASE_DOMAIN:-}"
# Люди вставляют домен и как https://Example.COM/ — приводим к чистому виду.
# В автоустановке опечатка не должна обрывать мастер: просим ввести домен снова.
while :; do
  BASE_DOMAIN="$(normalize_domain_input "$BASE_DOMAIN")"
  if is_fqdn "$BASE_DOMAIN"; then break; fi
  if [[ "${QUICK_SETUP:-0}" == 1 && "$NONINTERACTIVE" != 1 ]] && has_tty; then
    warn "Некорректный домен: «$BASE_DOMAIN» — нужен вид example.com (без https://, www и путей)."
    ask BASE_DOMAIN "Введите базовый домен ещё раз" ""
  else
    die "Некорректный домен: «$BASE_DOMAIN» — нужен вид example.com (без https://, www и путей)."
  fi
done

# Явный вопрос про авто-создание доменов — понятно обычному пользователю.
# Если флаг --cloudflare/--no-cloudflare уже задан — не спрашиваем, используем его.
# В быстром режиме вопрос не нужен: Cloudflare обязателен (проверено выше).
if (( QUICK_SETUP )); then
  CF_MODE=1
  note "Поддомены ноды создаст Cloudflare API автоматически (случайные непохожие имена)."
elif [[ -z "$CF_MODE_SETTING" ]]; then
  note "Поддомены можно создать автоматически через Cloudflare API (рекомендуется для новичков)"
  note "или вручную — тогда нужно заранее создать A-записи на IP ноды ($SERVER_IP)."
  ask_bool CF_MODE "Создавать поддомены автоматически через Cloudflare?" "${CF_MODE:-n}"
else
  # Флаг уже определил CF_MODE выше — сохраняем его как выбор пользователя.
  CF_MODE="$CF_MODE_SETTING"
fi

if (( CF_MODE )); then
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    note "Токен Cloudflare с правами Zone:Read и Zone:DNS:Edit создаётся в панели Cloudflare → API Tokens."
    ask_secret CLOUDFLARE_API_TOKEN \
      "Cloudflare API Token (для авто-создания A-записей)" ""
  fi
  if [[ "${QUICK_SETUP:-0}" == 1 && "$NONINTERACTIVE" != 1 ]] && has_tty; then
    while :; do
      if cf_check_token_zone; then break; else __cf_check_rc=$?; fi
      if (( __cf_check_rc == 2 )); then
        warn "Токен принят, но зона ${CLOUDFLARE_ZONE:-$BASE_DOMAIN} не найдена. Проверьте домен/зону и права токена."
        ask BASE_DOMAIN "Введите базовый домен ещё раз" "$BASE_DOMAIN"
        BASE_DOMAIN="$(normalize_domain_input "$BASE_DOMAIN")"
        while ! is_fqdn "$BASE_DOMAIN"; do
          warn "Некорректный домен — нужен вид example.com."
          ask BASE_DOMAIN "Введите базовый домен ещё раз" ""
          BASE_DOMAIN="$(normalize_domain_input "$BASE_DOMAIN")"
        done
        continue
      else
        warn "Cloudflare не принял токен или проверка API не удалась. Проверьте токен и права Zone:Read + Zone:DNS:Edit."
        ask_secret CLOUDFLARE_API_TOKEN "Введите токен Cloudflare ещё раз (скрытый ввод)" ""
      fi
    done
  fi
  log "Режим Cloudflare: поддомены создаст API (случайные непохожие имена вида quiet-otter.example.com)"
  cf_setup_hosts
else
  if cf_valid_saved_host "${VLESS_HOST:-}" "$BASE_DOMAIN" \
      && cf_valid_saved_host "${HY_HOST:-}" "$BASE_DOMAIN"; then
    ok "Хосты из сохранённых переменных: $VLESS_HOST / $HY_HOST"
  else
    note "Ручной режим: поддомены создаются вами вручную. Формат по умолчанию — prefix + номер."
    ask PREFIX "Префикс поддомена (напр. usa, eu, sg)" "${PREFIX:-usa}"
    VLESS_HOST="${PREFIX}1.${BASE_DOMAIN}"
    HY_HOST="${PREFIX}3.${BASE_DOMAIN}"
    note "Будут использованы: VLESS=$VLESS_HOST, Hysteria2=$HY_HOST"
    note "Убедитесь, что A-записи этих доменов указывают на $SERVER_IP и без прокси (серое облако)."
  fi
fi
ok "Домены ноды: $VLESS_HOST / $HY_HOST"

ACME_EMAIL="admin@${BASE_DOMAIN}"
ok "Email для Let's Encrypt: $ACME_EMAIL"

if (( QUICK_SETUP )); then
  SELF_STEAL_HOST="${SELF_STEAL_HOST:-$VLESS_HOST}"
  note "Self-steal домен для Vision/Reality: $SELF_STEAL_HOST (авто)"
else
  ask SELF_STEAL_HOST "Домен self-steal для Vision/Reality (обычно = VLESS домен)" "${SELF_STEAL_HOST:-$VLESS_HOST}"
fi
VISION_SNI="$SELF_STEAL_HOST"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# БЛОК 2/4: Шаблоны — маскировочный сайт и шаблон подписки
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if (( ! QUICK_SETUP )); then
  if has_tty; then printf '\n %s%s━━━ Блок 2/4: Шаблоны — маскировка и подписка ━━━%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" > /dev/tty 2>/dev/null || true; fi
  note "Маскировочный сайт показывается сканерам вместо заглушки — выберите тему, похожую на обычный веб-сайт."
  note "Шаблон подписки определяет, как клиенты получают настройки: весь трафик через VPN или только часть."
fi

# Выбор темы фасада — меню с описаниями (понятно обычному пользователю).
# В быстром режиме тема на свежей установке выбирается случайно (фасады нод
# не выглядят одинаково), на повторной — сохраняется прежняя из env-файла.
if [[ -z "${SELF_STEAL_TEMPLATE_URL:-}" ]]; then
  if (( QUICK_SETUP )); then
    if (( ! SELF_STEAL_TEMPLATE_EXPLICIT && ! ENV_STORE_LOADED )); then
      if __theme_idx="$(cf_rand_index "${#SELF_STEAL_TEMPLATES[@]}")"; then
        SELF_STEAL_TEMPLATE="${SELF_STEAL_TEMPLATES[$__theme_idx]}"
      fi
    fi
    note "Тема маскировочного сайта: $SELF_STEAL_TEMPLATE (авто)"
  else
  # Определяем дефолтный номер для меню: vaultdrop=1, mail=2, cloud=3, admin=4, docs=5
  __default_theme_num=1
  for __i in "${!SELF_STEAL_TEMPLATES[@]}"; do
    if [[ "${SELF_STEAL_TEMPLATES[$__i]}" == "$SELF_STEAL_TEMPLATE" ]]; then
      __default_theme_num=$((__i+1))
      break
    fi
  done
  ask_choice SELF_STEAL_TEMPLATE "Выберите тему маскировочного сайта" "$__default_theme_num" \
    "vaultdrop: Файлообменник — приватный обмен файлами (рекомендуется)" \
    "mail: Почта — корпоративный почтовый портал" \
    "cloud: Облако — файловое облако с папками" \
    "admin: Админ-панель — панель управления сервером" \
    "docs: Документация — сайт с документацией"
  note "Выбрана тема: $SELF_STEAL_TEMPLATE"
  fi
else
  ok "Используется кастомный фасад: $SELF_STEAL_TEMPLATE_URL"
fi

# Выбор шаблона подписки — full vs split (предлагаем и в быстром, и в расширенном режиме;
# в --non-interactive ask_choice сам выбирает дефолт без ожидания ввода).
__default_tpl_num=1
if [[ "${XRAY_TEMPLATE_CHOICE,,}" == "split" ]]; then __default_tpl_num=2; fi
ask_choice XRAY_TEMPLATE_CHOICE "Выберите шаблон подписки для клиентов" "$__default_tpl_num" \
  "standard: Весь трафик через VPN (рекомендуется для обхода блокировок)" \
  "split: Только часть сайтов/сервисов через VPN, остальное напрямую (split-routing)"
# Нормализуем к стандартным значениям
case "${XRAY_TEMPLATE_CHOICE,,}" in
  split|2) XRAY_TEMPLATE_CHOICE="split" ;;
  *)       XRAY_TEMPLATE_CHOICE="standard" ;;
esac
if [[ "$XRAY_TEMPLATE_CHOICE" == "split" ]]; then
  note "Шаблон подписки: split-routing — только часть доменов через VPN"
else
  note "Шаблон подписки: standard — весь трафик через VPN (full-tunnel)"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# БЛОК 3/4: Протоколы
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if (( ! QUICK_SETUP )); then
  if has_tty; then printf '\n %s%s━━━ Блок 3/4: Протоколы ━━━%s\n' "${C_B:-}" "${C_CYN:-}" "${C_RST:-}" > /dev/tty 2>/dev/null || true; fi
  note "VLESS Reality/Vision и Hysteria2 включены всегда. Дополнительно можно включить:"
  note "  • XHTTP — современный транспорт, лучше работает в некоторых сетях"
  note "  • VLESS за CDN — прячет IP ноды за Cloudflare/аналогами (требует отдельный домен)"
fi
: "${C_B:=}" "${C_CYN:=}" "${C_RST:=}" "${C_DIM:=}" "${C_GRY:=}" "${C_MAG:=}"
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
    CDN_TRANSPORT="${CDN_TRANSPORT:-ws}"
    note "CDN: включён автоматически (домен $CDN_HOST, транспорт ${CDN_TRANSPORT,,})"
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

# Авто-настройка панели спрашивается до IP/порта: по домену панели IP для
# firewall чаще всего определяется сам, а порт в быстром режиме — случайный.
if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
  REMNAWAVE_AUTO_SETUP=1
else
  note "Панель можно настроить автоматически (создать Config Profile, ноду, хосты) через API,"
  note "или вручную — через веб-интерфейс панели (инструкция в README, шаги 1–8)."
  ask_bool REMNAWAVE_AUTO_SETUP "Настроить панель автоматически через Remnawave API?" "${REMNAWAVE_AUTO_SETUP:-n}"
fi
if (( REMNAWAVE_AUTO_SETUP )); then
  note "Домен панели пишите полным URL — с https:// в начале. Слэш в конце можно:"
  note "https://panel.example.com/ установщик сам приведёт к https://panel.example.com."
  note "Путь в конце не нужен: panel.example.com/login — ошибка. Без схемы тоже можно —"
  note "https:// добавится автоматически."
  note "API-токен создаётся в панели: Settings → API Tokens. Нужны права на ЧТЕНИЕ и запись:"
  note "config-profiles, nodes, hosts, internal-squads, subscription-template, keygen"
  note "(проще всего выдать полный доступ * или config-profiles:*, nodes:*, hosts:*, internal-squads:*, subscription-template:*, keygen:*)."
  ask REMNAWAVE_PANEL_URL "Домен панели (URL, напр. https://panel.example.com)" "${REMNAWAVE_PANEL_URL:-}"
  while :; do
    __normalized_panel_url="$(normalize_panel_url "$REMNAWAVE_PANEL_URL")" || __normalized_panel_url=""
    if [[ -n "$__normalized_panel_url" ]]; then
      REMNAWAVE_PANEL_URL="$__normalized_panel_url"
      break
    fi
    if [[ "${QUICK_SETUP:-0}" == 1 && "$NONINTERACTIVE" != 1 ]] && has_tty; then
      warn "Некорректный URL панели — нужен адрес вида https://panel.example.com без пути."
      ask REMNAWAVE_PANEL_URL "Введите домен панели ещё раз" ""
    else
      die "Некорректный домен панели «$REMNAWAVE_PANEL_URL»: нужен URL вида https://panel.example.com (https:// можно не писать — добавится сам; слэш в конце допустим, а путь — нет)."
    fi
  done
  ok "URL панели: $REMNAWAVE_PANEL_URL"
  if [[ -z "${REMNAWAVE_API_TOKEN:-}" ]]; then
    ask_secret REMNAWAVE_API_TOKEN "API токен панели Remnawave (скрытый ввод)" ""
  fi
  note "Проверка соединения с панелью..."
  panel_curl_cfg_init
  if panel_check_connection; then
    ok "Панель доступна и токен валиден — профиль, нода, шаблон XRAY и хосты будут созданы на шаге 9"
    if [[ -z "${SECRET_KEY:-}" ]] && ! panel_fetch_node_secret >/dev/null 2>&1; then
      warn "Токену не выдано право keygen (GET /keygen → HTTP $(panel_api_code)): профиль, нода, шаблон и хосты создадутся сами, но для авто-получения SECRET_KEY добавьте keygen:* в Settings → API Tokens."
    fi
  elif [[ "$NONINTERACTIVE" != 1 ]] && has_tty; then
    while :; do
      warn "Не удалось проверить панель:"
      note "$(panel_connection_hint)"
      if [[ "${QUICK_SETUP:-0}" != 1 ]]; then
        if ! confirm "Ввести URL/API-токен панели заново? (n — прервать/пропустить)" "y"; then
          if ! confirm "Продолжить установку несмотря на ошибку соединения?" "n"; then
            die "Отменено: исправьте URL/токен панели."
          fi
          break
        fi
      fi
      [[ -n "${PANEL_CURL_CFG:-}" ]] && rm -f "$PANEL_CURL_CFG"
      PANEL_CURL_CFG=""
      ask REMNAWAVE_PANEL_URL "Введите домен панели ещё раз" "$REMNAWAVE_PANEL_URL"
      while :; do
        __normalized_panel_url="$(normalize_panel_url "$REMNAWAVE_PANEL_URL")" || __normalized_panel_url=""
        [[ -n "$__normalized_panel_url" ]] && { REMNAWAVE_PANEL_URL="$__normalized_panel_url"; break; }
        warn "Некорректный URL панели — нужен адрес вида https://panel.example.com без пути."
        ask REMNAWAVE_PANEL_URL "Введите домен панели ещё раз" ""
      done
      ask_secret REMNAWAVE_API_TOKEN "Введите API токен панели ещё раз (скрытый ввод)" ""
      panel_curl_cfg_init
      if panel_check_connection; then
        ok "Панель доступна и токен валиден — профиль, нода, шаблон XRAY и хосты будут созданы на шаге 9"
        if [[ -z "${SECRET_KEY:-}" ]] && ! panel_fetch_node_secret >/dev/null 2>&1; then
          warn "Токену не выдано право keygen (GET /keygen → HTTP $(panel_api_code)): профиль, нода, шаблон и хосты создадутся сами, но для авто-получения SECRET_KEY добавьте keygen:* в Settings → API Tokens."
        fi
        break
      fi
    done
  else
    warn "Не удалось проверить панель — авто-настройка может не сработать."
    note "$(panel_connection_hint)"
    if ! confirm "Продолжить установку несмотря на ошибку соединения?" "n"; then
      die "Отменено: исправьте URL/токен панели."
    fi
  fi
  # Не удаляем PANEL_CURL_CFG сейчас — он понадобится на шаге 9/10 для авто-настройки.
else
  note "Ручной режим: после установки создайте Config Profile, ноду и хосты вручную (README шаги 1–8)."
  if [[ -n "${PANEL_CURL_CFG:-}" && -f "$PANEL_CURL_CFG" ]]; then
    rm -f "$PANEL_CURL_CFG"; PANEL_CURL_CFG=""
  fi
fi

# IP панели нужен только firewall'у (порт ноды открывается лишь с него).
# Если адрес не задан, пробуем получить его из домена панели — пользователю
# останется нажать Enter. Подвох: панель за Cloudflare-прокси резолвится в IP
# Cloudflare, а не сервера, — об этом предупреждаем прямо в вопросе.
__panel_ip_default="${PANEL_IP:-}"
if [[ -z "$__panel_ip_default" && -n "${REMNAWAVE_PANEL_URL:-}" ]]; then
  __panel_host="$(panel_url_host "$REMNAWAVE_PANEL_URL")"
  if is_ipv4 "$__panel_host" || is_ipv6 "$__panel_host"; then
    __panel_ip_default="$__panel_host"
    note "IP панели взят из её URL: $__panel_ip_default"
  elif __resolved_panel_ip="$(resolve_ipv4_host "$__panel_host")"; then
    __panel_ip_default="$__resolved_panel_ip"
    note "IP панели определён по домену $__panel_host: $__panel_ip_default (Enter — оставить)"
    note "Если панель за Cloudflare-прокси, это IP Cloudflare — вместо него введите реальный IP сервера панели."
  fi
fi
ask PANEL_IP "IP сервера панели Remnawave (IPv4 или IPv6, для firewall)" "$__panel_ip_default"

# Порт Node API: в быстром режиме случайный (и сохраняется), в расширенном —
# прежний вопрос с дефолтом 2222.
if [[ "${QUICK_SETUP:-0}" == 1 ]]; then
  if [[ -z "${NODE_API_PORT:-}" ]]; then
    NODE_API_PORT="$(random_node_port)" \
      || die "Не удалось сгенерировать случайный порт ноды — задайте NODE_API_PORT через env."
  fi
  ok "Порт ноды: $NODE_API_PORT (авто) — укажите его при создании ноды в панели; он есть в сводке ниже"
else
  ask NODE_API_PORT "Порт ноды для связи с панелью (обычно 2222)" "${NODE_API_PORT:-2222}"
fi

is_fqdn "$BASE_DOMAIN"       || die "Некорректный домен: $BASE_DOMAIN"
[[ "$PREFIX" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ && ${#PREFIX} -le 50 ]] \
  || die "Некорректный префикс: $PREFIX"
is_fqdn "$SELF_STEAL_HOST"   || die "Некорректный self-steal домен: $SELF_STEAL_HOST"
if (( ENABLE_XHTTP )); then
  is_fqdn "$XHTTP_SNI"             || die "Некорректный XHTTP SNI: $XHTTP_SNI"
  is_safe_xhttp_path "$XHTTP_PATH" || die "Некорректный XHTTP path: $XHTTP_PATH"
fi
{ is_ipv4 "$PANEL_IP" || is_ipv6 "$PANEL_IP"; } \
  || die "Некорректный IP панели: $PANEL_IP (нужен IPv4 или IPv6)"
{ [[ "$NODE_API_PORT" =~ ^[0-9]+$ ]] && (( NODE_API_PORT >= 1 && NODE_API_PORT <= 65535 )); } \
  || die "Некорректный порт ноды: $NODE_API_PORT"
# Порты, занятые самой схемой: 80 и 443 — Caddy, 9443 — локальный сайт
# self-steal, 10443/10444 — Vision и XHTTP в Xray. CDN-порты (сайт CDN-хоста и
# его инбаунды) берём из констант, чтобы список не разъезжался с ними: иначе
# Node API занял бы порт CDN-сайта или инбаунда и нода молча не поднялась бы.
case "$NODE_API_PORT" in
  80|443|9443|10443|10444|"$CDN_TLS_PORT"|"$CDN_WS_PORT"|"$CDN_XHTTP_PORT"|"$CDN_GRPC_PORT")
    die "Node API port $NODE_API_PORT занят этой схемой; выберите другой, например 2222."
    ;;
esac
ACTIVE_SSH_PORT="${SSH_PORT_OVERRIDE:-$(detect_ssh_port)}"
[[ "$NODE_API_PORT" != "$ACTIVE_SSH_PORT" ]] \
  || die "Node API port $NODE_API_PORT совпадает с SSH-портом; выберите другой порт ноды."
if [[ -n "$SERVER_IP" && "$PANEL_IP" == "$SERVER_IP" ]]; then
  warn "PANEL_IP ($PANEL_IP) совпадает с адресом самого сервера: так бывает, если панель работает на той же машине. Убедитесь, что это именно то, что нужно."
fi
[[ "$SELF_STEAL_HOST" != "$HY_HOST" ]] \
  || die "SELF_STEAL_HOST должен отличаться от доменов Hysteria2."
if (( ENABLE_XHTTP )); then
  [[ "$XHTTP_SNI" != "$SELF_STEAL_HOST" && "$XHTTP_SNI" != "$HY_HOST" ]] \
    || die "XHTTP_SNI конфликтует с SNI другого маршрута Caddy."
fi
if (( ENABLE_CDN )); then
  is_fqdn "$CDN_HOST" || die "Некорректный CDN-домен: $CDN_HOST"
  [[ "$CDN_HOST" != "$SELF_STEAL_HOST" && "$CDN_HOST" != "$HY_HOST" && \
     "$CDN_HOST" != "${XHTTP_SNI:-}" && "$CDN_HOST" != "$VLESS_HOST" ]] \
    || die "CDN-домен $CDN_HOST совпадает с SNI другого маршрута Caddy — нужен отдельный поддомен."
  if (( CDN_WS_ENABLED )); then
    is_safe_xhttp_path "$CDN_WS_PATH" || die "Некорректный путь WebSocket для CDN: $CDN_WS_PATH"
  fi
  if (( CDN_XHTTP_ENABLED )); then
    is_safe_xhttp_path "$CDN_XHTTP_PATH" || die "Некорректный путь XHTTP для CDN: $CDN_XHTTP_PATH"
  fi
  if (( CDN_GRPC_ENABLED )); then
    # serviceName обязан начинаться со слэша: Caddy выделяет его префиксом пути,
    # а Xray сам разбирает остаток (/<serviceName>/Tun).
    is_safe_xhttp_path "$CDN_GRPC_PATH" \
      || die "Некорректный serviceName gRPC для CDN: $CDN_GRPC_PATH (нужен путь, начинающийся со слэша)."
  fi
  # Пути (у gRPC — serviceName) обязаны различаться: иначе один маршрут Caddy
  # перекроет другой и транспорт перестанет работать.
  if (( CDN_WS_ENABLED && CDN_XHTTP_ENABLED )) && [[ "$CDN_WS_PATH" == "$CDN_XHTTP_PATH" ]]; then
    die "Пути WebSocket и XHTTP для CDN должны различаться."
  fi
  if (( CDN_WS_ENABLED && CDN_GRPC_ENABLED )) && [[ "$CDN_WS_PATH" == "$CDN_GRPC_PATH" ]]; then
    die "Путь WebSocket и serviceName gRPC для CDN должны различаться."
  fi
  if (( CDN_XHTTP_ENABLED && CDN_GRPC_ENABLED )) && [[ "$CDN_XHTTP_PATH" == "$CDN_GRPC_PATH" ]]; then
    die "Путь XHTTP и serviceName gRPC для CDN должны различаться."
  fi
fi
# Тема фасада → URL шаблона. Явный SELF_STEAL_TEMPLATE_URL имеет приоритет
# и отключает подстановку по теме (иначе пользователь не мог бы задать свой
# фасад, не переименовывая тему).
if [[ -z "$SELF_STEAL_TEMPLATE_URL" ]]; then
  SELF_STEAL_TEMPLATE_URL="$(self_steal_template_url "$SELF_STEAL_TEMPLATE")" \
    || die "Неизвестная тема self-steal: $SELF_STEAL_TEMPLATE. Доступны: $(self_steal_template_list | tr '\n' ' ')."
  SELF_STEAL_THEME_USED=1
fi
[[ "$SELF_STEAL_TEMPLATE_URL" == https://* ]] \
  || die "SELF_STEAL_TEMPLATE_URL должен начинаться с https://"
NODE_IMAGE="$(normalize_node_image "${NODE_IMAGE:-}")"
[[ "$NODE_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*(:[0-9]+)?/[a-zA-Z0-9._/-]+(:[a-zA-Z0-9._-]+)?(@sha256:[0-9a-fA-F]{64})?$ ]] \
  || die "Некорректная ссылка на образ: $NODE_IMAGE"
[[ "$XCADDY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Некорректная версия xcaddy: $XCADDY_VERSION"
[[ "$CADDY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Некорректная версия Caddy: $CADDY_VERSION"
[[ "$CADDY_L4_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Некорректная версия caddy-l4: $CADDY_L4_VERSION"

export SERVER_IP BASE_DOMAIN PREFIX VLESS_HOST HY_HOST ACME_EMAIL \
       SELF_STEAL_HOST VISION_SNI PANEL_IP NODE_API_PORT
if (( ENABLE_XHTTP )); then
  export XHTTP_SNI XHTTP_PATH
fi
if (( ENABLE_CDN )); then
  export ENABLE_CDN CDN_HOST CDN_TRANSPORT CDN_WS_PATH CDN_XHTTP_PATH CDN_GRPC_PATH
fi
export XRAY_TEMPLATE_CHOICE SELF_STEAL_TEMPLATE SELF_STEAL_TEMPLATE_URL
export REMNAWAVE_PANEL_URL REMNAWAVE_API_TOKEN REMNAWAVE_AUTO_SETUP
export CF_MODE CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE QUICK_SETUP

# Запись CDN-хоста создаётся проксируемой: именно оранжевое облако направляет
# трафик через CDN на origin. Это делается при каждом включённом CDN, а не
# только в режиме авто-ДНС (CF_MODE): блок 1 мог быть ручным (usa1/usa3
# созданы руками), а токен для CDN введён позже, в блоке 3, — запись всё
# равно обязана появиться. cf_setup_cdn_host сама убирает временный конфиг
# curl (и on_exit — если установка прервётся раньше); страховочная уборка ниже.
if (( ENABLE_CDN )); then
  cf_setup_cdn_host
fi
if [[ -n "$CF_CURL_CFG" ]]; then
  rm -f "$CF_CURL_CFG"
  CF_CURL_CFG=""
fi

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
# -F: путь ищется фиксированной строкой, а не как regex (точки в пути не
# должны совпадать с любым символом); %q корректно кавычивает записываемую строку.
grep -qF "source $ENV_STORE" /root/.bashrc 2>/dev/null \
  || printf '[ -f %q ] && source %q\n' "$ENV_STORE" "$ENV_STORE" >> /root/.bashrc
ok "Переменные сохранены в $ENV_STORE (0600, подхват в .bashrc)"
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" || -n "${REMNAWAVE_API_TOKEN:-}" ]]; then
  note "Токены сохранены в $ENV_STORE (0600) — ограничьте доступ к файлу и ротируйте при утечке; в логе токены не пишутся."
fi
write_config_profile
write_xray_template

echo
hr
kv "SERVER_IP"     "$SERVER_IP"
kv "VLESS"         "$VLESS_HOST"
kv "HYSTERIA2"     "$HY_HOST"
kv "SELF_STEAL"    "$SELF_STEAL_HOST -> 127.0.0.1:9443"
if (( SELF_STEAL_THEME_USED )); then
  kv "Фасад"         "тема $SELF_STEAL_TEMPLATE"
else
  kv "Фасад"         "$SELF_STEAL_TEMPLATE_URL"
fi
if (( ENABLE_XHTTP )); then
  kv "XHTTP_SNI"     "$XHTTP_SNI"
  kv "XHTTP_PATH"    "$XHTTP_PATH"
else
  kv "XHTTP"         "(отключено — профиль без inbound'а XHTTP)"
fi
if (( ENABLE_CDN )); then
  kv "CDN"           "$CDN_HOST (транспорт: $CDN_TRANSPORT)"
  if [[ "$CDN_DNS_MANAGED" == "cloudflare" ]]; then
    kv "CDN DNS"       "Cloudflare: проксируемая A-запись $CDN_HOST создана (proxied=on)"
  else
    kv "CDN DNS"       "ВРУЧНУЮ: создайте проксируемую A-запись $CDN_HOST → $SERVER_IP (оранжевое облако)"
  fi
fi
kv "Config Profile" "$NODE_DIR/Multiselect.json"
kv "Шаблон подписки" "$XRAY_TEMPLATE_CHOICE ($NODE_DIR/Xray_template.json)"
kv "PANEL_IP"      "$PANEL_IP"
kv "NODE_API_PORT" "$NODE_API_PORT"
if (( QUICK_SETUP )); then
  kv "Режим"           "быстрая автоустановка (пути, порт и тема выбраны автоматически)"
else
  kv "Режим"           "расширенная настройка"
fi
if (( CF_MODE )); then
  kv "DNS"            "Cloudflare: A-записи VLESS/Hysteria2 созданы API (DNS only, proxied=off)"
fi
if (( REMNAWAVE_AUTO_SETUP )); then
  kv "Авто-панель"     "$REMNAWAVE_PANEL_URL (API)"
else
  kv "Авто-панель"     "выключена — ручная настройка по README"
fi
hr
echo
confirm "Всё верно, продолжаем?" "y" || die "Отменено пользователем."

step 2 "Проверка DNS и SNI"
DNS_OK=1
declare -A DNS_SEEN=()
if ! have dig; then
  # Раньше отсутствие dig выглядело как «нет A-записи» и путало пользователя
  # ложным предупреждением — теперь о пропуске сообщается явно.
  warn "dig не установлен — проверка A/AAAA-записей пропущена; при неверном DNS сам выпуск сертификата acme.sh упадёт с понятной ошибкой."
else
  for d in "$VLESS_HOST" "$HY_HOST" "$SELF_STEAL_HOST"; do
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
fi
if [[ "$DNS_OK" -eq 0 && "$FORCE_DNS" -eq 0 ]]; then
  confirm "DNS не совпадает — сертификаты могут не выпуститься. Продолжить?" "n" \
    || die "Прервано из-за DNS. Поправьте A-записи или запустите с --force-dns."
fi
if (( ENABLE_XHTTP )); then
  proto="$(echo | timeout 8 openssl s_client -connect "$XHTTP_SNI:443" -servername "$XHTTP_SNI" -alpn h2 -tls1_3 -brief 2>&1 \
           | grep -Ei 'Protocol|ALPN' | tr '\n' ' ' || true)"
  if [[ -n "$proto" ]]; then
    ok "SNI $XHTTP_SNI: $proto"
  else
    warn "SNI $XHTTP_SNI: не удалось проверить TLS1.3/h2"
  fi
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
  ufw allow 443/tcp           comment 'VLESS via Caddy L4'  >/dev/null
  ufw allow 443/udp           comment 'Hysteria2 QUIC'             >/dev/null
  ufw allow 80/tcp            comment 'acme.sh standalone'         >/dev/null
  if is_ipv6 "$PANEL_IP" && [[ -f /etc/default/ufw ]] \
      && grep -qE '^[[:space:]]*IPV6=no' /etc/default/ufw; then
    warn "Панель задана IPv6-адресом, а в /etc/default/ufw стоит IPV6=no: правило не сработает. Поставьте IPV6=yes и выполните ufw reload."
  fi
  ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp comment 'Remnawave panel -> node' >/dev/null
  ufw --force enable >/dev/null || die "Не удалось включить ufw."
  # Проверяем и активные правила, и список добавленных: правило должно связывать панель с портом ноды.
  if ufw status 2>/dev/null | grep -F "$NODE_API_PORT" | grep -Fq "$PANEL_IP" \
      || ufw show added 2>/dev/null | grep -F "port $NODE_API_PORT " | grep -Fq "$PANEL_IP"; then
    ok "Правило «панель $PANEL_IP → Node API $NODE_API_PORT» есть в ufw"
  else
    ufw status numbered 2>/dev/null | sed 's/^/   /' || true
    die "В ufw нет правила для $PANEL_IP: Node API остался бы открытым. Проверьте IP панели."
  fi
  ok "ufw включён. API-порт $NODE_API_PORT доступен только с $PANEL_IP."
  ufw status numbered | sed 's/^/   /' || true
else
  step 4 "Firewall (пропущен)"
  warn "--no-firewall: убедитесь, что 443 tcp/udp, 80/tcp открыты, а $NODE_API_PORT доступен только панели. Без firewall нет гарантий ограничения доступа Node API."
fi

caddy_build_matches() {
  have caddy \
    && [[ "$(caddy version 2>/dev/null | awk '{print $1}')" == "$CADDY_VERSION" ]] \
    && caddy list-modules 2>/dev/null | grep -qE 'layer4' \
    && caddy build-info 2>/dev/null | tr '\t' ' ' \
      | grep -Fq "github.com/mholt/caddy-l4 $CADDY_L4_VERSION"
}

# Ранний fail-fast: если 443/tcp уже держит посторонний процесс (nginx,
# apache…), Caddy не сможет занять порт — об этом лучше сказать до
# многоминутной сборки, а не после неё.
assert_port443_free() {
  local line holder
  have ss || return 0
  line="$(ss -H -lntp 'sport = :443' 2>/dev/null | grep -vi caddy | head -1 || true)"
  [[ -n "$line" ]] || return 0
  holder="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line")"
  holder="${holder:-неизвестный процесс}"
  die "Порт 443/tcp занят процессом «$holder»: остановите его (systemctl stop <сервис>), иначе Caddy не сможет слушать 443."
}

step 5 "Сборка Caddy с модулем layer4"
assert_port443_free
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
  if ! pkg_installed build-essential; then
    BUILD_ESSENTIAL_ADDED=1
  fi
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
  # Caddy уже в /usr/bin/caddy, поэтому инструменты сборки больше не нужны.
  # Сборка кэширует гигабайты объектов в ~/.cache/go-build, а модули — в GOMODCACHE;
  # на малых VPS это лишнее место, поэтому удаляем всё после успешной установки.
  if [[ "$KEEP_BUILD_TOOLS" == 1 ]]; then
    note "Инструменты сборки оставлены (--keep-build-tools / KEEP_BUILD_TOOLS=1)"
  else
    remove_build_leftovers
    remove_build_packages
  fi
  systemctl enable caddy >/dev/null 2>&1 || true
  L4_COUNT="$(caddy list-modules 2>/dev/null | grep -c layer4 || true)"
  ok "Кастомный Caddy $CADDY_VERSION собран (${L4_COUNT:-0} L4-модулей)"
else
  ok "Caddy $CADDY_VERSION + caddy-l4 $CADDY_L4_VERSION уже установлены — сборку пропускаю"
fi
caddy version || true

step 6 "Сертификаты acme.sh (self-steal + Hysteria2)"
if ss -lntup 2>/dev/null | grep -q ':80 '; then
  port80_other="$(ss -lntup 2>/dev/null | grep ':80 ' | grep -v caddy || true)"
  if [[ -z "$port80_other" ]]; then
    note "Порт 80 слушает Caddy: на время ACME standalone challenge он будет остановлен."
  else
    warn "Порт 80 занят посторонним процессом — acme.sh standalone может не выпустить сертификаты:"
    printf '%s\n' "$port80_other" | sed 's/^/   /'
  fi
else
  note "Порт 80 свободен — challenge пройдёт без остановки Caddy."
fi
if [[ ! -x /root/.acme.sh/acme.sh ]]; then
  retry 3 10 bash -c "curl -fsSL https://get.acme.sh | sh -s email='$ACME_EMAIL'" \
    || die "Не удалось установить acme.sh."
fi
ACME=/root/.acme.sh/acme.sh
[[ -x "$ACME" ]] || die "acme.sh не найден по пути $ACME."
"$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
"$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || warn "Не удалось выставить CA по умолчанию."

# Автопродление работает из crontab root: если задания нет (crontab чистили
# или установка acme.sh оборвалась), сертификаты молча протухнут через ~90 дней.
# --install-cronjob идемпотентен — добавляет запись только при её отсутствии.
if crontab -l 2>/dev/null | grep -qF 'acme.sh --cron'; then
  ok "Задание автопродления acme.sh есть в crontab"
else
  warn "В crontab нет задания автопродления acme.sh — восстанавливаю."
  "$ACME" --install-cronjob >/dev/null 2>&1 || true
  if crontab -l 2>/dev/null | grep -qF 'acme.sh --cron'; then
    ok "Задание автопродления добавлено в crontab"
  else
    warn "Не удалось добавить задание автопродления: выполните вручную — $ACME --install-cronjob."
  fi
fi

# Caddy занимает :80 ради HTTP->HTTPS 301, поэтому standalone challenge требует
# временно остановить Caddy. Хуки сохраняются в конфиг сертификата acme.sh и
# срабатывают при автопродлении из cron (--renew/--cron) так же, как при первой выдаче.
ACME_PRE_HOOK='systemctl stop caddy >/dev/null 2>&1 || true'
ACME_POST_HOOK='systemctl start caddy >/dev/null 2>&1 || true'

# Сколько дней осталось у уже выпущенного сертификата acme.sh; возвращает 1,
# если файла нет или он нечитаем. Без этой проверки повторный запуск «пропускал»
# бы выпуск, и просроченный сертификат продолжал бы работать до ручного
# вмешательства. ACME_HOME переопределяется в tests/installer-funcs-checks.sh.
acme_cert_days_left() {
  local d="$1" home="${ACME_HOME:-/root/.acme.sh}" crt end end_epoch
  for crt in "$home/${d}_ecc/${d}.crt" "$home/${d}/${d}.crt"; do
    [[ -s "$crt" ]] || continue
    end="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2-)" || return 1
    [[ -n "$end" ]] || return 1
    end_epoch="$(LC_ALL=C date -d "$end" +%s 2>/dev/null)" || return 1
    printf '%s' $((( end_epoch - $(date +%s) ) / 86400 ))
    return 0
  done
  return 1
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

# Сертификат для CDN-хоста: HTTP-01 здесь невозможен — за прокси на :80 отвечает
# сам CDN, а не наша нода. Поэтому DNS-01 (`dns_cf`) тем же токеном Cloudflare.
# acme.sh сохраняет креденшелы DNS-API в конфиг сертификата, поэтому cron
# обновляет его так же, как остальные.
issue_cert_dns() {
  local d="$1" listed=0 days
  local -a issue_args=(--issue --dns dns_cf -d "$d" --keylength ec-256)
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] \
    || { warn "Для DNS-01 сертификата $d нужен CLOUDFLARE_API_TOKEN."; return 1; }
  if "$ACME" --list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$d"; then
    listed=1
  fi
  if (( listed )); then
    if days="$(acme_cert_days_left "$d")" && (( days > 7 )); then
      ok "Сертификат для $d уже выпущен (осталось ${days} дн.) — пропускаю issue"
      return 0
    fi
    warn "Сертификат для $d отсутствует, нечитаем или истекает — перевыпускаю через DNS-01."
    issue_args+=(--force)
  fi
  # dns_cf читает CF_Token; CF_Zone_ID избавляет от повторного поиска зоны.
  export CF_Token="$CLOUDFLARE_API_TOKEN"
  if [[ -n "${CF_ZONE_ID:-}" ]]; then export CF_Zone_ID="$CF_ZONE_ID"; fi
  if ! "$ACME" "${issue_args[@]}"; then
    warn "Не удалось выпустить сертификат для $d через DNS-01: проверьте права токена (Zone:Read + DNS:Edit) и CLOUDFLARE_ZONE."
    return 1
  fi
}

issue_cert "$SELF_STEAL_HOST" || die "Без сертификата $SELF_STEAL_HOST настоящий self-steal невозможен."
issue_cert "$HY_HOST" || die "Не удалось подготовить обязательный сертификат Hysteria2."
# Проверку через порт 80 для CDN-хоста не делаем вовсе: HTTP-01 за прокси
# невозможно, а DNS-01 портов не требует и Caddy не останавливает.
if (( ENABLE_CDN )); then
  issue_cert_dns "$CDN_HOST" \
    || die "CDN включён, но сертификат для $CDN_HOST не выпущен: без него CDN не сможет ходить на origin по Full (strict)."
fi

mkdir -p "$CERT_DIR/$SELF_STEAL_HOST" "$CERT_DIR/$HY_HOST"
"$ACME" --install-cert -d "$SELF_STEAL_HOST" --ecc \
  --key-file       "$CERT_DIR/$SELF_STEAL_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem" \
  --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || true" \
  || die "Не удалось установить сертификат self-steal для $SELF_STEAL_HOST."
"$ACME" --install-cert -d "$HY_HOST" --ecc \
  --key-file       "$CERT_DIR/$HY_HOST/key.pem" \
  --fullchain-file "$CERT_DIR/$HY_HOST/fullchain.pem" \
  --reloadcmd "docker restart remnanode >/dev/null 2>&1 || true" \
  || die "install-cert для $HY_HOST не удался."

if (( ENABLE_CDN )); then
  mkdir -p "$CERT_DIR/$CDN_HOST"
  "$ACME" --install-cert -d "$CDN_HOST" --ecc \
    --key-file       "$CERT_DIR/$CDN_HOST/key.pem" \
    --fullchain-file "$CERT_DIR/$CDN_HOST/fullchain.pem" \
    --reloadcmd "systemctl reload caddy >/dev/null 2>&1 || true" \
    || die "Не удалось установить сертификат CDN для $CDN_HOST."
fi

cert_files=(
  "$CERT_DIR/$SELF_STEAL_HOST/key.pem" "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem"
  "$CERT_DIR/$HY_HOST/key.pem" "$CERT_DIR/$HY_HOST/fullchain.pem"
)
if (( ENABLE_CDN )); then
  cert_files+=("$CERT_DIR/$CDN_HOST/key.pem" "$CERT_DIR/$CDN_HOST/fullchain.pem")
fi
for cert_file in "${cert_files[@]}"; do
  [[ -s "$cert_file" ]] || die "Сертификат или ключ отсутствует/пуст: $cert_file"
done

chown -R root:root "$CERT_DIR"
find "$CERT_DIR" -type d -exec chmod 755 {} \; || true
find "$CERT_DIR" -type f -name 'key.pem'       -exec chmod 600 {} \; || true
find "$CERT_DIR" -type f -name 'fullchain.pem' -exec chmod 644 {} \; || true
chown root:caddy "$CERT_DIR/$SELF_STEAL_HOST/key.pem" "$CERT_DIR/$SELF_STEAL_HOST/fullchain.pem"
chmod 640 "$CERT_DIR/$SELF_STEAL_HOST/key.pem"
if (( ENABLE_CDN )); then
  # Caddy читает ключ CDN-хоста, поэтому права той же схемы, что у self-steal.
  chown root:caddy "$CERT_DIR/$CDN_HOST/key.pem" "$CERT_DIR/$CDN_HOST/fullchain.pem"
  chmod 640 "$CERT_DIR/$CDN_HOST/key.pem"
fi
ok "Сертификаты установлены в $CERT_DIR (автопродление — таймер/cron acme.sh)"

step 7 "Caddyfile — SNI-роутинг и локальный self-steal сайт"
SELF_STEAL_ROOT=/var/www/remnanode-self-steal
mkdir -p "$SELF_STEAL_ROOT"
SELF_STEAL_TEMPLATE_TMP="$(mktemp)"
if retry 3 3 curl -fsSL "$SELF_STEAL_TEMPLATE_URL" -o "$SELF_STEAL_TEMPLATE_TMP"; then
  install -m 644 "$SELF_STEAL_TEMPLATE_TMP" "$SELF_STEAL_ROOT/index.html"
  if (( SELF_STEAL_THEME_USED )); then
    ok "Фасад self-steal установлен (тема $SELF_STEAL_TEMPLATE)"
  else
    ok "Фасад self-steal установлен (SELF_STEAL_TEMPLATE_URL)"
  fi
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
# Маршрут XHTTP вырезается целиком, когда XHTTP выключен: иначе Caddy уводил бы
# SNI XHTTP в 127.0.0.1:10444, где после отключения inbound'а никто не слушает.
XHTTP_L4_BLOCK=""
if (( ENABLE_XHTTP )); then
  XHTTP_L4_BLOCK="$(printf '      @xhttp tls sni %s\n      route @xhttp {\n        proxy 127.0.0.1:10444\n      }' "$XHTTP_SNI")"
fi
# SNI CDN-хоста уводим на отдельный TLS-сайт: именно с ним приходит CDN на :443.
CDN_L4_BLOCK=""
if (( ENABLE_CDN )); then
  CDN_L4_BLOCK="$(printf '      @cdn tls sni %s\n      route @cdn {\n        proxy 127.0.0.1:%s\n      }' "$CDN_HOST" "$CDN_TLS_PORT")"
fi
cat > /etc/caddy/Caddyfile <<EOF
{
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
        proxy 127.0.0.1:9443
      }
    }
  }
}

# Постоянный 301 на HTTPS с сохранением пути и query string.
# Домен берётся из конфигурации, а не из заголовка Host, поэтому open redirect невозможен.
http://$SELF_STEAL_HOST {
  redir https://$SELF_STEAL_HOST{uri} permanent
}

https://$SELF_STEAL_HOST:9443 {
  bind 127.0.0.1
  tls $CERT_DIR/$SELF_STEAL_HOST/fullchain.pem $CERT_DIR/$SELF_STEAL_HOST/key.pem {
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

if (( ENABLE_CDN )); then
  # Отдельный блок для CDN-хоста. Публичный TLS терминирует CDN, а к нам на :443
  # приходит уже его SNI — отсюда маршрут @cdn в layer4. Здесь мы терминируем
  # TLS сертификатом CDN-хоста и отдаём: пути инбаундов — в Xray (loopback),
  # всё остальное — тот же фасад, что и на self-steal сайте. Сторонний сканер
  # по CDN-хосту видит обычный веб-сайт. Xray при этом не смотрит наружу.
  CDN_ROUTES_BLOCK=""
  if (( CDN_WS_ENABLED )); then
    CDN_ROUTES_BLOCK+="$(printf '\n  @ws path %s*\n  reverse_proxy @ws 127.0.0.1:%s' "$CDN_WS_PATH" "$CDN_WS_PORT")"
  fi
  if (( CDN_XHTTP_ENABLED )); then
    CDN_ROUTES_BLOCK+="$(printf '\n  @xhttpcdn path %s*\n  reverse_proxy @xhttpcdn 127.0.0.1:%s' "$CDN_XHTTP_PATH" "$CDN_XHTTP_PORT")"
  fi
  if (( CDN_GRPC_ENABLED )); then
    # gRPC: Xray слушает h2c (HTTP/2 без TLS), поэтому upstream — h2c://...;
    # поток не буферизуем, иначе gRPC-стримы будут ждать закрытия ответа.
    CDN_ROUTES_BLOCK+="$(printf '\n  @grpccdn path %s/*\n  reverse_proxy @grpccdn h2c://127.0.0.1:%s {\n    flush_interval -1\n  }' "$CDN_GRPC_PATH" "$CDN_GRPC_PORT")"
  fi
  cat >> /etc/caddy/Caddyfile <<EOF

https://$CDN_HOST:$CDN_TLS_PORT {
  bind 127.0.0.1
  tls $CERT_DIR/$CDN_HOST/fullchain.pem $CERT_DIR/$CDN_HOST/key.pem {
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

caddy fmt --overwrite /etc/caddy/Caddyfile || warn "caddy fmt не удался — продолжаю."
caddy validate --config /etc/caddy/Caddyfile || die "Caddyfile невалиден — исправьте SNI/синтаксис."
systemctl restart caddy || die "Не удалось перезапустить Caddy."
sleep 1
if systemctl is-active --quiet caddy; then
  CADDY_RESTORE_NEEDED=0
  if (( ENABLE_XHTTP )); then
    ok "Caddy запущен: :443 L4 (Vision + XHTTP), HTTP->HTTPS 301, и локальный TLS-сайт 127.0.0.1:9443"
  else
    ok "Caddy запущен: :443 L4 (только Vision), HTTP->HTTPS 301, и локальный TLS-сайт 127.0.0.1:9443"
  fi
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

# 1) Авто-настройка панели ДО запроса SECRET_KEY и запуска контейнера:
# сначала создаём/обновляем Config Profile, ноду, шаблон подписки, хосты и
# Internal Squad в панели, чтобы нода гарантированно существовала в панели даже
# при ручном вводе SECRET_KEY или сбое сети Docker.
PANEL_NODE_UUID=""
if (( REMNAWAVE_AUTO_SETUP )); then
  panel_auto_setup || warn "Авто-настройка панели завершилась с ошибкой — проверьте панель вручную (README шаги 1–8)"
fi

# 2) Получаем SECRET_KEY (автоматически через GET /keygen или из ввода)
AUTO_SECRET_KEY=""
if (( REMNAWAVE_AUTO_SETUP )) && [[ -z "${SECRET_KEY:-}" ]]; then
  note "Получение SECRET_KEY ноды из Remnawave Panel API (GET /keygen)..."
  panel_curl_cfg_init
  AUTO_SECRET_KEY="$(panel_fetch_node_secret 2>/dev/null || true)"
  if [[ -n "$AUTO_SECRET_KEY" ]]; then
    ok "SECRET_KEY ноды получен автоматически через Panel API"
  else
    warn "Не удалось автоматически получить SECRET_KEY через Panel API (HTTP $(panel_api_code); выдайте токену право keygen:*)."
  fi
fi

if [[ -n "$AUTO_SECRET_KEY" ]]; then
  SECRET_RAW="$AUTO_SECRET_KEY"
else
  if [[ -n "${PANEL_NODE_UUID:-}" ]]; then
    note "Нода уже создана в панели ($SERVER_IP:$NODE_API_PORT) — откройте её в Nodes → Management и скопируйте SECRET_KEY."
  else
    note "Создайте ноду в панели (Nodes -> Add) с IP $SERVER_IP и портом $NODE_API_PORT."
  fi
  note "Панель выдаст SECRET_KEY (ключ связи с нодой). Вставьте его целиком."
  note "Можно как чистое значение (eyJ...), так и строку 'SECRET_KEY=...'."
  echo
  ask_secret SECRET_RAW "SECRET_KEY из панели" "${SECRET_KEY:-}"
fi

SECRET_VALUE="$SECRET_RAW"
SECRET_VALUE="${SECRET_VALUE#SECRET_KEY=}"
SECRET_VALUE="${SECRET_VALUE#\"}"; SECRET_VALUE="${SECRET_VALUE%\"}"
SECRET_VALUE="${SECRET_VALUE#\'}"; SECRET_VALUE="${SECRET_VALUE%\'}"
SECRET_VALUE="$(printf '%s' "$SECRET_VALUE" | tr -d '[:space:]')"
[[ -n "$SECRET_VALUE" ]] || die "Пустой SECRET_KEY."

# На случай, если в старом окружении или .env оставался голый тег без репозитория
NODE_IMAGE="$(normalize_node_image "$NODE_IMAGE")"

if [[ "$BUILD_COMPOSE" -eq 1 ]]; then
  ( umask 077
    cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_API_PORT
SECRET_KEY=$SECRET_VALUE
NODE_IMAGE=$NODE_IMAGE
EOF
  )
  # Файл от старой версии мог остаться с другими правами: перезапись через
  # redirection права не меняет, поэтому приводим к 0600 явно.
  chmod 600 "$NODE_DIR/.env"
  cat > "$NODE_DIR/docker-compose.yml" <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE:-remnawave/node:latest}
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
  chmod 600 "$NODE_DIR/.env"
  ok "Обновлён $NODE_DIR/.env (compose оставлен как есть)"
fi

( cd "$NODE_DIR" && retry 3 10 docker compose pull ) || die "docker compose pull не удался."
( cd "$NODE_DIR" && retry 3 10 docker compose up -d --remove-orphans ) || die "docker compose up не удался."

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
# В образе ноды busybox: GNU find с -printf там не работает, поэтому
# перечисляем файлы через ls. Если сертификаты вообще не найдены (например,
# том не смонтирован) — получаем ненулевой код и предупреждение.
docker exec -i remnanode sh -s <<'SH' 2>/dev/null | sed 's/^/   /' \
  || warn "Не удалось прочитать сертификаты внутри контейнера (docker logs remnanode)."
files=$(ls -1 /etc/remna-certs/*/key.pem /etc/remna-certs/*/fullchain.pem 2>/dev/null)
if [ -z "$files" ]; then
  echo "сертификаты не найдены в /etc/remna-certs"
  exit 1
fi
ls -l $files | sort
SH
ok "Контейнер remnanode запущен"

# 3) Контейнер remnanode уже слушает API-порт — просим панель немедленно
# подключиться и передать конфиг Xray (не дожидаясь периодического опроса),
# чтобы к шагу 10 все слушатели Xray уже поднялись.
if (( REMNAWAVE_AUTO_SETUP )) && [[ -n "${PANEL_NODE_UUID:-}" ]]; then
  panel_trigger_node_start "$PANEL_NODE_UUID" || true
fi

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

log "Жду все протокольные слушатели после получения конфигурации от панели (до 60s)..."
listeners_ready=0
for _ in $(seq 1 30); do
  if all_protocol_listeners_ready; then
    listeners_ready=1
    break
  fi
  sleep 2
done

printf '   %s%sTCP listeners%s\n' "${C_B:-}" "${C_MAG:-}" "${C_RST:-}"
ss -lntup 2>/dev/null | grep -E ':443|:9443|:9444|:10443|:10444|:10446|:10447|:'"$NODE_API_PORT" | sed 's/^/     /' || true
printf '   %s%sUDP listeners (Hysteria2)%s\n' "${C_B:-}" "${C_MAG:-}" "${C_RST:-}"
ss -lnuap 2>/dev/null | grep ':443' | sed 's/^/     /' || true

if [[ "$listeners_ready" -ne 1 ]]; then
  has_tcp_listener 443 || warn "Caddy L4 не слушает TCP/443."
  has_tcp_listener_at 127.0.0.1 9443 || warn "Self-steal сайт не слушает 127.0.0.1:9443."
  has_tcp_listener_at 127.0.0.1 10443 || warn "Vision inbound не слушает 127.0.0.1:10443."
  if (( ENABLE_XHTTP )); then
    has_tcp_listener_at 127.0.0.1 10444 || warn "XHTTP inbound не слушает 127.0.0.1:10444."
  fi
  if (( ENABLE_CDN )); then
    has_tcp_listener_at 127.0.0.1 "$CDN_TLS_PORT" \
      || warn "CDN-сайт Caddy не слушает 127.0.0.1:$CDN_TLS_PORT."
    if (( CDN_WS_ENABLED )); then
      has_tcp_listener_at 127.0.0.1 "$CDN_WS_PORT" \
        || warn "WS-inbound CDN не слушает 127.0.0.1:$CDN_WS_PORT (включён ли VLESS_CDN_WS на карточке ноды?)."
    fi
    if (( CDN_XHTTP_ENABLED )); then
      has_tcp_listener_at 127.0.0.1 "$CDN_XHTTP_PORT" \
        || warn "XHTTP-inbound CDN не слушает 127.0.0.1:$CDN_XHTTP_PORT (включён ли VLESS_CDN_XHTTP на карточке ноды?)."
    fi
    if (( CDN_GRPC_ENABLED )); then
      has_tcp_listener_at 127.0.0.1 "$CDN_GRPC_PORT" \
        || warn "gRPC-inbound CDN не слушает 127.0.0.1:$CDN_GRPC_PORT (включён ли VLESS_CDN_GRPC на карточке ноды?)."
    fi
  fi
  has_tcp_listener "$NODE_API_PORT" || warn "Node API не слушает порт $NODE_API_PORT."
  has_udp_listener 443 || warn "Hysteria2 не слушает UDP/443."
  docker logs remnanode --tail 120 2>&1 | sed 's/^/   /' || true
  if (( ENABLE_CDN )); then
    note "CDN включён: назначенный Config Profile должен содержать выбранные VLESS_CDN_*, а на карточке ноды они должны быть включены."
  fi
  die "Не все inbound'ы поднялись за 60s. Проверьте назначенный Config Profile в Remnawave."
fi
ok "Все TCP/UDP-слушатели активны"

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

tls_failures=0
ROUTE_PAIRS=("Vision:$VISION_SNI")
if (( ENABLE_XHTTP )); then
  ROUTE_PAIRS+=("XHTTP:$XHTTP_SNI")
fi
if (( ENABLE_CDN )); then
  # Проверяем именно origin-плечо: сертификат для CDN-хоста должен проходить
  # проверку имени, иначе Cloudflare в режиме Full (strict) отвергнет origin.
  ROUTE_PAIRS+=("CDN:$CDN_HOST")
fi
for pair in "${ROUTE_PAIRS[@]}"; do
  name="${pair%%:*}"; sni="${pair#*:}"
  check_tls_route "$name" "$sni" || tls_failures=$((tls_failures + 1))
done
printf '   %s%sSelf-steal target (%s)%s\n' "${C_B:-}" "${C_MAG:-}" "$SELF_STEAL_HOST" "${C_RST:-}"
if self_steal_output="$(timeout 12 openssl s_client -connect 127.0.0.1:9443 \
    -servername "$SELF_STEAL_HOST" -verify_hostname "$SELF_STEAL_HOST" \
    -verify_return_error -brief </dev/null 2>&1)" \
    && grep -Eq 'CONNECTION ESTABLISHED|Protocol version:' <<<"$self_steal_output"; then
  printf '%s\n' "$self_steal_output" | head -8 | sed 's/^/     /'
else
  printf '%s\n' "$self_steal_output" | head -8 | sed 's/^/     /'
  die "Локальный TLS-сайт self-steal не прошёл проверку."
fi

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

printf '   %s%sHTTP-слой: :80 и локальный TLS-сайт%s\n' "${C_B:-}" "${C_MAG:-}" "${C_RST:-}"
verify_http_layer

(( tls_failures == 0 )) || die "Не прошли TLS-проверку маршруты: $tls_failures. Установка не считается завершённой."
ok "Все SNI/TLS-маршруты прошли проверку"

prune_matching_files "$LOG_DIR" 'remnanode-setup-*.log' 10

log "Очистка установочных остатков (apt, Docker)"
cleanup_system_leftovers

echo
printf '%s%s╭──────────────────────────────────────────────────────────────╮%s\n' "${C_B:-}" "${C_GRN:-}" "${C_RST:-}"
printf '%s%s│%s  %s✔ ГОТОВО%s  Проверьте статус ноды в панели — должна быть online   %s%s│%s\n' \
  "${C_B:-}" "${C_GRN:-}" "${C_RST:-}" "${C_B:-}${C_GRN:-}" "${C_RST:-}" "${C_B:-}${C_GRN:-}" "" "${C_RST:-}"
printf '%s%s╰──────────────────────────────────────────────────────────────╯%s\n' "${C_B:-}" "${C_GRN:-}" "${C_RST:-}"
echo
printf '   %s%sКонфигурация нод-инбаундов (сверьте в панели)%s\n' "${C_B:-}" "${C_MAG:-}" "${C_RST:-}"
kv "Vision/Reality" "SNI $SELF_STEAL_HOST  →  127.0.0.1:10443  (target: 127.0.0.1:9443)"
if (( ENABLE_XHTTP )); then
  kv "XHTTP"          "SNI $XHTTP_SNI  path $XHTTP_PATH  →  127.0.0.1:10444"
else
  kv "XHTTP"          "(отключено — режим только Vision)"
fi
if (( ENABLE_CDN )); then
  kv "VLESS за CDN"   "$CDN_HOST  →  origin 127.0.0.1:$CDN_TLS_PORT  ($CDN_TRANSPORT)"
  if [[ "$CDN_DNS_MANAGED" == "cloudflare" ]]; then
    kv "  CDN: DNS"  "проксируемая A-запись в Cloudflare создана (proxied=on)"
  else
    kv "  CDN: DNS"  "ВРУЧНУЮ: проксируемая A-запись $CDN_HOST → $SERVER_IP ещё не создана!"
  fi
  if (( CDN_WS_ENABLED )); then kv "  CDN: ws" "path $CDN_WS_PATH  →  127.0.0.1:$CDN_WS_PORT"; fi
  if (( CDN_XHTTP_ENABLED )); then kv "  CDN: xhttp" "path $CDN_XHTTP_PATH  →  127.0.0.1:$CDN_XHTTP_PORT"; fi
  if (( CDN_GRPC_ENABLED )); then kv "  CDN: grpc" "serviceName $CDN_GRPC_PATH  →  h2c 127.0.0.1:$CDN_GRPC_PORT"; fi
fi
kv "Hysteria2"      "UDP/443 напрямую  (cert $CERT_DIR/$HY_HOST)"
kv "HTTP 301"       "TCP/80  →  https://$SELF_STEAL_HOST  (путь и query сохраняются)"
kv "TLS"            "1.2/1.3 + HSTS max-age=31536000 на self-steal сайте"
kv "Node API"       "$SERVER_IP:$NODE_API_PORT  (только с панели $PANEL_IP)"
kv "Образ ноды"     "$NODE_IMAGE"
echo
if (( SELF_STEAL_THEME_USED )); then
  kv "Тема фасада"    "$SELF_STEAL_TEMPLATE"
fi
kv "Config Profile" "$NODE_DIR/Multiselect.json  (вставьте в панели → Config Profiles)"
kv "Шаблон XRAY"    "$NODE_DIR/Xray_template.json  ($XRAY_TEMPLATE_CHOICE, тег $(panel_node_tag))"
kv "Лог установки"   "$LOG_FILE"
kv "Логи ноды"       "docker logs remnanode --tail 120"
kv "Логи Xray"      "docker exec -it remnanode tail -n +1 -f /var/log/xray/current"
kv "Статус Caddy"    "systemctl status caddy --no-pager"
kv "Firewall"        "ufw status numbered"
echo
