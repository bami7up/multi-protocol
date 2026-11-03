# --- Config Profile, XRAY_JSON и темы фасада ---
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

self_steal_template_list() {
  printf '%s\n' "${SELF_STEAL_TEMPLATES[@]}"
}

cdn_transport_enabled() {
  case "$CDN_TRANSPORT:$1" in
    ws:ws | xhttp:xhttp | grpc:grpc | both:ws | both:xhttp | all:ws | all:xhttp | all:grpc)
      return 0
      ;;
  esac
  return 1
}

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
     --arg minver "$REALITY_MIN_CLIENT_VER" \
     --arg xtarget "$XHTTP_TARGET" \
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
            | .streamSettings.realitySettings.minClientVer = $minver
          elif .tag == "REALITY_XHTTP" then
            .streamSettings.realitySettings.serverNames = [$xsni]
            | .streamSettings.realitySettings.minClientVer = $minver
            | .streamSettings.realitySettings.target = $xtarget
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
  local src="" tmp="" out="$NODE_DIR/Multiselect.json" out_tmp="" out_tmp2=""
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
  # Временные файлы с приватными ключами создаём через mktemp: 0600, а не
  # 0644 от обычного umask. Итоговый профиль тоже должен быть 0600.
  out_tmp="$(mktemp "$NODE_DIR/.Multiselect.XXXXXX")"
  out_tmp2="$(mktemp "$NODE_DIR/.Multiselect.XXXXXX")"
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
  if multiselect_filter < "$src" > "$out_tmp" && [[ -s "$out_tmp" ]]; then
    if jq --argjson saved "$existing_reality" '
      .inbounds |= map(
        if (.streamSettings.realitySettings? != null) and (($saved[.tag] // null) != null) then
          .streamSettings.realitySettings.privateKey = $saved[.tag].privateKey
          | if (($saved[.tag].shortIds | length) > 0) then
              .streamSettings.realitySettings.shortIds = $saved[.tag].shortIds
            else . end
        else . end
      )
    ' "$out_tmp" > "$out_tmp2" && [[ -s "$out_tmp2" ]]; then
      mv -f "$out_tmp2" "$out_tmp"
    else
      rm -f "$out_tmp2"
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
          ' "$out_tmp" > "$out_tmp2" && [[ -s "$out_tmp2" ]]; then
            mv -f "$out_tmp2" "$out_tmp"
          else
            rm -f "$out_tmp2"
          fi
        fi
      done < <(jq -r '.inbounds[]? | select(.streamSettings.realitySettings? != null) | select((.streamSettings.realitySettings.privateKey // "") == "") | .tag' "$out_tmp" 2>/dev/null || true)
    else
      warn "openssl не найден — REALITY privateKey/shortIds в $out останутся пустыми. Установите openssl и перезапустите установщик."
    fi
    install -m 600 "$out_tmp" "$out"
    rm -f "$out_tmp" "$out_tmp2" "$tmp"
    local profile_inbounds="Vision/Reality + Hysteria2"
    if (( ENABLE_XHTTP )); then
      profile_inbounds="Vision/Reality + XHTTP + Hysteria2"
    fi
    if (( ENABLE_CDN )); then
      profile_inbounds+=" + CDN ($CDN_TRANSPORT)"
    fi
    ok "Config Profile сохранён: $out ($profile_inbounds)"
  else
    rm -f "$out_tmp" "$out_tmp2" "$tmp"
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

resolve_self_steal_template() {
  # Тема фасада → URL шаблона. Явный SELF_STEAL_TEMPLATE_URL имеет приоритет
  # и отключает подстановку по теме (иначе пользователь не мог бы задать свой
  # фасад, не переименовывая тему).
  if [[ -n "$SELF_STEAL_TEMPLATE_URL" ]]; then
    [[ "$SELF_STEAL_TEMPLATE_URL" == https://* ]] \
      || die "SELF_STEAL_TEMPLATE_URL должен начинаться с https://"
    return 0
  fi
  if [[ "$SELF_STEAL_TEMPLATE" == "$SELF_STEAL_TEMPLATE_NONE" ]]; then
    # Свой сайт: шаблон не скачивается, SELF_STEAL_ROOT не трогаем. Проверка
    # непустого index.html — на шаге 7, когда каталог уже создан.
    SELF_STEAL_TEMPLATE_URL=""
    SELF_STEAL_THEME_USED=0
    return 0
  fi
  SELF_STEAL_TEMPLATE_URL="$(self_steal_template_url "$SELF_STEAL_TEMPLATE")" \
    || die "Неизвестная тема self-steal: $SELF_STEAL_TEMPLATE. Доступны: $(self_steal_template_list | tr '\n' ' '), none."
  SELF_STEAL_THEME_USED=1
}
