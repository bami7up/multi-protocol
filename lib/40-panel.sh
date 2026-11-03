# --- Remnawave Panel API и авто-настройка ---
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

panel_node_tag_suffix() {
  # Стабильный короткий суффикс из адреса ноды: два сервера с одинаковым
  # PREFIX (например, оба usa) не получают одинаковый тег и не смешивают
  # injectHosts в панели. Суффикс не зависит от времени, поэтому повторный
  # запуск на той же ноде даёт тот же тег.
  local seed="${SERVER_IP:-${VLESS_HOST:-}}" sum
  [[ -n "$seed" ]] || return 0
  sum="$(printf '%s' "$seed" | sha256sum | awk '{print $1}' | cut -c1-4 | tr 'a-f' 'A-F')"
  [[ -n "$sum" ]] && printf '_%s' "$sum"
}

panel_node_tag() {
  local raw="${NODE_TAG:-}" suffix=""
  if [[ -n "$raw" ]]; then
    # Явно заданный тег — решение пользователя, не переписываем.
    :
  else
    raw="$(panel_node_slug)"
    suffix="$(panel_node_tag_suffix)"
  fi
  raw="$(printf '%s' "$raw" | tr 'a-z-' 'A-Z_' | tr -cd 'A-Z0-9_:')"
  while [[ "$raw" == _* ]]; do raw="${raw#_}"; done
  while [[ "$raw" == *_ ]]; do raw="${raw%_}"; done
  # 32 — предел тега; суффикс должен уместиться целиком.
  if [[ -n "$suffix" ]]; then
    raw="${raw:0:27}"
    while [[ "$raw" == *_ ]]; do raw="${raw%_}"; done
    raw="${raw}${suffix}"
  fi
  raw="${raw:0:32}"
  [[ -n "$raw" ]] || raw="NODE"
  printf '%s' "$raw"
}

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

panel_prepare_profile_for_api() {
  local profile_name="$1" profile_json="$2"
  local resp work_json saved_map='{}' other_tags='[]' slug suffix try_suffix n
  resp="$(panel_api_retry GET "/config-profiles" 2>/dev/null || true)"

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

panel_result_uuid() {
  local out="${1:-}" rc="${2:-1}"
  (( rc == 0 )) || return 0
  printf '%s' "$out" | tail -1 | tr -d '[:space:]'
}

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
  resp="$(panel_api_retry GET "/config-profiles" 2>/dev/null || true)"
  # Remnawave 3.x: {response:{total, configProfiles:[...]}}; старые версии — массив
  uuid="$(jq -r --arg n "$name" '
    (.response // .data // .)
    | if type=="object" and has("configProfiles") then .configProfiles
      elif type=="array" then .
      else [] end
    | .[] | select(.name==$n) | .uuid // empty' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$uuid"
}

panel_profile_node_uuids() {
  local name="$1" resp
  resp="$(panel_api_retry GET "/config-profiles" 2>/dev/null || true)"
  jq -r --arg n "$name" '
    (.response // .data // .)
    | if type=="object" and has("configProfiles") then .configProfiles
      elif type=="array" then .
      else [] end
    | .[] | select(.name==$n) | .nodes[]?.uuid // empty
  ' <<<"$resp" 2>/dev/null | paste -sd, - || true
}

panel_get_inbounds() {
  local profile_uuid="$1" resp
  resp="$(panel_api_retry GET "/config-profiles/$profile_uuid/inbounds" 2>/dev/null || true)"
  # Иногда панель отдаёт inbounds в /config-profiles/{uuid}, фолбэк
  if ! jq -e '.. | objects | has("uuid") and has("tag")' >/dev/null 2>&1 <<<"$resp"; then
    resp="$(panel_api_retry GET "/config-profiles/$profile_uuid" 2>/dev/null || true)"
  fi
  # Выводим строки uuid|tag
  jq -r '.. | objects | select(has("uuid") and has("tag")) | "\(.uuid)|\(.tag)"' <<<"$resp" 2>/dev/null | sort -u
}

panel_find_node_by_address() {
  # Дополнительные аргументы (port/name) оставлены для совместимости вызовов.
  local addr="$1" resp uuid
  resp="$(panel_api_retry GET "/nodes" 2>/dev/null || true)"
  uuid="$(jq -r --arg a "$addr" '
    ((.response // .data // .)
      | if type=="object" and has("nodes") then .nodes
        elif type=="array" then .
        else [] end)
    | [ .[]? | select(.address == $a) | .uuid // empty ]
    | map(select(length > 0))[0] // empty
  ' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$uuid"
}

panel_find_node_by_name() {
  local name="$1" resp uuid
  resp="$(panel_api_retry GET "/nodes" 2>/dev/null || true)"
  uuid="$(jq -r --arg n "$name" '
    ((.response // .data // .)
      | if type=="object" and has("nodes") then .nodes
        elif type=="array" then .
        else [] end)
    | [ .[]? | select(.name == $n) | .uuid // empty ]
    | map(select(length > 0))[0] // empty
  ' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$uuid"
}

panel_find_host_by_remark() {
  local remark="$1" resp row
  resp="$(panel_api_retry GET "/hosts" 2>/dev/null || true)"
  row="$(jq -r --arg r "$remark" '
    (.response // .data // .)
    | if type=="object" and has("hosts") then .hosts
      elif type=="array" then .
      else [] end
    | .[] | select(.remark==$r)
    | "\(.uuid)|\(.inbound.configProfileUuid // "")|\(.inbound.configProfileInboundUuid // "")|\((.tags // []) | join(","))"
  ' <<<"$resp" 2>/dev/null | head -1 || true)"
  printf '%s' "$row"
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
    # Профиль с тем же именем мог быть создан другой нодой (одинаковый PREFIX).
    # Если у профиля уже есть ноды, а на этом SERVER_IP ноды ещё нет — не PATCH,
    # иначе мы заменим чужой конфиг и сломаем его подписки.
    local profile_nodes current_node
    profile_nodes="$(panel_profile_node_uuids "$profile_name" || true)"
    current_node="$(panel_find_node_by_address "$SERVER_IP" "$NODE_API_PORT" "$(panel_node_name)" || true)"
    if [[ -n "$profile_nodes" && -z "$current_node" ]]; then
      warn "Config Profile «$profile_name» уже назначен другой ноде ($profile_nodes), а на $SERVER_IP ноды ещё нет. Не перезаписываю; задайте другой PREFIX/NODE_TAG или удалите старый профиль."
      return 2
    fi
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
  local existing_uuid resp result_uuid name_uuid
  existing_uuid="$(panel_find_node_by_address "$SERVER_IP" "$NODE_API_PORT" "$node_name" || true)"
  if [[ -z "$existing_uuid" ]]; then
    name_uuid="$(panel_find_node_by_name "$node_name" || true)"
    if [[ -n "$name_uuid" ]]; then
      warn "В панели уже есть нода «$node_name» с другим address. Не перезаписываю её; задайте другой PREFIX/NODE_TAG."
      return 2
    fi
  fi
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
      if grep -qi "already exists\|duplicate\|conflict" <<<"$(panel_api_error "$resp")"; then
        existing_uuid="$(panel_find_node_by_address "$SERVER_IP" "$NODE_API_PORT" "$node_name" || true)"
        [[ -n "$existing_uuid" ]] || existing_uuid="$(panel_find_node_by_name "$node_name" || true)"
        if [[ -n "$existing_uuid" ]]; then
          warn "Нода уже существует в панели ($existing_uuid), но создать/обновить её этим запуском не удалось: $(panel_api_error "$resp")"
          note "Проверьте ноду в панели или повторите запуск установщика."
          return 1
        fi
      fi
      warn "Не удалось создать ноду: $(panel_api_error "$resp")"
      note "Создайте вручную: Nodes → Management → + (IP $SERVER_IP, порт $NODE_API_PORT, профиль $profile_uuid)"
      return 1
    fi
  fi
  printf '%s' "$result_uuid"
}

panel_trigger_node_start() {
  local node_uuid="${1:-}"
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
  # Remnawave 3.x отвечает на этот action 202 Accepted без JSON-тела, поэтому
  # panel_api_success здесь неприменим, а panel_api_retry повторял бы POST три
  # раза (три restart-события). Достаточно одного запроса и проверки 2xx.
  panel_api POST "/nodes/$node_uuid/actions/restart" '{"forceRestart":false}' >/dev/null 2>&1 || true
  if [[ "$(panel_api_code)" =~ ^2[0-9]{2}$ ]]; then
    ok "Панель запустила синхронизацию Xray с нодой ($node_uuid)"
  fi
  return 0
}

panel_upsert_host() {
  local profile_uuid="$1" inbound_uuid="$2" remark="$3" address="$4" port="$5" extra_json="${6:-}"
  local existing_row existing_uuid existing_profile existing_inbound existing_tags resp payload result_uuid node_tag
  existing_row="$(panel_find_host_by_remark "$remark" || true)"
  IFS='|' read -r existing_uuid existing_profile existing_inbound existing_tags <<<"$existing_row"
  node_tag="$(panel_node_tag)"
  if [[ -n "$existing_uuid" ]]; then
    # Тот же remark, но другой профиль/инбаунд: если у хоста тот же NODE_TAG,
    # это та же нода после смены хоста/профиля — обновляем. Если тег другой —
    # не перезаписываем чужой хост.
    if [[ -n "$existing_profile" \
          && ( "$existing_profile" != "$profile_uuid" || "$existing_inbound" != "$inbound_uuid" ) \
          && -n "$existing_tags" \
          && ",${existing_tags}," != *",${node_tag},"* ]]; then
      warn "Хост «$remark» уже принадлежит другому профилю/инбаунду (вероятно, другой ноде) — не перезаписываю."
      return 1
    fi
  fi
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
        existing_row="$(panel_find_host_by_remark "$remark" || true)"
        existing_uuid="${existing_row%%|*}"
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
  resp="$(panel_api_retry GET "/internal-squads" 2>/dev/null || true)"
  inbounds_json="$(printf '%s\n' "${inbounds[@]}" | jq -R . | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]')"
  # Remnawave 3.x: {response:{total, internalSquads:[...]}}; старые версии — массив.
  # Берём именно Default-Squad, а не первый попавшийся: иначе inbound'ы ноды
  # попадут в чужой/платный отряд.
  squad_uuid="$(jq -r '
    (.response // .data // .)
    | if type=="object" and has("internalSquads") then .internalSquads
      elif type=="array" then .
      else [] end
    | ([ .[] | select(.name == "Default-Squad") ][0].uuid) // empty' <<<"$resp" 2>/dev/null || true)"
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
    | [ ([ .[] | select(.name == "Default-Squad") ][0].inbounds[]?
          | if type=="object" then (.uuid // empty) else . end
          | select(length > 0)) ]
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

panel_find_subscription_template_uuid() {
  local tname="$1" resp code
  resp="$(panel_api_retry GET "/subscription-templates" 2>/dev/null || true)"
  code="$(panel_api_code)"
  if ! panel_api_success "$resp" && [[ "$code" == "404" ]]; then
    resp="$(panel_api_retry GET "/templates" 2>/dev/null || true)"
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
  if (( profile_rc == 2 )); then
    return 1
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
    warn "Не удалось получить inbound'ы профиля $profile_uuid — без них нода не заработает."
    note "Проверьте панель: Config Profiles → $profile_name → inbounds"
    return 1
  fi
  ok "Профиль содержит inbound'ы: ${!INBOUND_UUID_BY_TAG[*]}"

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
    if (( node_rc == 2 )); then
      return 1
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
  local host_count=0 host_failed=0 node_tag extra
  node_tag="$(panel_node_tag)"
  if [[ -n "${INBOUND_UUID_BY_TAG[REALITY_VISION]:-}" ]]; then
    extra="$(jq -n -c --arg sni "$SELF_STEAL_HOST" --arg tag "$node_tag" '{securityLayer:"DEFAULT", sni:$sni, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[REALITY_VISION]}" "VLESS Vision $node_tag" "$VLESS_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[REALITY_XHTTP]:-}" && -n "$XHTTP_SNI" ]]; then
    extra="$(jq -n -c --arg sni "$XHTTP_SNI" --arg path "$XHTTP_PATH" --arg tag "$node_tag" '{securityLayer:"DEFAULT", sni:$sni, path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[REALITY_XHTTP]}" "VLESS XHTTP $node_tag" "$VLESS_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[HYSTERIA2]:-}" ]]; then
    extra="$(jq -n -c --arg sni "$HY_HOST" --arg tag "$node_tag" '{securityLayer:"DEFAULT", sni:$sni, alpn:"h3", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[HYSTERIA2]}" "Hysteria2 $node_tag" "$HY_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  # CDN хосты (внешний TLS терминирует CDN → securityLayer="TLS")
  if [[ -n "${INBOUND_UUID_BY_TAG[VLESS_CDN_WS]:-}" ]]; then
    extra="$(jq -n -c --arg host "$CDN_HOST" --arg path "${CDN_WS_PATH:-/api/v1/stream}" --arg tag "$node_tag" '{securityLayer:"TLS", sni:$host, host:$host, path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[VLESS_CDN_WS]}" "VLESS CDN WS $node_tag" "$CDN_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[VLESS_CDN_XHTTP]:-}" ]]; then
    extra="$(jq -n -c --arg host "$CDN_HOST" --arg path "${CDN_XHTTP_PATH:-/api/v3/sync/c1}" --arg tag "$node_tag" '{securityLayer:"TLS", sni:$host, host:$host, path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[VLESS_CDN_XHTTP]}" "VLESS CDN XHTTP $node_tag" "$CDN_HOST" "443" "$extra"; then
      host_count=$((host_count+1))
    else
      host_failed=$((host_failed+1))
    fi
  fi
  if [[ -n "${INBOUND_UUID_BY_TAG[VLESS_CDN_GRPC]:-}" ]]; then
    extra="$(jq -n -c --arg host "$CDN_HOST" --arg path "${CDN_GRPC_PATH:-/api/v4/stream}" --arg tag "$node_tag" '{securityLayer:"TLS", sni:$host, alpn:"h2", path:$path, fingerprint:"chrome", tags:[$tag], isHidden:true}')"
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[VLESS_CDN_GRPC]}" "VLESS CDN gRPC $node_tag" "$CDN_HOST" "443" "$extra"; then
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
    if panel_try_host "$profile_uuid" "${INBOUND_UUID_BY_TAG[REALITY_VISION]}" "VPN $node_tag" "$VLESS_HOST" "443" "$extra"; then
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
  # has("response")/has("data") здесь намеренно НЕ используются: 200 с
  # {"response":null,"message":"Forbidden"} — это ошибка, а не успех.
  jq -e '.response != null or .success == true or .data != null' >/dev/null 2>&1 <<<"$body"
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

panel_api_retry() {
  local tries=3 delay=5 n=1 resp code
  while :; do
    resp="$(panel_api "$@" || true)"
    code="$(panel_api_code)"
    if panel_api_success "$resp"; then
      printf '%s' "$resp"
      return 0
    fi
    # 202/204 — принято, тела может не быть вовсе. Ретраить такой запрос
    # (например restart ноды) нельзя: повтор создаст второе действие.
    if [[ "$code" == "202" || "$code" == "204" ]]; then
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

PANEL_HTTP_BODY=""
PANEL_HTTP_CODE_FILE=""
PANEL_HTTP_ERROR_FILE=""
PANEL_CONN_REASON=""
PANEL_CONN_DETAIL=""
PANEL_CONN_CODE=""
