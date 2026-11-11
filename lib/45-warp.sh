# --- WARP outbound: ядерный WireGuard-туннель до Cloudflare WARP ---
#
# Зачем. Часть сервисов — в первую очередь AI (OpenAI, Anthropic, Gemini) —
# не пускает клиентов с IP-адресов хостингов и отвечает 403. Туннель до
# Cloudflare WARP подменяет адрес выхода, и такие сервисы начинают работать,
# при этом остальной трафик сервера и клиентов идёт напрямую.
#
# Как. Схема повторяет tagashi666/vps-warp, но живёт внутри установщика:
#   * туннель поднимает штатный wg-quick (никаких проприетарных демонов);
#   * маршруты складываются в отдельную таблицу (Table = $WARP_TABLE), а
#     политика `ip rule fwmark $WARP_FWMARK` уводит в неё только помеченные
#     пакеты. Помечает их Xray: у outbound'а WARP стоит sockopt.mark;
#   * в основной таблице маршрутизации ничего не меняется, поэтому падение
#     WARP не рвёт связь с панелью и не мешает входу клиентов;
#   * TCP MSS clamping (1240 при MTU 1280) — иначе тяжёлые сайты подвисают;
#   * rp_filter понижается со strict до loose: обратный трафик туннеля
#     приходит асимметрично и при strict молча дропается (симптом коварный:
#     хэндшейк свежий, интерфейс активен, а трафика нет);
#   * watchdog раз в 3 минуты проверяет хэндшейк и пинг через метку, при
#     сбое меняет endpoint Cloudflare и перезапускает туннель, с backoff;
#   * всё управление — CLI `remnawave-warp` (status/start/stop/rotate/log/...).

# Архитектура для бинарника wgcf.
warp_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

# Ожидаемая SHA256 суммы скачанного wgcf. Пины нужны, чтобы «обновите до
# последней версии» не превращалось в запуск произвольного бинарника от root.
warp_wgcf_sha256() {
  case "$1" in
    amd64) printf '%s' "$WGCF_SHA256_AMD64" ;;
    arm64) printf '%s' "$WGCF_SHA256_ARM64" ;;
    *) return 1 ;;
  esac
}

warp_trim() {
  local v="${1#*=}"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# Первый IPv4 из строки вида «172.16.0.2/32, 2606:4700::/128».
warp_first_ipv4() {
  local part
  local IFS=','
  for part in $1; do
    part="${part//[[:space:]]/}"
    if [[ "$part" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
      printf '%s' "$part"
      return 0
    fi
  done
  return 1
}

# Endpoint из профиля wgcf: host:port без пробелов.
warp_first_hostport() {
  local v="${1//[[:space:]]/}"
  [[ "$v" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || return 1
  printf '%s' "$v"
}

# Случайный endpoint Cloudflare из пула, который обычно не режут провайдеры.
# $RANDOM вместо shuf: shuf есть не всегда, а пустой RAND_* дал бы битый
# конфиг WireGuard (молча, на этапе, где уже поздно).
warp_random_endpoint() {
  local subnets ports subnet host port
  read -r -a subnets <<<"$WARP_ENDPOINT_SUBNETS"
  read -r -a ports <<<"$WARP_ENDPOINT_PORTS"
  subnet="${subnets[RANDOM % ${#subnets[@]}]}"
  host=$(( RANDOM % 254 + 1 ))
  port="${ports[RANDOM % ${#ports[@]}]}"
  printf '%s.%s:%s' "$subnet" "$host" "$port"
}

# Метка 0 бесполезна (fwmark 0 означает «без метки»), а mark больше 32 бит
# ядро не примет — отсекаем на входе, а не на apply.
warp_valid_mark() {
  local m="${1:-}"
  [[ "$m" =~ ^[0-9]{1,10}$ ]] || return 1
  (( 10#$m >= 1 && 10#$m <= 2147483647 ))
}

# Пакеты помечаются через SO_MARK — это право CAP_NET_ADMIN. Без него Xray в
# контейнере молча уйдёт напрямую с реального IP, поэтому проверяем заранее.
warp_validate_settings() {
  warp_valid_mark "$WARP_FWMARK" || die "WARP_FWMARK=$WARP_FWMARK некорректен: нужно число 1..2147483647."
  if ! [[ "$WARP_TABLE" =~ ^[0-9]{1,10}$ ]] || ! (( 10#$WARP_TABLE >= 1 )); then
    die "WARP_TABLE=$WARP_TABLE некорректен: нужно число больше нуля."
  fi
  if ! [[ "$WARP_MTU" =~ ^[0-9]{3,4}$ ]] || ! (( 10#$WARP_MTU >= 1280 && 10#$WARP_MTU <= 1500 )); then
    die "WARP_MTU=$WARP_MTU некорректен: WARP работает на MTU 1280..1500."
  fi
  [[ "$WARP_IFACE" =~ ^[a-z][a-z0-9]{0,14}$ ]] \
    || die "WARP_IFACE=$WARP_IFACE некорректен: нужно имя интерфейса (a-z0-9, до 15 символов)."
}

# Зависимости: wg-quick/wg, iptables (MSS clamp и правило метки), ping
# (watchdog проверяет связь именно пингом через туннель).
warp_install_deps() {
  local -a pkgs=()
  have wg || pkgs+=(wireguard-tools)
  have wg-quick || pkgs+=(wireguard)
  have iptables || pkgs+=(iptables)
  have ping || pkgs+=(iputils-ping)
  (( ${#pkgs[@]} == 0 )) && { ok "Зависимости WARP уже установлены"; return 0; }
  log "Устанавливаю зависимости WARP: ${pkgs[*]}"
  apt_get install -y "${pkgs[@]}" >/dev/null || die "Не удалось установить зависимости WARP: ${pkgs[*]}"
  have wg-quick || die "wg-quick не появился в системе после установки wireguard."
  ok "Зависимости WARP установлены (${pkgs[*]})"
}

# wgcf нужен только на время установки/обновления: он регистрирует аккаунт в
# Cloudflare и генерирует WireGuard-конфиг. Дальше туннель живёт на ядре.
warp_install_wgcf() {
  local arch="$1" tmp url sha
  if [[ -x /usr/local/bin/wgcf ]] \
      && [[ "$(/usr/local/bin/wgcf --version 2>/dev/null | awk '{print $NF}')" == "${WGCF_VERSION#v}" ]]; then
    ok "wgcf ${WGCF_VERSION#v} уже установлен"
    return 0
  fi
  sha="$(warp_wgcf_sha256 "$arch")" || die "Нет пина SHA256 для wgcf/$arch."
  url="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${arch}"
  tmp="$(mktemp)" || die "mktemp для wgcf не удался."
  if ! retry 3 5 curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    die "Не удалось скачать wgcf: $url"
  fi
  printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null \
    || { rm -f "$tmp"; die "SHA256 wgcf не совпал — установка остановлена ($url)."; }
  install -m 0755 "$tmp" /usr/local/bin/wgcf || { rm -f "$tmp"; die "Не удалось установить wgcf."; }
  rm -f "$tmp"
  ok "wgcf ${WGCF_VERSION#v} установлен (/usr/local/bin/wgcf)"
}

# Регистрация в Cloudflare. Рабочий каталог — $WARP_STATE_DIR/wgcf, а не $HOME:
# sudo сбрасывает HOME, и аккаунт терялся бы после перезахода.
warp_register() {
  local dir="$WARP_STATE_DIR/wgcf" i
  mkdir -p "$dir"
  chmod 700 "$WARP_STATE_DIR" "$dir" 2>/dev/null || true
  if [[ ! -f "$dir/wgcf-account.toml" ]]; then
    log "Регистрирую аккаунт Cloudflare WARP (до 3 попыток)"
    for i in 1 2 3; do
      # `yes` отвечает на запрос принятия условий; таймаут — чтобы Ctrl-C и
      # зависшая сеть не держали установку бесконечно.
      if ( cd "$dir" && timeout 60 bash -c 'yes | wgcf register' >/dev/null 2>&1 ); then
        break
      fi
      (( i < 3 )) && sleep 3
    done
  fi
  if [[ ! -f "$dir/wgcf-account.toml" ]]; then
    warn "Cloudflare отклонил регистрацию (rate-limit или блокировка IP хостинга)."
    return 1
  fi
  chmod 600 "$dir/wgcf-account.toml"
  if ! ( cd "$dir" && wgcf generate >/dev/null 2>&1 ); then
    warn "wgcf не смог сгенерировать профиль ($dir/wgcf-profile.conf)."
    return 1
  fi
  ok "Профиль WARP сгенерирован ($dir/wgcf-profile.conf)"
}

# WARP+ опционален: лицензионный ключ повышает приоритет трафика. Ключ не
# сохраняется на диск — он попадает в аккаунт wgcf и нужен только один раз.
warp_apply_license() {
  local dir="$WARP_STATE_DIR/wgcf" key
  key="$(printf '%s' "${WARP_LICENSE:-}" | tr -cd 'a-zA-Z0-9-')"
  [[ -n "$key" ]] || return 0
  log "Активирую ключ WARP+"
  if ( cd "$dir" && wgcf update --license-key "$key" >/dev/null 2>&1 ) \
      && ( cd "$dir" && wgcf generate >/dev/null 2>&1 ); then
    ok "Лицензия WARP+ активирована"
  else
    warn "Ключ WARP+ не принят — остаюсь на бесплатном тарифе."
  fi
}

# Сборка итогового конфига WireGuard. Пишем файл целиком, а не правим вывод
# wgcf sed-ом: так IPv6-адреса и маршруты, на которых провайдеры вешают
# blackhole, просто не попадают в конфиг, а секции и порядок директив
# остаются предсказуемыми (и проверяемыми юнит-тестом).
warp_render_conf() {
  local src="${1:-$WARP_STATE_DIR/wgcf/wgcf-profile.conf}" dst="${2:-$WARP_CONF}"
  local line private_key="" peer_pub="" addr4="" endpoint=""
  [[ -r "$src" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      PrivateKey\ =*|PrivateKey=*) [[ -n "$private_key" ]] || private_key="$(warp_trim "$line")" ;;
      PublicKey\ =*|PublicKey=*)   [[ -n "$peer_pub" ]]    || peer_pub="$(warp_trim "$line")" ;;
      Address\ =*|Address=*)       [[ -n "$addr4" ]]       || addr4="$(warp_first_ipv4 "$(warp_trim "$line")")" ;;
      Endpoint\ =*|Endpoint=*)     [[ -n "$endpoint" ]]    || endpoint="$(warp_first_hostport "$(warp_trim "$line")")" ;;
    esac
  done < "$src"
  [[ -n "$private_key" && -n "$peer_pub" && -n "$addr4" ]] || return 1
  # Ключи WireGuard — base64 ровно 32 байт (44 символа с «=» на конце).
  [[ "$private_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  [[ "$peer_pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  [[ "$addr4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  # Endpoint из профиля wgcf — общий engage.cloudflareclient.com, который как
  # раз и режут; берём случайный адрес из пула Cloudflare.
  endpoint="$(warp_random_endpoint)"

  mkdir -p "$(dirname "$dst")"
  ( umask 077
    {
      printf '[Interface]\n'
      printf 'PrivateKey = %s\n' "$private_key"
      printf 'Address = %s\n' "$addr4"
      printf 'MTU = %s\n' "$WARP_MTU"
      # Явный Table уводит маршруты wg-quick из main: дефолт сервера цел, а в
      # туннель попадает только помеченное. Без Table пакеты ушли бы все.
      printf 'Table = %s\n' "$WARP_TABLE"
      # del перед add: после жёсткой перезагрузки или OOM-killed wg-quick
      # правило могло остаться, и каждый старт добавлял бы дубликат.
      printf 'PostUp = ip rule del fwmark %s table %s 2>/dev/null || true\n' "$WARP_FWMARK" "$WARP_TABLE"
      printf 'PostUp = ip rule add fwmark %s table %s || true\n' "$WARP_FWMARK" "$WARP_TABLE"
      printf 'PostDown = ip rule del fwmark %s table %s 2>/dev/null || true\n' "$WARP_FWMARK" "$WARP_TABLE"
      # MSS clamping: при MTU 1280 «тяжёлые» сайты иначе подвисают на TLS.
      printf 'PostUp = iptables -t mangle -D POSTROUTING -o %s -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s 2>/dev/null || true\n' "$WARP_IFACE" "$WARP_MSS"
      printf 'PostUp = iptables -t mangle -A POSTROUTING -o %s -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s || true\n' "$WARP_IFACE" "$WARP_MSS"
      printf 'PostDown = iptables -t mangle -D POSTROUTING -o %s -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s 2>/dev/null || true\n' "$WARP_IFACE" "$WARP_MSS"
      printf '\n[Peer]\n'
      printf 'PublicKey = %s\n' "$peer_pub"
      # Только IPv4: IPv6-маршрут WARP у части провайдеров чёрная дыра, и
      # часть доменов «зависает» на попытке подключиться по IPv6.
      printf 'AllowedIPs = 0.0.0.0/0\n'
      printf 'Endpoint = %s\n' "$endpoint"
      printf 'PersistentKeepalive = 15\n'
    } > "$dst"
  ) || return 1
  chmod 600 "$dst"
  return 0
}

# rp_filter: туннель асимметричен by design. Помеченные пакеты уходят через
# $WARP_IFACE, а расшифрованные ответы приходят без метки, смотрятся в main и
# упираются в дефолт через основной NIC — строгий rp_filter (=1) их дропает.
# Ядро берёт max(conf.all, conf.<iface>), поэтому опускать нужно оба уровня.
# Трогаем только значение 1: осознанно выставленный 0 остаётся как есть.
warp_relax_rp_filter() {
  local scope cur
  local -a touched=()
  for scope in all default; do
    cur="$(cat "/proc/sys/net/ipv4/conf/${scope}/rp_filter" 2>/dev/null)" || continue
    [[ "$cur" == 1 ]] || continue
    sysctl -qw "net.ipv4.conf.${scope}.rp_filter=2" 2>/dev/null && touched+=("$scope")
  done
  (( ${#touched[@]} )) || return 0
  {
    printf '# Добавлено установщиком multi-protocol: policy-routing WARP требует\n'
    printf '# нестрогого reverse-path filter. Удаляется при --uninstall.\n'
    for scope in "${touched[@]}"; do
      printf 'net.ipv4.conf.%s.rp_filter = 2\n' "$scope"
    done
  } > "$WARP_RP_FILTER_FILE"
  chmod 644 "$WARP_RP_FILTER_FILE"
  ok "rp_filter понижен strict → loose (${touched[*]:-нет}) и закреплён в $WARP_RP_FILTER_FILE"
}

# Эффективное значение rp_filter так, как его считает ядро.
warp_rp_filter_effective() {
  local all iface
  all="$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 0)"
  iface="$(cat "/proc/sys/net/ipv4/conf/${WARP_IFACE}/rp_filter" 2>/dev/null || echo 0)"
  [[ "$all" =~ ^[0-9]+$ ]] || all=0
  [[ "$iface" =~ ^[0-9]+$ ]] || iface=0
  (( all > iface )) && printf '%s' "$all" || printf '%s' "$iface"
}

warp_wait_handshake() {
  local i hs age
  for i in $(seq 1 20); do
    hs="$(wg show "$WARP_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
    if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then
      age=$(( $(date +%s) - hs ))
      ok "WARP: хэндшейк установлен (${age}s назад)"
      return 0
    fi
    sleep 1
  done
  warn "WARP: хэндшейк не пришёл за 20s. Интерфейс поднят, но связь может быть заблокирована — проверьте: remnawave-warp log"
  return 1
}

# Watchdog: раз в 3 минуты. Проверяет хэндшейк и пинг ровно тем маршрутом,
# которым ходит Xray (метка → правило → таблица WARP). При сбое меняет
# endpoint и перезапускает туннель. Пауза между ротациями растёт 3→6→…→30
# минут, потому что при полной блокировке Cloudflare перезапуск раз в 3
# минуты (480 в сутки) сам по себе заметный признак.
warp_write_watchdog() {
  mkdir -p "$WARP_DIR"
  chmod 700 "$WARP_DIR"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# Сгенерировано установщиком multi-protocol; правки будут потеряны.'
    printf 'IFACE=%q\n' "$WARP_IFACE"
    printf 'FWMARK=%q\n' "$WARP_FWMARK"
    printf 'CONF=%q\n' "$WARP_CONF"
    printf 'STATE_FILE=%q\n' "$WARP_STATE_DIR/watchdog.state"
    printf 'SUBNETS=%q\n' "$WARP_ENDPOINT_SUBNETS"
    printf 'PORTS=%q\n' "$WARP_ENDPOINT_PORTS"
  } > "$WARP_DIR/watchdog.sh"
  cat >> "$WARP_DIR/watchdog.sh" <<'WARPWDEOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Туннель остановлен оператором — молчим, это не сбой.
systemctl is-active --quiet "wg-quick@${IFACE}" || exit 0
[[ -f "$CONF" ]] || { echo "WARP watchdog: нет $CONF — нечего проверять"; exit 1; }

hs_ts=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
hs_ts=${hs_ts:-0}
now=$(date +%s)
age=$(( now - hs_ts ))

# busybox ping не знает -m, поэтому есть запасной вариант через интерфейс.
if ping -V 2>&1 | grep -qi iputils; then
    PING_ARGS=(-m "$FWMARK")
else
    PING_ARGS=(-I "$IFACE")
fi

ping_ok=0
for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
    if ping "${PING_ARGS[@]}" -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        ping_ok=1
        break
    fi
done

healthy=1
[[ "$hs_ts" -eq 0 || $age -gt 180 ]] && healthy=0
[[ $ping_ok -eq 0 ]] && healthy=0

fails=0
last_rot=0
if [[ -f "$STATE_FILE" ]]; then
    read -r fails last_rot < "$STATE_FILE" || true
fi
[[ "$fails" =~ ^[0-9]+$ ]] || fails=0
[[ "$last_rot" =~ ^[0-9]+$ ]] || last_rot=0

if [[ $healthy -eq 1 ]]; then
    [[ $fails -ne 0 ]] && printf '0 %s\n' "$last_rot" > "$STATE_FILE"
    exit 0
fi

exp=$(( fails > 4 ? 4 : fails ))
backoff=$(( 180 * (2 ** exp) ))
[[ $backoff -gt 1800 ]] && backoff=1800
if [[ $(( now - last_rot )) -lt $backoff ]]; then
    echo "WARP watchdog: связи нет (сбой #$((fails + 1))), следующая ротация через $(( backoff - (now - last_rot) ))s"
    exit 0
fi

read -r -a subnets <<< "$SUBNETS"
read -r -a ports <<< "$PORTS"
subnet="${subnets[RANDOM % ${#subnets[@]}]}"
host=$(( RANDOM % 254 + 1 ))
port="${ports[RANDOM % ${#ports[@]}]}"
endpoint="${subnet}.${host}:${port}"

sed -i "s/^Endpoint = .*/Endpoint = ${endpoint}/" "$CONF" || exit 1
systemctl restart "wg-quick@${IFACE}"
printf '%s %s\n' "$(( fails + 1 ))" "$now" > "$STATE_FILE"
echo "WARP watchdog: связи нет (хэндшейк ${age}s, ping $ping_ok). Endpoint → ${endpoint}"
WARPWDEOF
  chmod 700 "$WARP_DIR/watchdog.sh"

  cat > /etc/systemd/system/remnawave-warp-watchdog.service <<EOF
[Unit]
Description=multi-protocol: WARP tunnel watchdog
After=wg-quick@${WARP_IFACE}.service

[Service]
Type=oneshot
ExecStart=$WARP_DIR/watchdog.sh
EOF
  cat > /etc/systemd/system/remnawave-warp-watchdog.timer <<'EOF'
[Unit]
Description=multi-protocol: проверка WARP каждые 3 минуты

[Timer]
OnBootSec=3min
OnUnitActiveSec=3min

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/remnawave-warp-watchdog.service \
             /etc/systemd/system/remnawave-warp-watchdog.timer
  systemctl daemon-reload
  systemctl enable --now remnawave-warp-watchdog.timer >/dev/null 2>&1 \
    || warn "Не удалось включить таймер remnawave-warp-watchdog.timer."
  ok "Watchdog WARP установлен (remnawave-warp-watchdog.timer, каждые 3 минуты)"
}

# CLI. Собирается так же, как watchdog: заголовок с %q-значениями, затем
# quoted heredoc — иначе пришлось бы экранировать каждый «$» в теле.
warp_write_cli() {
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' '# Сгенерировано установщиком multi-protocol; правки будут потеряны.'
    printf 'IFACE=%q\n' "$WARP_IFACE"
    printf 'FWMARK=%q\n' "$WARP_FWMARK"
    printf 'WTABLE=%q\n' "$WARP_TABLE"
    printf 'WMSS=%q\n' "$WARP_MSS"
    printf 'CONF=%q\n' "$WARP_CONF"
    printf 'IFACE=%q\n' "$WARP_IFACE"
    printf 'STATE_DIR=%q\n' "$WARP_STATE_DIR"
    printf 'APP_DIR=%q\n' "$WARP_DIR"
    printf 'RP_FLAG_FILE=%q\n' "$WARP_RP_FILTER_FILE"
    printf 'SUBNETS=%q\n' "$WARP_ENDPOINT_SUBNETS"
    printf 'PORTS=%q\n' "$WARP_ENDPOINT_PORTS"
  } > /usr/local/bin/remnawave-warp
  cat >> /usr/local/bin/remnawave-warp <<'WARPCLIEOF'
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "remnawave-warp: нужны права root (sudo remnawave-warp $*)"
    exit 1
fi
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
C_RST=$'\e[0m'; C_B=$'\e[1m'; C_GRN=$'\e[32m'; C_RED=$'\e[31m'
C_YLW=$'\e[33m'; C_GRY=$'\e[90m'; C_CYN=$'\e[36m'

format_bytes() {
    local b="$1"
    if [[ -z "$b" || "$b" == 0 ]]; then echo "0 KB"; return; fi
    if   (( b < 1048576 ));    then echo "$((b / 1024)) KB"
    elif (( b < 1073741824 )); then echo "$((b / 1048576)) MB"
    else echo "$(awk "BEGIN {printf \"%.1f\", $b/1073741824}") GB"
    fi
}

random_endpoint() {
    read -r -a subnets <<< "$SUBNETS"
    read -r -a ports <<< "$PORTS"
    echo "${subnets[RANDOM % ${#subnets[@]}]}.$(( RANDOM % 254 + 1 )):${ports[RANDOM % ${#ports[@]}]}"
}

show_status() {
    local c_stat t_stat tunnel_ip endpoint raw_stats rx tx hs_ts age c_hs t_hs c_rule t_rule rp c_rp t_rp

    if systemctl is-active --quiet "wg-quick@${IFACE}"; then
        c_stat="$C_GRN"; t_stat="ACTIVE"
    else
        c_stat="$C_RED"; t_stat="INACTIVE"
    fi

    tunnel_ip=$(ip -4 addr show "$IFACE" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
    endpoint=$(sed -n 's/^Endpoint = //p' "$CONF" 2>/dev/null | head -1)
    raw_stats=$(wg show "$IFACE" transfer 2>/dev/null | head -1)
    rx=$(format_bytes "$(awk '{print $2}' <<< "$raw_stats")")
    tx=$(format_bytes "$(awk '{print $3}' <<< "$raw_stats")")

    hs_ts=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    if [[ "$hs_ts" =~ ^[0-9]+$ ]] && (( hs_ts > 0 )); then
        age=$(( $(date +%s) - hs_ts ))
        c_hs="$C_GRN"; t_hs="${age}s назад"
    else
        c_hs="$C_RED"; t_hs="нет соединения"
    fi

    # Пропажа правила означает, что помеченные пакеты Xray уходят с реального
    # IP сервера — со стороны «всё работает», но не так, как задумано.
    if ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$FWMARK") lookup ${WTABLE}"; then
        c_rule="$C_GRN"; t_rule="ok (fwmark ${FWMARK} → table ${WTABLE})"
    else
        c_rule="$C_RED"; t_rule="MISSING (fwmark ${FWMARK} → table ${WTABLE})"
    fi

    rp=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo 0)
    if [[ "$rp" == 1 ]]; then
        c_rp="$C_RED"; t_rp="STRICT (=1) — обратный трафик будет теряться"
    else
        c_rp="$C_GRN"; t_rp="loose (=${rp:-?})"
    fi

    echo
    echo -e "  ${C_B}${C_CYN}WARP — Cloudflare${C_RST}"
    echo -e "  ${C_GRY}─────────────────────────────────────${C_RST}"
    echo -e "   ${C_GRY}Статус:${C_RST}      ${c_stat}${C_B}${t_stat}${C_RST}"
    echo -e "   ${C_GRY}IP туннеля:${C_RST}  ${C_CYN}${tunnel_ip:---}${C_RST}"
    echo -e "   ${C_GRY}Endpoint:${C_RST}    ${C_CYN}${endpoint:---}${C_RST}"
    echo -e "   ${C_GRY}Хэндшейк:${C_RST}    ${c_hs}${t_hs}${C_RST}"
    echo -e "   ${C_GRY}Маршрутизация:${C_RST} ${c_rule}${t_rule}${C_RST}"
    echo -e "   ${C_GRY}rp_filter:${C_RST}   ${c_rp}${t_rp}${C_RST}"
    echo -e "   ${C_GRY}Трафик:${C_RST}      ${C_YLW}↓ ${rx}${C_RST}  ${C_GRY}|${C_RST}  ${C_YLW}↑ ${tx}${C_RST}"
    echo -e "  ${C_GRY}─────────────────────────────────────${C_RST}"
    echo -e "   ${C_GRY}Команды:${C_RST} status | start | stop | restart | rotate | log | uninstall"
    echo
}

rotate_endpoint() {
    local ep
    ep=$(random_endpoint)
    if ! sed -i "s/^Endpoint = .*/Endpoint = ${ep}/" "$CONF"; then
        echo "remnawave-warp: не удалось записать $CONF" >&2
        exit 1
    fi
    systemctl restart "wg-quick@${IFACE}"
    # Ручная ротация — вмешательство оператора: снимаем backoff watchdog.
    rm -f "${STATE_DIR}/watchdog.state"
    echo -e "  ${C_GRN}✔${C_RST} Endpoint сменён на ${ep}"
    sleep 2
    show_status
}

uninstall_warp() {
    local reply
    echo -e "  ${C_YLW}▲${C_RST} Будут удалены туннель WARP, watchdog, CLI, правило и sysctl-файл."
    read -r -p "  Для подтверждения введите yes: " reply
    [[ "$reply" == yes ]] || { echo "  Отменено."; exit 0; }

    systemctl disable --now "wg-quick@${IFACE}" >/dev/null 2>&1
    systemctl disable --now remnawave-warp-watchdog.timer >/dev/null 2>&1
    systemctl stop remnawave-warp-watchdog.service >/dev/null 2>&1
    rm -f /etc/systemd/system/remnawave-warp-watchdog.service \
          /etc/systemd/system/remnawave-warp-watchdog.timer
    systemctl daemon-reload
    # Страховка: если интерфейс когда-то умер без PostDown, правило и clamp
    # пережили бы перезапуск и тихо ломали маршрутизацию.
    ip rule del fwmark "$FWMARK" table "$WTABLE" 2>/dev/null
    iptables -t mangle -D POSTROUTING -o "$IFACE" -p tcp -m tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WMSS" 2>/dev/null
    ip link del "$IFACE" 2>/dev/null
    rm -f "$CONF" "$RP_FLAG_FILE"
    sysctl --system >/dev/null 2>&1
    rm -rf "$APP_DIR" "$STATE_DIR"
    rm -f /usr/local/bin/wgcf /usr/local/bin/remnawave-warp
    echo -e "  ${C_GRN}✔${C_RST} WARP удалён. Пакет wireguard оставлен установленным."
    echo
}

case "${1:-status}" in
    start)     systemctl start "wg-quick@${IFACE}"; sleep 1; show_status ;;
    stop)      systemctl stop "wg-quick@${IFACE}"; sleep 1; show_status ;;
    restart)   systemctl restart "wg-quick@${IFACE}"; sleep 1; show_status ;;
    rotate)    rotate_endpoint ;;
    log)       journalctl -u remnawave-warp-watchdog.service -n 50 -f ;;
    uninstall) uninstall_warp ;;
    status)    show_status ;;
    *)         echo "Использование: remnawave-warp {status|start|stop|restart|rotate|log|uninstall}"; exit 1 ;;
esac
WARPCLIEOF
  chmod 755 /usr/local/bin/remnawave-warp
  ok "CLI установлен: remnawave-warp (status | rotate | log | uninstall)"
}

# Проверка «как видит сеть сам Xray»: пинг с меткой идёт по тому же правилу,
# что и помеченный трафик ноды.
warp_verify() {
  local rp hs age ok_ping=0
  systemctl is-active --quiet "wg-quick@${WARP_IFACE}" \
    || { warn "WARP: интерфейс $WARP_IFACE не активен (journalctl -u wg-quick@$WARP_IFACE)."; return 0; }

  if ip rule show 2>/dev/null | grep -q "fwmark 0x$(printf '%x' "$WARP_FWMARK") lookup $WARP_TABLE"; then
    ok "WARP: правило fwmark $WARP_FWMARK → table $WARP_TABLE на месте"
  else
    warn "WARP: НЕТ правила fwmark $WARP_FWMARK → table $WARP_TABLE — трафик пойдёт с реального IP сервера (remnawave-warp restart)."
  fi

  rp="$(warp_rp_filter_effective)"
  if [[ "$rp" == 1 ]]; then
    warn "WARP: rp_filter=1 (strict) — обратный трафик туннеля будет теряться."
  else
    ok "WARP: rp_filter=$rp (обратный трафик проходит)"
  fi

  hs="$(wg show "$WARP_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
  if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then
    age=$(( $(date +%s) - hs ))
    ok "WARP: хэндшейк ${age}s назад"
  fi

  if have ping; then
    if ping -m "$WARP_FWMARK" -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 \
        || ping -I "$WARP_IFACE" -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
      ok_ping=1
    fi
    if (( ok_ping )); then
      ok "WARP: ICMP через туннель проходит (маршрут помеченных пакетов работает)"
    else
      warn "WARP: ICMP через туннель не проходит — проверьте: remnawave-warp status, remnawave-warp log"
    fi
  fi
  return 0
}

# Полная установка/переустановка WARP. Идемпотентна: аккаунт и состояние
# переиспользуются, поэтому повторный запуск установщика не регистрирует
# новый аккаунт в Cloudflare (там это rate-limit'ится).
warp_enable() {
  local arch
  warp_validate_settings
  arch="$(warp_arch)" \
    || die "WARP: архитектура $(uname -m) не поддерживается (нужны x86_64 или arm64)."
  [[ -d /run/systemd/system ]] \
    || die "WARP: нужен systemd (wg-quick@ и watchdog без него не работают)."

  warp_prompt_license
  warp_install_deps
  warp_install_wgcf "$arch"

  if ! warp_register; then
    if [[ -f "$WARP_CONF" ]]; then
      warn "Регистрация не удалась, но готовый $WARP_CONF есть — переиспользую его."
    else
      die "WARP: не удалось получить профиль Cloudflare. Повторите позже или с другого IP (rate-limit)."
    fi
  fi
  warp_apply_license

  # Конфиг пересобираем всегда: так применяются изменения WARP_MTU/FWMARK/TABLE
  # из повторного запуска, а endpoint получает свежий случайный адрес.
  if [[ -f "$WARP_STATE_DIR/wgcf/wgcf-profile.conf" ]]; then
    warp_render_conf "$WARP_STATE_DIR/wgcf/wgcf-profile.conf" "$WARP_CONF" \
      || die "WARP: не удалось собрать $WARP_CONF из профиля wgcf."
    ok "Конфиг туннеля записан: $WARP_CONF (MTU $WARP_MTU, table $WARP_TABLE, fwmark $WARP_FWMARK)"
  elif [[ ! -f "$WARP_CONF" ]]; then
    die "WARP: нет ни профиля wgcf, ни готового $WARP_CONF."
  fi

  warp_relax_rp_filter
  warp_write_watchdog
  warp_write_cli

  systemctl enable "wg-quick@$WARP_IFACE" >/dev/null 2>&1 || true
  if systemctl restart "wg-quick@$WARP_IFACE" >/dev/null 2>&1; then
    ok "Интерфейс $WARP_IFACE поднят"
  else
    die "WARP: интерфейс не поднялся. Смотрите: journalctl -u wg-quick@$WARP_IFACE"
  fi
  warp_wait_handshake || true
  warp_verify
}

# Демонтаж WARP (используется --uninstall и reconfigure при выключении).
warp_disable() {
  systemctl disable --now "wg-quick@$WARP_IFACE" >/dev/null 2>&1 || true
  systemctl disable --now remnawave-warp-watchdog.timer >/dev/null 2>&1 || true
  systemctl stop remnawave-warp-watchdog.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/remnawave-warp-watchdog.service \
        /etc/systemd/system/remnawave-warp-watchdog.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  ip rule del fwmark "$WARP_FWMARK" table "$WARP_TABLE" 2>/dev/null || true
  iptables -t mangle -D POSTROUTING -o "$WARP_IFACE" -p tcp -m tcp \
      --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_MSS" 2>/dev/null || true
  ip link del "$WARP_IFACE" 2>/dev/null || true
  rm -f "$WARP_CONF" "$WARP_RP_FILTER_FILE"
  rm -rf -- "$WARP_DIR" "$WARP_STATE_DIR"
  rm -f /usr/local/bin/wgcf /usr/local/bin/remnawave-warp
  if have sysctl; then
    sysctl --system >/dev/null 2>&1 || true
  fi
  ok "WARP удалён (туннель, watchdog, CLI, правило маршрутизации)"
}

# Ключ WARP+ — необязательный. Спрашиваем только в интерактивном режиме и не
# сохраняем на диск: он нужен один раз, при регистрации.
warp_prompt_license() {
  local input
  [[ -z "${WARP_LICENSE:-}" ]] || return 0
  [[ "${NONINTERACTIVE:-0}" == 1 ]] && return 0
  has_tty || return 0
  printf ' %s?%s Ключ WARP+ %s[Enter — бесплатный тариф]%s: ' \
    "${C_MAG:-}${C_B:-}" "${C_RST:-}" "${C_DIM:-}${C_GRY:-}" "${C_RST:-}" > /dev/tty
  IFS= read -r input < /dev/tty || true
  input="$(printf '%s' "$input" | tr -cd 'a-zA-Z0-9-')"
  if [[ -n "$input" ]]; then
    WARP_LICENSE="$input"
    note "Ключ WARP+ принят (не сохраняется на диск)"
  else
    note "WARP остаётся на бесплатном тарифе"
  fi
}

# Один домен/geosite-паттерн из env: нормализуем к виду «domain:…», «geosite:…»
# и т.п. Возвращает ненулевой код на мусоре, чтобы опечатка не уехала в профиль.
warp_normalize_route_item() {
  local item="$1" prefix rest
  item="${item#"${item%%[![:space:]]*}"}"
  item="${item%"${item##*[![:space:]]}"}"
  [[ -n "$item" ]] || return 1
  case "$item" in
    domain:*|full:*|geosite:*|regexp:*) prefix="${item%%:*}" ; rest="${item#*:}" ;;
    *) prefix="domain" ; rest="$item" ;;
  esac
  [[ -n "$rest" && ${#item} -le 253 ]] || return 1
  case "$prefix" in
    geosite)
      [[ "$rest" =~ ^[a-z0-9][a-z0-9!_:-]*$ ]] || return 1
      ;;
    regexp)
      # Кавычка или обратный слэш в regexp: ломают JSON профиля и сам jq-фильтр.
      case "$rest" in
        *\"*|*\\*) return 1 ;;
      esac
      [[ "$rest" =~ ^[[:print:]]+$ ]] || return 1
      ;;
    *)
      # domain/full: буквы, цифры, дефис, точки. Маска «*.» снимается: в Xray
      # `domain:foo.net` и так покрывает все поддомены, а `domain:*.foo.net`
      # матчером не понимается.
      rest="${rest#\*.}"
      [[ "$rest" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
      rest="${rest,,}"
      ;;
  esac
  printf '%s:%s' "$prefix" "$rest"
}

# Список того, что уходит через WARP: встроенные AI-сервисы + WARP_ROUTE_GEOSITE
# + WARP_ROUTE_DOMAINS (через пробел или запятую).
warp_route_domain_list() {
  local item
  local -a extra=()
  printf '%s\n' "${WARP_ROUTE_DOMAINS_DEFAULT[@]}"
  IFS=', ' read -r -a extra <<<"${WARP_ROUTE_GEOSITE//,/ }" || true
  for item in "${extra[@]}"; do
    [[ -n "$item" ]] && printf 'geosite:%s\n' "$item"
  done
  IFS=', ' read -r -a extra <<<"${WARP_ROUTE_DOMAINS//,/ }" || true
  for item in "${extra[@]}"; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

# JSON-массив паттернов для jq в multiselect_filter (без дублей).
warp_route_domains_json() {
  local raw norm out="" seen=" "
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    norm="$(warp_normalize_route_item "$raw")" || {
      warn "WARP: пропускаю некорректный паттерн маршрута «$raw» (нужно domain:…, full:…, geosite:… или домен)."
      continue
    }
    [[ "$seen" == *" $norm "* ]] && continue
    seen+="$norm "
    out+="${out:+,}\"$norm\""
  done < <(warp_route_domain_list)
  printf '[%s]' "$out"
}
