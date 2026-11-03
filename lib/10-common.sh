# --- общие утилиты, ввод, валидаторы ---
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
      go_sha=ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5
      ;;
    aarch64|arm64)
      go_arch=arm64
      go_sha=3f4227ce7b206a513e794f1393adb473a07b46e94d18bd15d1c684bbb7319797
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

cleanup_system_leftovers() {
  apt_get clean >/dev/null 2>&1 || true
  rm -rf -- /var/lib/apt/lists/* 2>/dev/null || true
  if have docker && docker info >/dev/null 2>&1; then
    docker image prune -f >/dev/null 2>&1 || true
  fi
  ok "Очистка завершена. Свободно на /: $(df -Pm / | awk 'NR==2{print $4}' 2>/dev/null || echo '?') МБ"
}

have() { command -v "$1" >/dev/null 2>&1; }

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

is_private_ipv6() {
  # ::1, link-local (fe80::/10) и ULA (fc00::/7): такие адреса панели можно
  # использовать по HTTP, не отправляя токен в публичную сеть.
  local ip="${1:-}"
  [[ "$ip" == "::1" || "$ip" == fe80:* || "$ip" == fc* || "$ip" == fd* ]]
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

is_safe_path() {
  local p="${1:-}"
  [[ "$p" == /* && "$p" != *$'\n'* && "$p" != *$'\r'* \
      && "$p" != *'"'* && "$p" != *'{'* && "$p" != *'}'* ]] || return 1
  # Обратный слэш перед закрывающей кавычкой Caddyfile экранировал бы её.
  case "$p" in *\\*) return 1 ;; esac
  return 0
}

is_client_version() {
  # Xray сравнивает minClientVer как три числовых компонента (x.y.z).
  [[ "${1:-}" =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$ ]]
}

normalize_client_version() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr -d '[:space:]')"
  if [[ -z "$v" ]]; then
    printf '%s' "0.0.0"
  elif is_client_version "$v"; then
    printf '%s' "$v"
  else
    return 1
  fi
}

is_host_port() {
  local hp="${1:-}" host port
  [[ "$hp" == *:* && "$hp" != *" "* ]] || return 1
  host="${hp%:*}"
  port="${hp##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1
  if [[ "$host" == \[*\] ]]; then
    is_ipv6 "${host:1:${#host}-2}"
  elif [[ "$host" =~ ^[0-9.]+$ ]]; then
    is_ipv4 "$host"
  else
    is_fqdn "$host"
  fi
}

normalize_xhttp_target() {
  local target="${1:-}" port="${SELF_STEAL_TLS_PORT:-9443}"
  target="$(printf '%s' "$target" | tr -d '[:space:]')"
  if [[ -z "$target" ]]; then
    printf '%s' "www.gstatic.com:443"
    return 0
  fi
  if [[ "$target" == "self" || "$target" == "local" ]]; then
    printf '127.0.0.1:%s' "$port"
    return 0
  fi
  if ! is_host_port "$target"; then
    return 1
  fi
  printf '%s' "$target"
}

is_xhttp_target_local() {
  case "${XHTTP_TARGET:-}" in
    127.0.0.1:* | localhost:* | "[::1]:"*) return 0 ;;
  esac
  return 1
}

acme_method_supported() {
  case "${1:-}" in auto|dns|http) return 0 ;; esac
  return 1
}

acme_method_resolved() {
  # auto: DNS-01, если есть Cloudflare-токен (он уже проверен и сохранён),
  # иначе HTTP-01. Явные dns/http не переопределяются.
  case "${ACME_METHOD:-auto}" in
    dns) printf 'dns' ;;
    http) printf 'http' ;;
    *)
      if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        printf 'dns'
      else
        printf 'http'
      fi
      ;;
  esac
}


random_hex() {
  local n="${1:-8}" bytes hex
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  bytes=$(( (n + 1) / 2 ))
  hex="$(od -An -N"$bytes" -tx1 </dev/urandom 2>/dev/null | tr -d '[:space:]')"
  [[ "$hex" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s' "${hex:0:$n}"
}

gen_random_api_path() {
  local prefix="${1:-/api/v3/sync}" suffix
  suffix="$(random_hex 8)" || return 1
  printf '%s/%s' "$prefix" "$suffix"
}

gen_cdn_host() {
  local base="${1:-${BASE_DOMAIN:-}}" suffix=""
  [[ -n "$base" ]] || return 1
  suffix="$(random_hex 6 2>/dev/null || true)"
  [[ -n "$suffix" ]] || suffix="node01"
  printf 'cdn-%s.%s' "$suffix" "$base"
}

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

normalize_node_image() {
  local img="${1:-}"
  img="$(printf '%s' "$img" | tr -d '[:space:]')"
  if [[ -z "$img" ]]; then
    printf 'remnawave/node:3.4.4'
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

uwuray_core_url() {
  case "$(uname -m)" in
    x86_64|amd64)        printf 'https://github.com/MakostaDev/UwURay/releases/latest/download/Xray-linux-64' ;;
    aarch64|arm64|armv8) printf 'https://github.com/MakostaDev/UwURay/releases/latest/download/Xray-linux-arm64-v8a' ;;
    *) return 1 ;;
  esac
}

normalize_custom_core_url() {
  local u="${1:-}"
  u="$(printf '%s' "$u" | tr -d '\r\n')"
  case "$u" in
    ""|none|official|off) printf '' ;;
    uwuray|uwuray-latest) uwuray_core_url ;;
    https://*)
      # URL попадает в .env/Node env: без пробелов, кавычек и решётки.
      if [[ "$u" == *[[:space:]]* || "$u" == *'"'* || "$u" == *"'"* || "$u" == *#* ]]; then
        return 1
      fi
      printf '%s' "$u"
      ;;
    *) return 1 ;;
  esac
}

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

normalize_panel_url() {
  local u="${1:-}" rest host port scheme has_port=0
  u="$(printf '%s' "$u" | tr -d '[:space:]')"
  [[ -n "$u" ]] || return 1
  # Схему сравниваем без учёта регистра и нормализуем обратно в нижний.
  case "${u,,}" in
    http://*)  scheme=http;  u="http://${u#*://}" ;;
    https://*) scheme=https; u="https://${u#*://}" ;;
    *://*) return 1 ;;
    *) scheme=https; u="https://$u" ;;
  esac
  u="${u%/}"
  rest="${u#*://}"
  # Разрешён только origin без пути: иначе запросы API пойдут по неверному URL.
  [[ "$rest" != */* ]] || return 1
  if [[ "$rest" == \[* ]]; then
    host="${rest%%]*}"
    host="${host#\[}"
    is_ipv6 "$host" || return 1
    local after="${rest#*]}"
    if [[ -n "$after" ]]; then
      [[ "$after" == :* ]] || return 1
      port="${after#:}"
      has_port=1
    fi
  else
    host="${rest%%/*}"
    if [[ "$host" == *:* ]]; then
      port="${host#*:}"
      host="${host%%:*}"
      has_port=1
    fi
    { is_fqdn "$host" || is_ipv4 "$host" || [[ "$host" == "localhost" ]]; } || return 1
  fi
  if (( has_port )); then
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
  fi
  # HTTP допустим только до локальной/приватной панели: иначе Bearer-токен
  # уйдёт по открытой сети. Для публичного адреса — только HTTPS.
  if [[ "$scheme" == http ]] \
      && ! { is_private_ipv4 "$host" || is_private_ipv6 "$host" || [[ "$host" == "localhost" ]]; }; then
    return 1
  fi
  printf '%s' "$u"
}

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

parse_bool() {
  local val="${1:-}" def="${2:-0}"
  case "${val,,}" in
    1|y|yes|true|on)  printf '1' ;;
    0|n|no|false|off) printf '0' ;;
    *)                printf '%s' "$def" ;;
  esac
}

bool_yn() {
  if [[ "${1:-0}" == 1 ]]; then
    printf 'y'
  else
    printf 'n'
  fi
}

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
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || port=22
  printf '%s' "$port"
}

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
  if [[ -n "${DOCKER_INSTALL_TMP:-}" && -f "$DOCKER_INSTALL_TMP" ]]; then
    rm -f -- "$DOCKER_INSTALL_TMP"
  fi
  if [[ -n "${ACME_INSTALL_DIR:-}" && -d "$ACME_INSTALL_DIR" ]]; then
    rm -rf -- "$ACME_INSTALL_DIR"
  elif [[ -n "${ACME_INSTALL_TMP:-}" && -f "$ACME_INSTALL_TMP" ]]; then
    rm -f -- "$ACME_INSTALL_TMP"
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

resolve_server_ip() {
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
elif [[ -n "${SERVER_IP:-}" ]]; then
  # Опечатка/IPv6 в env: не тащим мусор в env-файл и DNS-сравнение.
  warn "SERVER_IP=$SERVER_IP не является IPv4 — игнорирую и определяю автоматически."
  SERVER_IP=""
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
}

is_reserved_node_port() {
  case "$1" in
    80|443|9443|10443|10444|"$CDN_TLS_PORT"|"$CDN_WS_PORT"|"$CDN_XHTTP_PORT"|"$CDN_GRPC_PORT") return 0 ;;
  esac
  return 1
}
