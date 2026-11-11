#!/usr/bin/env bash
set -Eeuo pipefail

# Заголовок установщика: версия, константы, usage и цвета.
# Единый remnanode-setup.sh собирается из lib/*.sh через build.sh.

SCRIPT_VERSION="1.3.0"

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
UNINSTALL=0
DRY_RUN="${DRY_RUN:-0}"
# Интерактивное изменение настроек уже установленной ноды без переустановки.
RECONFIGURE="${RECONFIGURE:-0}"
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
# Быстрый режим мастера (--quick / QUICK_SETUP=y): только 9 вопросов —
# домен, токен Cloudflare, домен панели, токен панели, IP панели, шаблон
# подписки, транспорт CDN, XHTTP target (external/local) и WARP (да/нет).
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
NODE_IMAGE="${NODE_IMAGE:-remnawave/node:3.4.4}"
# Кастомный Xray-core для Remnawave Node (CUSTOM_CORE_URL). Пусто — штатный
# Xray из образа. "uwuray" — предустановленный URL UwURay под архитектуру;
# иначе полный https:// URL на бинарник. Мutable "latest" удобен, но не
# воспроизводим: для продакшена лучше закрепить конкретный release URL.
CUSTOM_CORE_URL="${CUSTOM_CORE_URL:-}"
# WARP: исходящий туннель WireGuard до Cloudflare для сервисов, которые не
# пускают адреса хостингов (AI: OpenAI, Anthropic, Gemini). В туннель уходит
# только помеченный трафик — остальное идёт напрямую с IP сервера. Схема:
# отдельная таблица маршрутизации + ip rule fwmark, watchdog с ротацией
# endpoint, CLI remnawave-warp. Реализация — lib/45-warp.sh.
# ENABLE_WARP: "" — решить по режиму мастера, 1 — включить, 0 — не ставить.
ENABLE_WARP="${ENABLE_WARP:-}"
WARP_SETTING=""
# Задан ли WARP явно (env/сохранённый env-файл/флаг) — тогда мастер не
# спрашивает и не переопределяет решение дефолтом режима.
WARP_ENV_PRESENT=0
[[ -n "${ENABLE_WARP:-}" ]] && WARP_ENV_PRESENT=1
# Метка (SO_MARK) в sockopt у outbound'а WARP. Должна совпадать с ip rule.
WARP_FWMARK="${WARP_FWMARK:-255}"
WARP_TABLE="${WARP_TABLE:-51820}"
WARP_MTU="${WARP_MTU:-1280}"
WARP_IFACE="${WARP_IFACE:-warp}"
# MSS = MTU − 40 (IPv4+TCP); без clamping тяжёлые сайты зависают.
WARP_MSS=$((WARP_MTU - 40))
# Путь трафика через WARP: ai — только AI/заблокированные сервисы (домены
# берутся из WARP_ROUTE_DOMAINS_DEFAULT), all — весь исходящий трафик ноды.
WARP_ROUTE_MODE="${WARP_ROUTE_MODE:-ai}"
WARP_CONF="/etc/wireguard/${WARP_IFACE}.conf"
WARP_STATE_DIR="/etc/remnawave-warp"
WARP_DIR="/opt/remnawave-warp"
WARP_RP_FILTER_FILE="/etc/sysctl.d/99-remnawave-warp.conf"
# Пул endpoint'ов Cloudflare: индексы 188.114.96/97 — те, что обычно проходят.
WARP_ENDPOINT_SUBNETS="${WARP_ENDPOINT_SUBNETS:-188.114.96 188.114.97}"
WARP_ENDPOINT_PORTS="${WARP_ENDPOINT_PORTS:-2408 500 4500 1701}"
# wgcf регистрирует аккаунт и генерирует WireGuard-профиль. Версия закреплена:
# «последняя» превращала бы установку в запуск произвольного бинарника от root.
WGCF_VERSION="${WGCF_VERSION:-v2.3.1}"
WGCF_SHA256_AMD64="${WGCF_SHA256_AMD64:-4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8}"
WGCF_SHA256_ARM64="${WGCF_SHA256_ARM64:-710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301}"
# Ключ WARP+ (опционально): вводится один раз и на диск не сохраняется.
WARP_LICENSE="${WARP_LICENSE:-}"
# Домены/geosite, которые уходят в WARP. Добавить свои: WARP_ROUTE_DOMAINS
# (список через запятую) и WARP_ROUTE_GEOSITE (имена geosite-категорий).
WARP_ROUTE_DOMAINS="${WARP_ROUTE_DOMAINS:-}"
WARP_ROUTE_GEOSITE="${WARP_ROUTE_GEOSITE:-}"
WARP_ROUTE_DOMAINS_DEFAULT=(
  "geosite:openai"
  "geosite:anthropic"
  "geosite:google-gemini"
  "geosite:category-ai-!cn"
  "domain:claude.ai"
  "domain:chatgpt.com"
  "domain:chat.com"
  "domain:openai.com"
  "domain:anthropic.com"
  "domain:gemini.google.com"
  "domain:aistudio.google.com"
  "domain:generativelanguage.googleapis.com"
  "domain:perplexity.ai"
  "domain:copilot.microsoft.com"
  "domain:api.x.ai"
  "domain:grok.com"
)
# Заполняется на шаге WARP: IP туннеля для сводки.
WARP_LOCAL_IP=""
WARP_READY=0
# Внешние install-скрипты закреплены по commit/tag и SHA256: get.docker.com и
# get.acme.sh отдают плавающий master. Свои значения можно передать через env.
DOCKER_INSTALL_URL="${DOCKER_INSTALL_URL:-https://raw.githubusercontent.com/docker/docker-install/ada7a567e59b/install.sh}"
DOCKER_INSTALL_SHA256="${DOCKER_INSTALL_SHA256:-2b102d809152ea157a59f171319f489d971273b2d26dd7e9a6d1d737ce89289d}"
ACME_INSTALL_URL="${ACME_INSTALL_URL:-https://raw.githubusercontent.com/acmesh-official/acme.sh/v3.1.6/acme.sh}"
ACME_INSTALL_SHA256="${ACME_INSTALL_SHA256:-c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7}"
# 1 — обновлять acme.sh из upstream при каждом запуске (плавающий код).
ACME_AUTO_UPGRADE="${ACME_AUTO_UPGRADE:-0}"
DOCKER_INSTALL_TMP=""
ACME_INSTALL_DIR=""
ACME_INSTALL_TMP=""
# Темы фасада self-steal: файлы self-steal-templates/<тема>.html в репозитории.
# Дефолт — прежний «файлообменник», чтобы поведение не менялось без запроса.
# Базу URL шаблонов фасада можно переопределить (свой форк, тег или коммит):
SELF_STEAL_RAW_BASE="${SELF_STEAL_RAW_BASE:-https://raw.githubusercontent.com/bami7up/multi-protocol/main}"
SELF_STEAL_TEMPLATES=(vaultdrop mail cloud admin docs)
# none — не устанавливать шаблон: оставить собственный сайт в SELF_STEAL_ROOT.
# Это не тема из репозитория, поэтому в SELF_STEAL_TEMPLATES её нет.
SELF_STEAL_TEMPLATE_NONE="none"
# Тема задана явно (env/--self-steal-template)? Тогда быстрый режим не вправе
# заменять её случайной на свежей установке.
SELF_STEAL_TEMPLATE_EXPLICIT=0
[[ -n "${SELF_STEAL_TEMPLATE:-}" ]] && SELF_STEAL_TEMPLATE_EXPLICIT=1
SELF_STEAL_TEMPLATE="${SELF_STEAL_TEMPLATE:-vaultdrop}"
# Явный URL (свой фасад) важнее имени темы; проверяется при разборе переменных.
SELF_STEAL_TEMPLATE_URL="${SELF_STEAL_TEMPLATE_URL:-}"
SELF_STEAL_THEME_USED=0
# Каталог фасада: при SELF_STEAL_TEMPLATE=none установщик его не трогает и
# только проверяет, что там есть index.html.
SELF_STEAL_ROOT="${SELF_STEAL_ROOT:-/var/www/remnanode-self-steal}"
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
GO_VERSION="1.26.10"
GO_INSTALL_TMP=""
GO_ARCHIVE_TMP=""
CADDY_RESTORE_NEEDED=0
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/remnanode-setup-$(date +%F-%H%M%S).log"
CADDYFILE_PATH="${CADDYFILE_PATH:-/etc/caddy/Caddyfile}"
# REALITY: минимальная версия клиента, которую пускает сервер. 0.0.0 —
# совместимость с Mihomo (он представляется 1.8.2, см. MetaCubeX/mihomo
# #3132/#3039); более строгие значения — осознанный opt-in.
REALITY_MIN_CLIENT_VER="${REALITY_MIN_CLIENT_VER:-0.0.0}"
# REALITY target для XHTTP. self → локальный self-steal сайт
# (127.0.0.1:$SELF_STEAL_TLS_PORT); иначе host:port. Внешний target остаётся
# дефолтом, пока local self-steal не подтверждён тестом (Xray-core #5923).
XHTTP_TARGET="${XHTTP_TARGET:-www.gstatic.com:443}"
# ACME: auto — DNS-01 при наличии Cloudflare-токена, иначе HTTP-01; dns —
# только DNS-01 (не останавливает Caddy и не рвёт 443/tcp); http — только
# HTTP-01 (короткий простой 443/tcp на время challenge).
ACME_METHOD="${ACME_METHOD:-auto}"
# Каталог логов Xray на хосте. Монтируется в контейнер как /var/log/xray:
# если образ пишет туда файлы, их ротирует logrotate; stdout по-прежнему
# ограничен Docker log-opts (50m × 5).
XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/remnanode/xray}"
SELF_STEAL_TLS_PORT="${SELF_STEAL_TLS_PORT:-9443}"
SELF_STEAL_HTTP_PORT="${SELF_STEAL_HTTP_PORT:-}"
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
  --node-image REF      образ ноды (по умолчанию remnawave/node:3.4.4)
  --custom-core-url URL кастомный Xray-core для ноды (CUSTOM_CORE_URL);
                        uwuray — предустановленный UwURay, либо https:// URL бинарника
  --node-tag TAG        уникальный тег балансировки ноды (A-Z0-9_:, до 32 символов)
  --self-steal-template T
                        тема фасада self-steal (vaultdrop, mail, cloud, admin, docs)
                        или none — не устанавливать шаблон, оставить свой сайт в
                        SELF_STEAL_ROOT (по умолчанию /var/www/remnanode-self-steal)
  --min-client-ver X.Y.Z
                        минимальная версия клиента для REALITY (по умолчанию 0.0.0:
                        совместимо с Mihomo; значения >1.8.2 могут отсечь Mihomo)
  --xhttp-target TARGET target REALITY для XHTTP: host:port, self или local
                        (self/local = локальный self-steal 127.0.0.1:9443)
  --acme-method M       auto | dns | http. auto: DNS-01 при Cloudflare-токене,
                        иначе HTTP-01; dns не останавливает Caddy и не рвёт 443/tcp
  --xray-template T     шаблон подписки: standard (весь трафик через VPN) или split
  --warp                поднять исходящий туннель Cloudflare WARP (WireGuard) для
                        AI-сервисов и включить outbound WARP в Config Profile
  --no-warp             не ставить WARP (по умолчанию WARP включается в быстром режиме)
  --warp-route MODE     ai — через WARP только AI/заблокированные сервисы
                        (по умолчанию), all — весь исходящий трафик ноды
  --warp-mark N         метка пакетов для WARP (sockopt.mark, по умолчанию 255)
  --cloudflare          создать A-записи через Cloudflare API
  --no-cloudflare       не использовать Cloudflare, даже если токен в env
  --panel-url URL       URL панели Remnawave (напр. https://panel.example.com)
  --quick               быстрый режим мастера: 9 вопросов, остальное — авто/случайно
  --advanced            расширенный режим мастера: все вопросы (как раньше)
  --uninstall           удалить управляемые компоненты (нода, Caddyfile,
                        сертификаты, UFW-правила, env-файл); пакеты остаются
  --reconfigure         интерактивно изменить настройки уже установленной ноды
                        (тема фасада, XHTTP/CDN, WARP, minClientVer, ACME method)
  --dry-run             показать, что удалит --uninstall, без изменений
  --version             показать версию/ревизию
  -y | --yes            авто-подтверждение всех «y/n» вопросов
  --non-interactive     не задавать вопросы: все значения из env/дефолтов
  -h | --help           показать эту справку

Переменные окружения (для --non-interactive / CI):
  BASE_DOMAIN, PREFIX, SELF_STEAL_HOST, XHTTP_SNI, XHTTP_PATH, ENABLE_XHTTP,
  ENABLE_CDN, CDN_HOST, CDN_TRANSPORT, CDN_WS_PATH, CDN_XHTTP_PATH, CDN_GRPC_PATH,
  PANEL_IP, NODE_API_PORT, SECRET_KEY, NODE_IMAGE, NODE_TAG,
  CUSTOM_CORE_URL,
  ENABLE_WARP, WARP_ROUTE_MODE, WARP_FWMARK, WARP_TABLE, WARP_MTU, WARP_IFACE,
  WARP_ROUTE_DOMAINS, WARP_ROUTE_GEOSITE, WARP_LICENSE, WGCF_VERSION,
  SELF_STEAL_TEMPLATE, SELF_STEAL_TEMPLATE_URL, SELF_STEAL_ROOT,
  MULTISELECT_TEMPLATE_URL,
  REALITY_MIN_CLIENT_VER, XHTTP_TARGET, ACME_METHOD,
  SELF_STEAL_RAW_BASE, XRAY_TEMPLATE_CHOICE,
  XCADDY_VERSION, CADDY_VERSION, CADDY_L4_VERSION,
  DOCKER_INSTALL_URL, DOCKER_INSTALL_SHA256,
  ACME_INSTALL_URL, ACME_INSTALL_SHA256, ACME_AUTO_UPGRADE,
  CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE,
  REMNAWAVE_PANEL_URL, REMNAWAVE_API_TOKEN, REMNAWAVE_AUTO_SETUP,
  QUICK_SETUP, SERVER_IP, NODE_DIR, CERT_DIR, ENV_STORE, KEEP_BUILD_TOOLS,
  XRAY_LOG_DIR

Логические переменные (ENABLE_XHTTP, ENABLE_CDN, ENABLE_WARP, REMNAWAVE_AUTO_SETUP, QUICK_SETUP, KEEP_BUILD_TOOLS) понимают
y/yes/1/true/on и n/no/0/false/off в любом регистре; пустое значение означает ответ по умолчанию.
Значение SERVER_IP (в том числе из сохранённого env-файла) важнее автодетекта:
задайте его, если нода за NAT или внешние сервисы определения IP недоступны.

Интерактивный мастер сначала спросит режим:
  быстрый (рекомендуется): всего 9 вопросов — домен, токен Cloudflare,
    домен панели (полным URL: https://panel.example.com), токен панели,
    IP панели, шаблон подписки, транспорт CDN, XHTTP target (external/local)
    и WARP (да/нет); поддомены, CDN-домен, пути, тема и порт ноды — автоматически;
  расширенный: прежние 4 блока вопросов со всеми настройками.
USAGE
}

if [[ -t 1 || "${FORCE_COLOR:-0}" == 1 ]]; then
  C_RST=$'\033[0m';  C_B=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[38;5;203m'; C_GRN=$'\033[38;5;114m'; C_YLW=$'\033[38;5;221m'
  C_BLU=$'\033[38;5;75m';  C_CYN=$'\033[38;5;80m';  C_MAG=$'\033[38;5;177m'
  C_GRY=$'\033[38;5;245m'; C_WHT=$'\033[38;5;255m'
else
  C_RST=; C_B=; C_DIM=; C_RED=; C_GRN=; C_YLW=; C_BLU=; C_CYN=; C_MAG=; C_GRY=; C_WHT=
fi

RULE='────────────────────────────────────────────────────────────────'
STEP_TOTAL=11
