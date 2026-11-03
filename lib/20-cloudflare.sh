# --- Cloudflare DNS ---
cf_rand_index() {
  local n="${1:-}" raw
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  raw="$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d '[:space:]')"
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' $(( raw % n ))
}

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

cf_valid_saved_host() {
  local host="${1:-}" base="${2:-}"
  [[ -n "$host" && -n "$base" ]] || return 1
  is_fqdn "$host" && [[ "$host" == *".$base" ]]
}

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

cf_curl_cfg_init() {
  local token
  # Токен — base64/hex без пробелов и кавычек; вычищаем их, чтобы curl-config
  # не сломался и нельзя было добавить лишние директивы через перевод строки.
  token="$(printf '%s' "${CLOUDFLARE_API_TOKEN:-}" | tr -d '[:space:]"')"
  CF_CURL_CFG="$(mktemp)"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$token" > "$CF_CURL_CFG" )
}

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

cf_a_exists() {
  local resp
  resp="$(cf_api GET "/zones/$1/dns_records?type=A&name=$2")" \
    || die "Cloudflare API недоступен при проверке $2."
  cf_json_success "$resp" || die "Cloudflare API (проверка $2): $(cf_json_error "$resp")"
  [[ -n "$(jq -r '.result[0].id // empty' <<<"$resp")" ]]
}

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

CF_HOST_ADJ=(quiet brisk amber coral golden vivid mellow crisp gentle lofty lucid nimble placid rugged serene slender sturdy tranquil azure bright clever frosty misty silken snowy sober solid sunny tidy wavy warm wild windy zesty merry prime rapid calm jolly mild)
CF_HOST_NOUN=(otter lantern drift fern ridge cove beacon birch cinder clover dune ember falcon fjord flare forest garnet glade granite grove hazel heron iris jade jetty juniper kelp lagoon laurel lilac linen lotus maple mesa moss nectar nickel olive onyx orbit pebble pewter pine prairie quartz quarry raven reef rivet ruby sage shale shore sienna spruce stone thistle tide timber topaz valley velvet willow zenith zephyr)
CF_API_BASE="https://api.cloudflare.com/client/v4"
