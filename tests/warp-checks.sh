#!/usr/bin/env bash
# Юнит-проверки интеграции WARP (lib/45-warp.sh).
#
# WARP — единственная часть схемы, которая общается с внешним миром и меняет
# маршрутизацию ядра, поэтому проверяется без сервера:
#   * разбор профиля wgcf (IPv6-адреса и чужой endpoint выбрасываются, иначе
#     часть доменов уходит в blackhole, а туннель — на заблокированный адрес);
#   * сгенерированный конфиг WireGuard: Table, PostUp/PostDown, MSS, keepalive;
#   * fail-closed на битом профиле (битый ключ/пустой Address не должен
#     превращаться в «интерфейс поднялся, а трафика нет»);
#   * нормализация WARP_ROUTE_DOMAINS и вставка правила WARP в Config Profile;
#   * re-render профиля при повторном запуске (идемпотентность) и снятие
#     outbound'а вместе с правилом при выключении WARP.
#
# SC2034: переменные ниже читают функции из lib/, а не этот файл.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317,SC2329
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok()   { printf '✔ %s\n' "$*"; }

[[ -r "$SRC/lib/45-warp.sh" ]] || fail "не найден $SRC/lib/45-warp.sh"

# shellcheck source=/dev/null
for f in "$SRC"/lib/*.sh; do
  [[ "$(basename "$f")" == "90-main.sh" ]] && continue
  . "$f"
done

# Стабы: тесты не трогают систему.
ok()   { printf '✔ %s\n' "$*"; }
warn() { printf '▲ %s\n' "$*" >&2; }
note() { :; }
log()  { :; }
die()  { printf 'die: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
sleep() { :; }

# Перенаправляем пути WARP во временный каталог.
WARP_STATE_DIR="$WORK/state"
WARP_DIR="$WORK/app"
WARP_CONF="$WORK/warp.conf"
export WARP_STATE_DIR WARP_DIR WARP_CONF

# --- warp_arch: только архитектуры, под которые есть пин SHA256 ------------
(
  case "$(uname -m)" in
    x86_64|amd64) want=amd64 ;;
    aarch64|arm64) want=arm64 ;;
    *) want="" ;;
  esac
  got="$(warp_arch)" || got=""
  [[ "$got" == "$want" ]] || fail "warp_arch вернула «$got», ожидалось «$want»"
)
ok "warp_arch: архитектура для wgcf определена"

# --- пины wgcf: SHA256 есть для обеих поддерживаемых архитектур -----------
for a in amd64 arm64; do
  sha="$(warp_wgcf_sha256 "$a")" || fail "нет SHA256 для wgcf/$a"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "SHA256 для wgcf/$a не похож на хеш: $sha"
done
if warp_wgcf_sha256 riscv64 >/dev/null 2>&1; then
  fail "warp_wgcf_sha256 вернула хеш для неподдерживаемой архитектуры"
fi
[[ "${WGCF_VERSION}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "WGCF_VERSION не закреплён тегом: $WGCF_VERSION"
ok "wgcf: версия закреплена тегом, SHA256 есть для amd64/arm64"

# --- warp_valid_mark: 0 и выход за 32 бита отвергаются --------------------
if warp_valid_mark 0; then fail "метка 0 принята (означает «без метки»)"; fi
if warp_valid_mark 2147483648; then fail "метка больше 32 бит принята"; fi
if warp_valid_mark abc; then fail "нечисловая метка принята"; fi
warp_valid_mark 255   || fail "метка 255 отвергнута"
warp_valid_mark 1     || fail "метка 1 отвергнута"
warp_valid_mark 1048576 || fail "большая корректная метка отвергнута"
ok "warp_valid_mark: 1..2147483647, ноль и мусор отвергнуты"

# --- warp_random_endpoint: адрес из пула Cloudflare, а не из профиля ------
for _ in 1 2 3 4 5; do
  ep="$(warp_random_endpoint)"
  [[ "$ep" =~ ^188\.114\.(96|97)\.[1-9][0-9]{0,2}:(2408|500|4500|1701)$ ]] \
    || fail "warp_random_endpoint вернул неожиданный адрес: $ep"
done
ok "warp_random_endpoint: 188.114.96/97 на портах 2408/500/4500/1701"

# --- warp_trim / warp_first_ipv4 / warp_first_hostport --------------------
[[ "$(warp_trim 'Address = 172.16.0.2/32')" == "172.16.0.2/32" ]] \
  || fail "warp_trim не отрезал ключ"
[[ "$(warp_first_ipv4 '172.16.0.2/32, 2606:4700::/128')" == "172.16.0.2/32" ]] \
  || fail "warp_first_ipv4 не выбрал IPv4 из списка с IPv6"
if warp_first_ipv4 '2606:4700::/128' >/dev/null; then
  fail "warp_first_ipv4 принял IPv6-адрес"
fi
[[ "$(warp_first_hostport 'engage.cloudflareclient.com:2408')" == "engage.cloudflareclient.com:2408" ]] \
  || fail "warp_first_hostport отверг корректный endpoint"
if warp_first_hostport 'без-порта' >/dev/null; then fail "warp_first_hostport принял строку без порта"; fi
ok "разбор профиля: ключ, IPv4 из списка и host:port"

# --- warp_render_conf: ключевые директивы и отсутствие IPv6 --------------
mkdir -p "$WARP_STATE_DIR/wgcf"
cat > "$WARP_STATE_DIR/wgcf/wgcf-profile.conf" <<'EOF'
[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
DNS = 1.1.1.1, 1.0.0.1
Address = 172.16.0.2/32, 2606:4700:110:8a36:df92:102a:9602:fa18/128
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
EOF
WARP_MTU=1280; WARP_MSS=1240
warp_render_conf "$WARP_STATE_DIR/wgcf/wgcf-profile.conf" "$WARP_CONF" \
  || fail "warp_render_conf не собрал конфиг из корректного профиля"
[[ "$(stat -c %a "$WARP_CONF")" == 600 ]] || fail "конфиг WARP создан не с правами 0600"
grep -q '^PrivateKey = yAnz5TF' "$WARP_CONF" || fail "в конфиге нет приватного ключа"
grep -q '^Address = 172.16.0.2/32$' "$WARP_CONF" || fail "в конфиге нет IPv4-адреса туннеля"
if grep -qE '2606:|::/0|DNS =' "$WARP_CONF"; then
  fail "в конфиге остались IPv6-адреса/маршрут или DNS (blackhole у провайдеров)"
fi
if grep -q 'engage.cloudflareclient.com' "$WARP_CONF"; then
  fail "в конфиге остался endpoint wgcf: он чаще всего и блокируется"
fi
grep -q '^Endpoint = 188\.114\.' "$WARP_CONF" || fail "endpoint не заменён на адрес из пула Cloudflare"
grep -q "^Table = ${WARP_TABLE}$" "$WARP_CONF" \
  || fail "нет Table: маршруты ушли бы в main и сломали дефолт сервера"
grep -qF "ip rule add fwmark ${WARP_FWMARK} table ${WARP_TABLE}" "$WARP_CONF" \
  || fail "нет правила fwmark → table"
grep -qF "ip rule del fwmark ${WARP_FWMARK} table ${WARP_TABLE} 2>/dev/null || true" "$WARP_CONF" \
  || fail "правило не удаляется перед добавлением (после падения wg-quick останутся дубликаты)"
grep -qF "ip rule del fwmark ${WARP_FWMARK} table ${WARP_TABLE} 2>/dev/null || true" "$WARP_CONF" \
  || fail "нет PostDown для правила"
grep -qF -- "--set-mss 1240" "$WARP_CONF" || fail "нет TCP MSS clamping (тяжёлые сайты зависают)"
awk '/^PostUp = iptables -t mangle -D/{ok=1} END{exit !ok}' "$WARP_CONF" \
  || fail "правило mangle не удаляется перед добавлением (дубликаты при перезапуске)"
grep -q '^PersistentKeepalive = 15$' "$WARP_CONF" || fail "нет PersistentKeepalive"
ok "warp_render_conf: IPv4-only, Table, ip rule, MSS clamp и keepalive"

# Endpoint должен меняться при повторной сборке (иначе ротация бессмысленна).
first_ep="$(sed -n 's/^Endpoint = //p' "$WARP_CONF")"
warp_render_conf "$WARP_STATE_DIR/wgcf/wgcf-profile.conf" "$WARP_CONF"
second_ep="$(sed -n 's/^Endpoint = //p' "$WARP_CONF")"
[[ "$first_ep" != "$second_ep" ]] \
  || fail "endpoint не пересобирается: повторный запуск оставил тот же адрес ($first_ep)"
ok "warp_render_conf: повторный запуск берёт свежий endpoint"

# --- fail-closed: битый профиль не должен давать конфиг -------------------
render_bad() {
  local content="$1" name="$2"
  printf '%s\n' "$content" > "$WORK/bad.conf"
  if warp_render_conf "$WORK/bad.conf" "$WORK/bad-out.conf" 2>/dev/null; then
    fail "warp_render_conf принял битый профиль: $name"
  fi
  [[ ! -s "$WORK/bad-out.conf" ]] || fail "битый профиль ($name) оставил конфиг"
}
render_bad '[Interface]
PrivateKey = short
Address = 172.16.0.2/32

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "короткий приватный ключ"
render_bad '[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 2606:4700::1/128

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "только IPv6-адрес"
render_bad '[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 172.16.0.2/32' "нет секции Peer"
if warp_render_conf "$WORK/missing.conf" "$WORK/bad-out.conf" 2>/dev/null; then
  fail "warp_render_conf счёл успехом отсутствующий профиль"
fi
ok "warp_render_conf: битый профиль — отказ, а не «поднятый» туннель"

# --- warp_valid_settings: диагностика до изменений в системе --------------
(
  WARP_FWMARK=255 WARP_TABLE=51820 WARP_MTU=1280 WARP_IFACE=warp
  warp_validate_settings || fail "корректные настройки WARP отвергнуты"
)
assert_die() {
  local desc="$1"
  if ( "$@" ) >/dev/null 2>&1; then fail "валидация пропустила: $desc"; fi
}
assert_die "метка 0"     env WARP_FWMARK=0 WARP_TABLE=51820 WARP_MTU=1280 WARP_IFACE=warp bash -c 'die(){ exit 1; }; warp_validate_settings'
assert_die "имя iface"   env WARP_FWMARK=255 WARP_TABLE=51820 WARP_MTU=1280 WARP_IFACE='warp; rm -rf /' bash -c 'die(){ exit 1; }; warp_validate_settings'
assert_die "MTU 512"     env WARP_FWMARK=255 WARP_TABLE=51820 WARP_MTU=512 WARP_IFACE=warp bash -c 'die(){ exit 1; }; warp_validate_settings'
ok "warp_validate_settings: метка, имя интерфейса и MTU проверяются"

# --- warp_normalize_route_item / warp_route_domains_json -----------------
[[ "$(warp_normalize_route_item 'example.org')" == "domain:example.org" ]] \
  || fail "домен без префикса не превратился в domain:"
[[ "$(warp_normalize_route_item 'Example.ORG')" == "domain:example.org" ]] \
  || fail "домен не приведён к нижнему регистру"
[[ "$(warp_normalize_route_item '*.foo.net')" == "domain:foo.net" ]] \
  || fail "маска *. не снята (Xray не понимает domain:*.foo.net)"
[[ "$(warp_normalize_route_item 'geosite:openai')" == "geosite:openai" ]] \
  || fail "geosite-паттерн испорчен"
[[ "$(warp_normalize_route_item 'full:api.example.com')" == "full:api.example.com" ]] \
  || fail "full-паттерн испорчен"
if warp_normalize_route_item 'https://bad' >/dev/null; then fail "URL принят как домен"; fi
if warp_normalize_route_item 'no-dot' >/dev/null; then fail "строка без точки принята как домен"; fi
if warp_normalize_route_item 'a"b.com' >/dev/null; then fail "кавычка в домене принята"; fi
ok "warp_normalize_route_item: domain/full/geosite, маска и мусор"

WARP_ROUTE_DOMAINS="example.org, example.org, *.foo.net"
WARP_ROUTE_GEOSITE="anthropic"
list="$(warp_route_domains_json)"
printf '%s' "$list" | jq -e . >/dev/null || fail "список маршрутов — не валидный JSON: $list"
printf '%s' "$list" | jq -e 'index("domain:example.org") != null' >/dev/null \
  || fail "домен из WARP_ROUTE_DOMAINS не попал в маршруты"
printf '%s' "$list" | jq -e 'index("geosite:anthropic") != null' >/dev/null \
  || fail "geosite из WARP_ROUTE_GEOSITE не попал в маршруты"
printf '%s' "$list" | jq -e 'index("geosite:openai") != null' >/dev/null \
  || fail "встроенный AI-паттерн geosite:openai пропал"
[[ "$(printf '%s' "$list" | jq '[.[] | select(. == "domain:example.org")] | length')" == 1 ]] \
  || fail "дубликаты в списке маршрутов не устранены"
printf '%s' "$list" | jq -e 'index("domain:foo.net") != null' >/dev/null \
  || fail "маска *.foo.net не нормализована в domain:foo.net"
ok "warp_route_domains_json: встроенные AI-домены + пользовательские, без дублей"

# --- Config Profile: outbound WARP и правило маршрутизации ---------------
# Окружение для multiselect_filter (шаблон берём из репозитория).
SELF_STEAL_HOST=steal.example.com
HY_HOST=hy.example.com
XHTTP_SNI=xhttp.example.com
XHTTP_PATH=/x
CDN_WS_PATH=/ws
CDN_XHTTP_PATH=/xh
CDN_GRPC_PATH=/g
CERT_DIR=/etc/remna-certs
REALITY_MIN_CLIENT_VER=0.0.0
XHTTP_TARGET=www.gstatic.com:443
CDN_TRANSPORT=ws
ENABLE_XHTTP=1
ENABLE_CDN=1
[[ -r "$SRC/Multiselect.json" ]] || fail "нет Multiselect.json"

WARP_FWMARK=255 WARP_ROUTE_MODE=ai ENABLE_WARP=1 \
  multiselect_filter < "$SRC/Multiselect.json" > "$WORK/profile-ai.json" \
  || fail "multiselect_filter упал с включённым WARP"
jq -e '.outbounds | map(select(.tag == "WARP")) | length == 1' "$WORK/profile-ai.json" >/dev/null \
  || fail "в профиле нет ровно одного outbound WARP"
jq -e '.outbounds[] | select(.tag == "WARP")
       | .protocol == "freedom"
         and .settings.domainStrategy == "ForceIPv4"
         and .streamSettings.sockopt.mark == 255' "$WORK/profile-ai.json" >/dev/null \
  || fail "outbound WARP не freedom+ForceIPv4+sockopt.mark"
jq -e '[.routing.rules[] | select(.outboundTag == "WARP")] | length == 1' "$WORK/profile-ai.json" >/dev/null \
  || fail "в routing нет ровно одного правила WARP"
jq -e '.routing.rules[-1].outboundTag == "WARP"' "$WORK/profile-ai.json" >/dev/null \
  || fail "правило WARP не стало маршрутом по умолчанию (в шаблоне только BLOCK-правила)"
jq -e '.routing.rules[0:-1] | map(.outboundTag == "BLOCK") | all' "$WORK/profile-ai.json" >/dev/null \
  || fail "правило WARP перекрыло BLOCK-правила (bittorrent/private)"
jq -e '[.routing.rules[] | select(.outboundTag == "WARP") | .domain[]]
       | index("geosite:openai") != null' "$WORK/profile-ai.json" >/dev/null \
  || fail "правило WARP не содержит geosite:openai"
ok "Config Profile: outbound WARP (sockopt.mark) и AI-правило после BLOCK"

# Режим all: правило без доменов, весь трафик по умолчанию.
WARP_ROUTE_MODE=all ENABLE_WARP=1 \
  multiselect_filter < "$SRC/Multiselect.json" > "$WORK/profile-all.json"
jq -e '[.routing.rules[] | select(.outboundTag == "WARP")][0]
       | .network == "tcp,udp" and (.domain == null)' "$WORK/profile-all.json" >/dev/null \
  || fail "режим all не завернул весь трафик в WARP"
ok "Config Profile: режим all — весь исходящий трафик через WARP"

# Выключение WARP убирает и outbound, и правило (иначе профиль ссылается на
# несуществующий тег и Xray не стартует).
ENABLE_WARP=0 multiselect_filter < "$WORK/profile-all.json" > "$WORK/profile-off.json"
jq -e '[.outbounds[].tag] | index("WARP") == null' "$WORK/profile-off.json" >/dev/null \
  || fail "outbound WARP остался в профиле после выключения"
jq -e '[.routing.rules[].outboundTag] | index("WARP") == null' "$WORK/profile-off.json" >/dev/null \
  || fail "правило WARP осталось после выключения"
jq -e '[.outbounds[].tag] | index("DIRECT") != null' "$WORK/profile-off.json" >/dev/null \
  || fail "при выключении WARP пропал DIRECT"
ok "Config Profile: выключение WARP снимает outbound и правило"

# Повторное применение не плодит дубликаты (идемпотентность reconfigure).
WARP_ROUTE_MODE=ai ENABLE_WARP=1 \
  multiselect_filter < "$WORK/profile-ai.json" > "$WORK/profile-ai2.json"
jq -e '([.outbounds[] | select(.tag == "WARP")] | length) == 1
       and ([.routing.rules[] | select(.outboundTag == "WARP")] | length) == 1' \
  "$WORK/profile-ai2.json" >/dev/null \
  || fail "повторное применение WARP задублировало outbound/правило"
ok "Config Profile: повторная сборка профиля идемпотентна"

# Профиль без routing (собран вручную) не должен ронять фильтр.
printf '%s' '{"inbounds":[],"outbounds":[{"tag":"DIRECT","protocol":"freedom"}]}' > "$WORK/min.json"
ENABLE_WARP=1 multiselect_filter < "$WORK/min.json" > "$WORK/min-out.json" \
  || fail "multiselect_filter упал на профиле без routing"
jq -e '.routing.rules[0].outboundTag == "WARP"' "$WORK/min-out.json" >/dev/null \
  || fail "на профиле без routing правило WARP не создано"
ok "Config Profile: профиль без routing не ломает сборку"

# --- Команды CLI и таймер: watchdog и управление на месте -----------------
grep -q '^warp_write_watchdog() {' "$SRC/lib/45-warp.sh" || fail "нет warp_write_watchdog"
grep -q '^warp_write_cli() {' "$SRC/lib/45-warp.sh" || fail "нет warp_write_cli"
grep -qF 'remnawave-warp-watchdog.timer' "$SRC/lib/45-warp.sh" || fail "нет таймера watchdog"
grep -qF 'OnUnitActiveSec=3min' "$SRC/lib/45-warp.sh" || fail "watchdog не каждые 3 минуты"
grep -qF 'backoff=$(( 180 * (2 ** exp) ))' "$SRC/lib/45-warp.sh" \
  || fail "нет backoff при ротации (перезапуск каждые 3 минуты = заметный признак)"
grep -qF 'rotate)' "$SRC/lib/45-warp.sh" || fail "в CLI нет rotate"
grep -qF 'uninstall)' "$SRC/lib/45-warp.sh" || fail "в CLI нет uninstall"
ok "watchdog и CLI: таймер 3 минуты, backoff, rotate и uninstall"

# --- Сгенерированные watchdog и CLI: валидный shell ----------------------
# Тела собираются quoted heredoc'ом внутри установщика. Проверить их на этом
# стенде дешевле, чем ловить «syntax error» на сервере в 3 часа ночи.
extract_body() {
  awk -v tag="$1" '
    index($0, "<<\047" tag "\047") {inside=1; next}
    inside && $0 == tag {exit}
    inside {print}
  ' "$SRC/lib/45-warp.sh"
}
for tag in WARPWDEOF WARPCLIEOF; do
  extract_body "$tag" > "$WORK/$tag.sh"
  [[ -s "$WORK/$tag.sh" ]] || fail "не удалось извлечь тело $tag из lib/45-warp.sh"
  bash -n "$WORK/$tag.sh" || fail "сгенерированный $tag — невалидный shell"
done
grep -q 'systemctl is-active --quiet "wg-quick@${IFACE}" || exit 0' "$WORK/WARPWDEOF.sh" \
  || fail "watchdog не выходит молча, когда туннель остановлен вручную"
grep -q 'ping "${PING_ARGS\[@\]}"' "$WORK/WARPWDEOF.sh" ||
  fail "watchdog не пингует через туннель"
grep -q 'rotate)' "$WORK/WARPCLIEOF.sh" || fail "в CLI нет команды rotate"
ok "watchdog и CLI: тела собираются quoted heredoc'ом и проходят bash -n"

# --- env-файл: решение по WARP переживает повторный запуск ---------------
ENV_STORE="$WORK/remnanode.env"
export ENV_STORE
SERVER_IP=203.0.113.10
BASE_DOMAIN=example.com
PREFIX=usa
VLESS_HOST=usa1.example.com
HY_HOST=usa3.example.com
ACME_EMAIL=admin@example.com
SELF_STEAL_HOST=usa1.example.com
VISION_SNI=usa1.example.com
ENABLE_XHTTP=1
XHTTP_SNI=www.gstatic.com
XHTTP_PATH=/api/v3/sync/r1
NODE_API_PORT=2222
NODE_IMAGE=remnawave/node:3.4.4
NODE_TAG=QUIET_OTTER_631F
SELF_STEAL_TEMPLATE=vaultdrop
XRAY_TEMPLATE_CHOICE=standard
CF_MODE=0
QUICK_SETUP=1
REMNAWAVE_AUTO_SETUP=0
ENABLE_CDN=0
ENABLE_WARP=1
WARP_ROUTE_MODE=all
WARP_FWMARK=200
WARP_TABLE=51234
WARP_ROUTE_DOMAINS="example.org"
write_env_store
[[ "$(stat -c %a "$ENV_STORE")" == 600 ]] || fail "env-файл с настройками WARP не 0600"
grep -q '^export ENABLE_WARP=y$' "$ENV_STORE" || fail "решение по WARP не сохраняется в env-файл"
grep -q '^export WARP_ROUTE_MODE=all$' "$ENV_STORE" || fail "режим маршрутизации WARP не сохраняется"
grep -q '^export WARP_FWMARK=200$' "$ENV_STORE" || fail "метка WARP не сохраняется"
grep -q '^export WARP_TABLE=51234$' "$ENV_STORE" || fail "таблица маршрутизации WARP не сохраняется"
grep -q '^export WARP_ROUTE_DOMAINS=example.org$' "$ENV_STORE" || fail "список доменов WARP не сохраняется"
# Выключенный WARP тоже фиксируется: иначе быстрый режим включит его снова.
ENABLE_WARP=0
write_env_store
grep -q '^export ENABLE_WARP=n$' "$ENV_STORE" || fail "выключенный WARP не сохраняется в env-файл"
if grep -q '^export WARP_ROUTE_DOMAINS=' "$ENV_STORE"; then
  fail "при выключенном WARP в env-файл всё ещё пишется его маршрутизация"
fi
ok "env-файл: ENABLE_WARP, режим, метка и домены сохраняются и снимаются"

printf 'все проверки WARP прошли\n' 
