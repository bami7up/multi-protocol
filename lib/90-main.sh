# --- main ---
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
      if ! [[ "$SSH_PORT_OVERRIDE" =~ ^[0-9]+$ ]] \
          || ! (( SSH_PORT_OVERRIDE >= 1 && SSH_PORT_OVERRIDE <= 65535 )); then
        echo "--ssh-port требует число 1–65535" >&2
        exit 2
      fi
      shift ;;
    --node-image)
      NODE_IMAGE="${2:-}"
      [[ -n "$NODE_IMAGE" ]] || { echo "--node-image требует значение" >&2; exit 2; }
      shift ;;
    --custom-core-url)
      CUSTOM_CORE_URL="${2:-}"
      [[ -n "$CUSTOM_CORE_URL" ]] || { echo "--custom-core-url требует uwuray или https:// URL" >&2; exit 2; }
      shift ;;
    --node-tag)
      NODE_TAG="${2:-}"
      [[ -n "$NODE_TAG" ]] || { echo "--node-tag требует значение (например NL1)" >&2; exit 2; }
      shift ;;
    --self-steal-template)
      SELF_STEAL_TEMPLATE_EXPLICIT=1
      SELF_STEAL_TEMPLATE="${2:-}"
      [[ -n "$SELF_STEAL_TEMPLATE" ]] || { echo "--self-steal-template требует значение (тема фасада)" >&2; exit 2; }
      shift ;;
    --min-client-ver)
      REALITY_MIN_CLIENT_VER="${2:-}"
      [[ -n "$REALITY_MIN_CLIENT_VER" ]] || { echo "--min-client-ver требует значение вида 0.0.0" >&2; exit 2; }
      shift ;;
    --xhttp-target)
      XHTTP_TARGET="${2:-}"
      [[ -n "$XHTTP_TARGET" ]] || { echo "--xhttp-target требует host:port или self" >&2; exit 2; }
      shift ;;
    --acme-method)
      ACME_METHOD="${2:-}"
      acme_method_supported "$ACME_METHOD" \
        || { echo "--acme-method принимает auto, dns или http" >&2; exit 2; }
      shift ;;
    --xray-template)
      XRAY_TEMPLATE_CHOICE="${2:-}"
      [[ -n "$XRAY_TEMPLATE_CHOICE" ]] || { echo "--xray-template требует значение (standard или split)" >&2; exit 2; }
      shift ;;
    --panel-url)
      REMNAWAVE_PANEL_URL="${2:-}"
      [[ -n "$REMNAWAVE_PANEL_URL" ]] || { echo "--panel-url требует значение" >&2; exit 2; }
      shift ;;
    --api-token)
      echo "Флаг --api-token удалён: токен виден в ps и истории. Задайте REMNAWAVE_API_TOKEN в окружении." >&2
      exit 2 ;;
    --cloudflare)    CF_MODE_SETTING=1 ;;
    --no-cloudflare) CF_MODE_SETTING=0 ;;
    --quick)         QUICK_SETUP_SETTING=1 ;;
    --advanced)      QUICK_SETUP_SETTING=0 ;;
    --uninstall)     UNINSTALL=1 ;;
    --reconfigure)   RECONFIGURE=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    --version)
      if [[ -r "$SCRIPT_DIR/VERSION" ]]; then
        printf 'multi-protocol %s\n' "$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
      elif command -v git >/dev/null 2>&1 \
          && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        printf 'multi-protocol %s\n' "$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
      else
        printf 'multi-protocol %s\n' "$SCRIPT_VERSION"
      fi
      exit 0 ;;
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









# Удаляет правила ufw с нашим комментарием (80/443 и т.п.), не трогая SSH.

# Защита от `--uninstall` с NODE_DIR=/ или /etc: удаляем только конкретные
# managed-каталоги/файлы, не корень и не системные каталоги.

# run_cmd — единственная точка выполнения деструктивных команд в --uninstall.

# Безопасное удаление только того, что создал установщик. Пакеты (Docker, Caddy,
# acme.sh, ufw) и чужие данные не удаляются — только managed-артефакты.



# Чистка за собой. На малых VPS диск ценен, а после сборки Caddy остаются
# инструменты, которые ноде не нужны: Go-тулчейн (сотни МБ), кэш сборки и
# модулей Go, xcaddy, копия собранного бинарника и build-essential с зависимостями.
# Если Caddy понадобится пересобрать, установщик скачает всё заново.
# Функция идемпотентна и безопасна при сбое: отсутствующие пути пропускаются.

# build-essential ставится только для сборки. Удаляем его, лишь если он появился
# при установке: пакет, который был в системе до нас, не трогаем.

# Финальная уборка: архивы .deb и индексы apt, неиспользуемые (dangling) образы
# Docker от прежних версий образа ноды. Работающие образы и установленные пакеты
# не затрагиваются. Индексы apt восстанавливаются через apt-get update.

# has_tty: есть ли управляющий терминал для интерактивных вопросов







# Путь, который можно подставлять в Caddyfile: абсолютный, без переводов строк,
# кавычек, фигурных скобок и обратных слэшей. Пробелы допустимы — путь в
# Caddyfile заключается в кавычки.

# ——— Cloudflare: автоматические A-записи с осмысленными случайными именами ———
# Поддомены собираются из двух словарей как «прилагательное-существительное»:
# в отличие от usa1/usa3 нумерация не выдаёт связь между записями, а четыре
# разных слова делают два хоста визуально непохожими друг на друга.

# Индекс [0, n) из криптографически случайных байтов (не $RANDOM).

# N случайных hex-символов из /dev/urandom — суффиксы случайных путей
# транспортов в быстром режиме (путь не должен быть одинаковым у всех нод).

# Случайный API-подобный путь вида <префикс>/<8 hex> для транспортов.

# Уникальный CDN-поддомен для каждой ноды: cdn-<6 hex>.<базовый домен>.
# Поддомен первого уровня (*.example.com) покрывается бесплатным Universal SSL
# Cloudflare (в отличие от <rand>.cdn.example.com, требующего платный ACM) и не
# конфликтует при размещении нескольких нод на одном базовом домене.

# Случайный порт Node API для быстрого режима: диапазон 11000–59999 не
# пересекается с портами схемы (80/443/9443/9444/10443–10448), а SSH-порт
# дополнительно исключается, если его удалось определить.

# Приводит короткую ссылку на образ (например, «latest» или «3.1.1», в т. ч.
# из старых env-файлов) к полному репозиторию remnawave/node:<тег>. Без слэша
# Docker ищет library/<имя> в Docker Hub и падает с
# «pull access denied for latest, repository does not exist».

# Домен, как его вводят люди (https://Example.COM/, www.example.com.),
# приводим к чистому виду example.com: без схемы, www, путей, порта и
# хвостовой точки. Валидацию не делаем — её выполнит is_fqdn у вызывающего.

# URL панели приводим к виду https://panel.example.com: схему добавляем,
# если её нет (панель почти всегда за HTTPS), хвостовой слэш срезаем.
# Возврат 1 — из ввода нельзя получить осмысленный URL.

# Хост из URL панели (без схемы, порта и пути) — чтобы определить IP панели.

# Первый IPv4 хоста по DNS (сам IPv4 возвращается как есть): дефолт для
# PANEL_IP, чтобы пользователь не вводил адрес панели второй раз.

# Два непохожих хоста «прилагательное-существительное.BASE_DOMAIN»:
# прилагательные и существительные не повторяются, поэтому хосты различаются
# в обеих частях. В stdout — ровно две строки.

# Сохранённый в прошлый раз хост переиспользуем, только если он валиден и лежит
# в текущем BASE_DOMAIN: при смене базового домена старые имена бессмысленны.

# cf_api METHOD PATH [JSON-ТЕЛО] → JSON в stdout. Токен уходит не в argv, а
# через файл конфигурации curl (-K), поэтому его не видно в ps и в логе.


# Токен не должен попадать ни в argv curl (видно в ps), ни в лог: он живёт
# во временном файле 0600, который curl читает через -K.

# Проверяет, что Cloudflare API принимает токен и видит зону BASE_DOMAIN.
# Возвращает 0 при успехе, 1 при ошибке API/токена и 2 если зона не найдена.

# cf_upsert_a ZONE_ID HOST [proxied] — создать A-запись или обновить
# существующую на текущий SERVER_IP. По умолчанию запись DNS-only
# (proxied=false): оранжевое облако ломает и REALITY, и прямой Hysteria2
# (см. README, Cloudflare и DNS-only записи). Исключение — CDN-хост: там
# проксирование и есть весь смысл, поэтому для него передаётся «proxied».

# cf_a_exists ZONE_ID HOST → 0, если A-запись уже есть (иначе 1; die при ошибке API).

# Точка входа CF-режима: токен → зона → либо переиспользуем сохранённые хосты
# (идемпотентный повторный запуск), либо генерируем свободные случайные —
# и только потом создаём/обновляем обе A-записи и ждём их в DNS.

# cf_zone_id_for_host HOST → id зоны в stdout (пустая строка и возврат 1,
# если токен не видит ни одной подходящей зоны или API недоступен). Зону
# ищем суффиксами хоста от длинного к короткому: для cdn.sub.example.com
# спрашиваем sub.example.com, затем example.com. Явный CLOUDFLARE_ZONE,
# накрывающий хост, спрашиваем первым.

# Точка входа для CDN-хоста: проксируемая A-запись (оранжевое облако)
# через Cloudflare API. Намеренно НЕ зависит от CF_MODE: режим авто-ДНС
# блока 1 отвечает только за случайные хосты VLESS/Hysteria2, а CDN
# включается позже (блок 3) и токен там спрашивают отдельно. Раньше
# создание записи гейтилось на CF_MODE, поэтому при ответе «n» в блоке 1
# CDN-домен молча не создавался вообще, хотя токен для DNS-01 был введён.
# Исходы без создания (--no-cloudflare, нет токена, токен не видит зону)
# не останавливают установку, но обязаны быть громкими: CDN_DNS_MANAGED
# остаётся "manual" и показывается в сводке как действие для пользователя.

# ——— self-steal: темы фасада ———
# Имя темы → URL шаблона в репозитории. Пустая тема означает, что пользователь
# задал SELF_STEAL_TEMPLATE_URL явно: свой фасад всегда важнее темы.
# Возвращает 1 на неизвестной теме — вызывающая сторона сама решает, как
# сообщить об этом (важно показать список доступных тем).

# Доступные темы — для подсказки об опечатке и для тестов (чтобы они не
# зависели от внутреннего массива с темами).

# CDN_TRANSPORT → включённые транспорты CDN. "both" (ws + xhttp) оставлен для
# совместимости со старыми env-файлами, "all" — все три транспорта. Функцию
# используют и промпты, и фильтр профиля, поэтому она вынесена отдельно.
# Вызывается как cdn_transport_enabled ws|xhttp|grpc; комментарий не пишется
# в строку с `{`: юнит-тест извлекает функцию по шаблону "скобка в конце строки".

# ——— Config Profile (Multiselect.json) ———
# Панель отдаёт ноде серверный конфиг Xray из Config Profile, поэтому установщик
# сохраняет готовый файл: с подставленными хостами и без inbound'а XHTTP, когда
# XHTTP в selfsteal выключен. Иначе профиль разошёлся бы с Caddyfile и нода
# слушала бы порт 10444, к которому ничего не маршрутизируется.
#
# multiselect_filter — чистый фильтр: JSON шаблона на stdin, адаптированный JSON
# в stdout. Значения берутся из переменных установщика, поэтому функцию целиком
# покрывает tests/installer-funcs-checks.sh (на шаблоне из репозитория).



# ——— Авто-настройка панели через API (если выбран REMNAWAVE_AUTO_SETUP) ———
# Короткий детерминированный идентификатор текущей ноды (из VLESS_HOST или PREFIX).

# Уникальный тег балансировки скрытых хостов этой ноды (формат Remnawave 3.x:
# ^[A-Z0-9_:]{1,36}$). У каждой ноды свой тег и свой XRAY_JSON шаблон, чтобы
# подписка не смешивала хосты разных нод под общим тегом «USA».

# Имя Config Profile: API разрешает только буквы, цифры, пробелы, «_» и «-»
# (точки из домена запрещены), длина 2–30 символов. Без штампа даты: повторный
# запуск в другой день обязан находить и обновлять профиль этой же ноды, а не
# плодить дубликаты и натыкаться на уникальность тегов inbound'ов в БД панели.

# Имя ноды в панели (3–30 символов, уникально в таблице nodes).

# Возвращает каноническое базовое имя тега inbound'а независимо от суффикса ноды
# (например, REALITY_VISION_QUIET_OTTER → REALITY_VISION).

# Подготавливает JSON Config Profile для отправки в Panel API:
#  1) переиспользует существующие REALITY privateKey/shortIds и теги этой же ноды;
#  2) гарантирует непустой X25519 privateKey + shortIds у всех REALITY inbound'ов
#     (панель Remnawave не генерирует ключи на сервере — с пустым privateKey Xray
#     не поднимает слушатели и подписка не выдаёт pbk);
#  3) обходит глобальный @@unique([tag]) в таблице config_profile_inbounds: если
#     базовый тег уже занят другим профилем в панели (вторая нода или старый
#     профиль), добавляет к тегам детерминированный суффикс текущей ноды.

# Результат функции, которая печатает диагностику (ok/warn) и лишь последней
# строкой — значение. Подоболочка $(...) смешивает их, поэтому значение берём
# ТОЛЬКО при успешном коде возврата: иначе текст предупреждения
# («▲ Не удалось создать…») стал бы uuid профиля и ушёл в URL запросов.

# panel_fetch_node_secret — получить SECRET_KEY ноды через Remnawave Panel API (GET /keygen).
# В Remnawave 3.x поле называется secretKey, в старых 2.x — pubKey.
# Возвращает чистый base64 ключ или пустую строку при ошибке.

# Обёртка для panel_upsert_host: в успешном случае молчим (функция печатает
# uuid в stdout — в консоли он не нужен), при ошибке показываем диагностику
# целиком и возвращаем ненулевой код, чтобы вызывающий её посчитал.


# UUID нод, уже привязанных к профилю. Нужен, чтобы не перезаписывать профиль,
# который принадлежит другой ноде (например, при случайно одинаковом PREFIX).


# Ищет ноду только по address. Раньше сюда подмешивался поиск по имени: при
# одинаковом PREFIX у двух нод вторая находила первую и PATCH-ем меняла ей
# address/port/profile. Имя проверяется отдельно в panel_upsert_node.


# Возвращает uuid|profileUuid|inboundUuid — этого достаточно, чтобы отличить
# «тот же хост, обновляем адрес» от «такой же remark у другой ноды».



# Инициирует немедленный запуск/синхронизацию Xray на ноде после старта контейнера
# remnanode (POST /nodes/{uuid}/actions/restart с {"forceRestart":false}), чтобы
# панель сразу отправила конфиг Xray и подняла слушатели к шагу 10.



# Шаблоны в репозитории комментированы (JSON5), а Panel API принимает только
# строгий JSON. Убираем //-комментарии вне строк и висячие запятые перед }/].
# Важно: используем print с пустым ORS вместо printf "%s%s" — в mawk на
# Debian/Ubuntu буфер sprintf ограничен 8192 байтами и обнуляет Xray_template_split.json.






# ask_secret — как ask, но значение не печатается никогда: секреты не попадают
# ни на экран, ни в установочный лог (например SECRET_KEY ноды).

# parse_bool [значение] [дефолт] → 0|1 в stdout. Логические переменные приходят
# из трёх источников: интерактивного ответа, переменных окружения и сохранённого
# /root/remnanode.env (установщик прежних версий писал туда «1»), поэтому все
# распространённые написания должны пониматься одинаково, а мусор — не выключать
# функцию молча: вызывающий сам решает, что делать (см. ask_bool).

# bool_yn 0|1 → y|n: так флаги записываются в /root/remnanode.env, чтобы файл
# читался человеком и одинаково понимался любым парсером (y* → включено).

# ask_bool VAR PROMPT DEFAULT(y/n) — вопрос с нормализацией ответа к 0/1.
# Непонятный ответ переспрашивается (или останавливает установку в
# --non-interactive), а не трактуется как «нет»: иначе опечатка тихо выключала бы
# CDN или XHTTP.

# Флаги авто-режимов приходят и из env (например, ASSUME_YES=y в CI): приводим их
# к 0/1 тем же разбором, что и остальные логические переменные. Флаг командной
# строки главнее: -y/--yes уже выставил 1 выше, и нормализация это не отменит.
ASSUME_YES="$(parse_bool "${ASSUME_YES:-0}" 0)"
NONINTERACTIVE="$(parse_bool "${NONINTERACTIVE:-0}" 0)"
KEEP_BUILD_TOOLS="$(parse_bool "${KEEP_BUILD_TOOLS:-0}" 0)"
DRY_RUN="$(parse_bool "${DRY_RUN:-0}" 0)"
if (( DRY_RUN )) && (( ! UNINSTALL )); then
  die "--dry-run сейчас поддерживается только вместе с --uninstall."
fi

# confirm "вопрос" "дефолт(y/n)" -> 0 если да, 1 если нет; уважает --yes/--non-interactive

# ask_choice VAR PROMPT DEFAULT_NUM "вариант1: описание" "вариант2: описание" ...
# Понятный выбор из списка для обычного пользователя — нумерованное меню.

# ——— Remnawave Panel API: автоматическая настройка ———

# panel_api вызывают из $(...), а переменные, выставленные в подоболочке, до
# вызывающего не доходят. Поэтому HTTP-код и ошибку curl храним в файлах:
# иначе panel_api_success всегда видел пустой код и ЛЮБОЙ ответ панели считал
# ошибкой — даже 200 с валидным токеном («не удалось подключиться»).

# Пути берутся из приватного каталога PANEL_STATE_DIR: его создаёт
# родительская оболочка, а подоболочки $(...) наследуют путь. Поэтому HTTP-код,
# записанный внутри panel_api, читается вызывающим.




# Тело ответа — в stdout, HTTP-код — в PANEL_HTTP_CODE_FILE,
# ошибка транспорта curl — в PANEL_HTTP_ERROR_FILE.



# Причина неудачной проверки — для понятной подсказки в мастере.


# Человеческое объяснение к PANEL_CONN_REASON: 401 — токен, 403 — права,
# 404 — адрес, 000 — сеть, 2xx без JSON — Cloudflare/страница входа.

# Повтор с бэкофом для сетевых сбоев панели (000/5xx/429)


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


trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT

RECONFIGURE="$(parse_bool "${RECONFIGURE:-0}" 0)"
if (( RECONFIGURE )); then
  run_reconfigure
  exit 0
fi

if (( UNINSTALL )); then
  uninstall_node
  exit 0
fi

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
# psmisc нужен для fuser в apt_wait; openssl — для X25519-ключей REALITY (шаг 1
# пишет Config Profile до основного блока пакетов шага 3); iproute2 — для ss.
retry 3 5 apt_get install -y curl ca-certificates dnsutils jq psmisc openssl iproute2 logrotate \
  || die "Не удалось установить базовые утилиты (curl, jq, openssl, iproute2, logrotate)."

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

# Новые настройки нормализуются после загрузки ENV_STORE: сохранённое значение
# должно побеждать дефолт, а явный флаг — сохранённое.
if ! REALITY_MIN_CLIENT_VER="$(normalize_client_version "${REALITY_MIN_CLIENT_VER:-0.0.0}")"; then
  die "REALITY_MIN_CLIENT_VER/--min-client-ver: нужен вид 0.0.0 (три числа), получено «${REALITY_MIN_CLIENT_VER:-}»."
fi
if ! XHTTP_TARGET="$(normalize_xhttp_target "${XHTTP_TARGET:-}")"; then
  die "XHTTP_TARGET/--xhttp-target: нужен host:port или self, получено «${XHTTP_TARGET:-}»."
fi
if ! CUSTOM_CORE_URL="$(normalize_custom_core_url "${CUSTOM_CORE_URL:-}")"; then
  die "CUSTOM_CORE_URL/--custom-core-url: нужен uwuray или https:// URL бинарника, получено «${CUSTOM_CORE_URL:-}»."
fi
if [[ -n "$CUSTOM_CORE_URL" ]]; then
  warn "Включён кастомный Xray-core: $CUSTOM_CORE_URL"
  warn "Это сторонний бинарник, который Remnawave Node скачает при старте. Для продакшена закрепите конкретный release URL."
fi
if is_xhttp_target_local; then
  warn "XHTTP_TARGET=$XHTTP_TARGET (локальный self-steal) — экспериментальный режим:"
  warn "Caddy добавит loopback-сайт для XHTTP_SNI; проверьте XHTTP на стенде (Xray-core #5923)."
fi
if ! is_safe_path "${SELF_STEAL_ROOT:-}" || ! is_safe_remove_path "${SELF_STEAL_ROOT:-}"; then
  die "SELF_STEAL_ROOT должен быть отдельным абсолютным каталогом (например /var/www/remnanode-self-steal): «${SELF_STEAL_ROOT:-}»."
fi
if ! is_safe_path "${XRAY_LOG_DIR:-}" || ! is_safe_remove_path "${XRAY_LOG_DIR:-}"; then
  die "XRAY_LOG_DIR должен быть отдельным абсолютным каталогом (например /var/log/remnanode/xray): «${XRAY_LOG_DIR:-}»."
fi
if ! acme_method_supported "$ACME_METHOD"; then
  die "ACME_METHOD/--acme-method: допустимо auto, dns или http, получено «$ACME_METHOD»."
fi

# Короткое объяснение для новичка: что сейчас будет.
if has_tty; then
{
  printf '\n'
  printf ' %s%s Добро пожаловать в мастер установки! %s\n' "${C_B:-}${C_CYN:-}" "${C_RST:-}" ""
  printf ' %sБыстрый режим задаст всего 8 вопросов; расширенный — все настройки по блокам.%s\n' "${C_DIM:-}${C_GRY:-}" "${C_RST:-}"
  printf ' %sЕсли не знаете что ответить — жмите Enter для значения по умолчанию.%s\n' "${C_DIM:-}${C_GRY:-}" "${C_RST:-}"
  printf '\n'
} > /dev/tty 2>/dev/null || true
fi

# Цвета могут быть не определены в тестах — задаём пустые значения чтобы set -u не падал
: "${C_B:=}" "${C_CYN:=}" "${C_GRN:=}" "${C_RST:=}" "${C_DIM:=}" "${C_GRY:=}" "${C_MAG:=}" "${C_BLU:=}" "${C_YLW:=}" "${C_RED:=}" "${C_WHT:=}"
resolve_server_ip

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
    "quick: Быстрая автоустановка — всего 8 вопросов (домен, токены, панель, CDN, XHTTP target), остальное автоматически (рекомендуется)" \
    "advanced: Расширенная настройка — все вопросы по блокам, полный ручной контроль"
  if [[ "$SETUP_MODE" == "quick" ]]; then QUICK_SETUP=1; else QUICK_SETUP=0; fi
fi
if (( QUICK_SETUP )); then
  [[ "$CF_MODE_SETTING" != "0" ]] \
    || die "Быстрый режим требует Cloudflare (поддомены и CDN создаются через API): уберите --no-cloudflare или запустите с --advanced."
  ok "Режим: быстрая автоустановка — спрошу домен, токен Cloudflare, домен/IP/токен панели, шаблон и транспорт CDN"
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
if (( ENABLE_XHTTP )) && is_xhttp_target_local && [[ "${XHTTP_SNI:-}" == "$SELF_STEAL_HOST" ]]; then
  warn "XHTTP_SNI совпадает с self-steal доменом: Caddy L4 уводит этот SNI в Vision, XHTTP не заработает. Задайте отдельный XHTTP_SNI."
fi

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
  # Определяем дефолтный номер для меню: vaultdrop=1, mail=2, cloud=3, admin=4,
  # docs=5, none=6 (свой сайт).
  __default_theme_num=1
  if [[ "$SELF_STEAL_TEMPLATE" == "$SELF_STEAL_TEMPLATE_NONE" ]]; then
    __default_theme_num=6
  fi
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
    "docs: Документация — сайт с документацией" \
    "none: Свой сайт — не устанавливать шаблон; положите index.html в $SELF_STEAL_ROOT"
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
  note "  • VLESS за CDN — прячет TCP-маршрут VLESS за Cloudflare/аналогами (Hysteria2 остаётся прямой)"
fi
: "${C_B:=}" "${C_CYN:=}" "${C_RST:=}" "${C_DIM:=}" "${C_GRY:=}" "${C_MAG:=}"
prompt_flags

# Кастомный Xray-core. Спрашиваем только в расширенном режиме: в быстром
# оставляем штатный Xray из образа, но env/--custom-core-url всё равно работают.
if (( ! QUICK_SETUP )); then
  __core_choice="official"
  __core_default=1
  if [[ -n "${CUSTOM_CORE_URL:-}" ]]; then
    __core_choice="custom"
    __core_default=3
    if [[ "$CUSTOM_CORE_URL" == "$(uwuray_core_url 2>/dev/null || true)" ]]; then
      __core_choice="uwuray"
      __core_default=2
    fi
  fi
  ask_choice __core_choice "Xray-core для ноды" "$__core_default" \
    "official: Штатный Xray из образа remnawave/node (рекомендуется)" \
    "uwuray: UwURay (MakostaDev/UwURay) — форк с расширенным sniffing и опциями REALITY" \
    "custom: Свой https:// URL на бинарник Xray"
  case "$__core_choice" in
    uwuray)
      CUSTOM_CORE_URL="$(uwuray_core_url)" \
        || die "UwURay не поддерживает архитектуру $(uname -m)."
      warn "UwURay: используется mutable URL latest — для продакшена закрепите конкретный release."
      ;;
    custom)
      ask CUSTOM_CORE_URL "URL бинарника Xray (https://...)" "${CUSTOM_CORE_URL:-}"
      CUSTOM_CORE_URL="$(normalize_custom_core_url "$CUSTOM_CORE_URL")" \
        || die "URL должен начинаться с https:// и не содержать пробелов/кавычек/#."
      ;;
    *)
      CUSTOM_CORE_URL=""
      ;;
  esac
  unset __core_choice __core_default
fi

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
      warn "Некорректный URL панели — нужен https://panel.example.com без пути (http:// допустим только для localhost/приватного адреса)."
      ask REMNAWAVE_PANEL_URL "Введите домен панели ещё раз" ""
    else
      die "Некорректный домен панели «$REMNAWAVE_PANEL_URL»: нужен URL вида https://panel.example.com (https:// можно не писать — добавится сам; http:// — только для localhost/приватного адреса; слэш в конце допустим, а путь — нет)."
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
        warn "Некорректный URL панели — нужен https://panel.example.com без пути (http:// допустим только для localhost/приватного адреса)."
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
if is_reserved_node_port "$NODE_API_PORT"; then
  die "Node API port $NODE_API_PORT занят этой схемой; выберите другой, например 2222."
fi
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
resolve_self_steal_template
# Шаблон профиля может содержать REALITY privateKey — только HTTPS, иначе MITM
# подменит ключи. SELF_STEAL_RAW_BASE используется для Xray-шаблона: тоже HTTPS.
[[ "$MULTISELECT_TEMPLATE_URL" == https://* ]] \
  || die "MULTISELECT_TEMPLATE_URL должен начинаться с https://"
[[ "$SELF_STEAL_RAW_BASE" == https://* ]] \
  || die "SELF_STEAL_RAW_BASE должен начинаться с https://"
is_safe_path "$CERT_DIR" \
  || die "Некорректный CERT_DIR: $CERT_DIR (нужен абсолютный путь без кавычек/скобок/переводов строк)."
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

write_env_store
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
if [[ "$SELF_STEAL_TEMPLATE" == "$SELF_STEAL_TEMPLATE_NONE" && -z "${SELF_STEAL_TEMPLATE_URL:-}" ]]; then
  kv "Фасад"         "свой сайт (none): $SELF_STEAL_ROOT"
elif (( SELF_STEAL_THEME_USED )); then
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
                   ufw psmisc iproute2 \
  || die "Не удалось установить базовые пакеты."

DOCKER_RESTART_REQUIRED=0
if ! have docker; then
  DOCKER_INSTALL_TMP="$(mktemp)"
  retry 3 10 curl -fsSL "$DOCKER_INSTALL_URL" -o "$DOCKER_INSTALL_TMP" \
    || die "Не удалось скачать Docker install script ($DOCKER_INSTALL_URL)."
  printf '%s  %s\n' "$DOCKER_INSTALL_SHA256" "$DOCKER_INSTALL_TMP" | sha256sum -c - >/dev/null \
    || die "SHA256 Docker install script не совпал — установка Docker остановлена."
  retry 3 10 sh "$DOCKER_INSTALL_TMP" \
    || die "Docker install script завершился с ошибкой."
  rm -f "$DOCKER_INSTALL_TMP"
  DOCKER_INSTALL_TMP=""
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


# Ранний fail-fast: если 443/tcp уже держит посторонний процесс (nginx,
# apache…), Caddy не сможет занять порт — об этом лучше сказать до
# многоминутной сборки, а не после неё.

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
  # acme.sh --install копирует ./acme.sh из текущего каталога, поэтому кладём
  # проверенный файл в отдельный каталог и запускаем его оттуда.
  ACME_INSTALL_DIR="$(mktemp -d)"
  ACME_INSTALL_TMP="$ACME_INSTALL_DIR/acme.sh"
  retry 3 10 curl -fsSL "$ACME_INSTALL_URL" -o "$ACME_INSTALL_TMP" \
    || die "Не удалось скачать acme.sh ($ACME_INSTALL_URL)."
  printf '%s  %s\n' "$ACME_INSTALL_SHA256" "$ACME_INSTALL_TMP" | sha256sum -c - >/dev/null \
    || die "SHA256 acme.sh не совпал — установка acme.sh остановлена."
  ( cd "$ACME_INSTALL_DIR" && retry 3 10 sh ./acme.sh --install -m "$ACME_EMAIL" ) \
    || die "Не удалось установить acme.sh."
  rm -rf -- "$ACME_INSTALL_DIR"
  ACME_INSTALL_DIR=""
  ACME_INSTALL_TMP=""
fi
ACME=/root/.acme.sh/acme.sh
[[ -x "$ACME" ]] || die "acme.sh не найден по пути $ACME."
if [[ "$ACME_AUTO_UPGRADE" == 1 ]]; then
  "$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
else
  note "acme.sh закреплён; автообновление выключено (ACME_AUTO_UPGRADE=1 — обновлять из upstream)."
fi
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

# Сколько дней осталось у уже выпущенного сертификата acme.sh; возвращает 1,
# если файла нет или он нечитаем. Без этой проверки повторный запуск «пропускал»
# бы выпуск, и просроченный сертификат продолжал бы работать до ручного
# вмешательства. ACME_HOME переопределяется в tests/installer-funcs-checks.sh.


# Сертификат для CDN-хоста: HTTP-01 здесь невозможен — за прокси на :80 отвечает
# сам CDN, а не наша нода. Поэтому DNS-01 (`dns_cf`) тем же токеном Cloudflare.
# acme.sh сохраняет креденшелы DNS-API в конфиг сертификата, поэтому cron
# обновляет его так же, как остальные.

ACME_METHOD_USED="$(acme_method_resolved)"
if [[ "$ACME_METHOD_USED" == "dns" ]]; then
  ok "ACME: DNS-01 для self-steal и Hysteria2 (продление без остановки Caddy)"
else
  warn "ACME: HTTP-01 — при первом выпуске и продлении Caddy кратко останавливается, 443/tcp может прерваться."
  warn "Чтобы убрать простой, задайте Cloudflare-токен и ACME_METHOD=auto (или dns)."
fi

issue_cert_selected "$SELF_STEAL_HOST" || die "Без сертификата $SELF_STEAL_HOST настоящий self-steal невозможен."
issue_cert_selected "$HY_HOST" || die "Не удалось подготовить обязательный сертификат Hysteria2."
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
  --reloadcmd "systemctl restart caddy >/dev/null 2>&1 || true" \
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
    --reloadcmd "systemctl restart caddy >/dev/null 2>&1 || true" \
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
mkdir -p "$SELF_STEAL_ROOT"
if [[ "$SELF_STEAL_TEMPLATE" == "$SELF_STEAL_TEMPLATE_NONE" && -z "${SELF_STEAL_TEMPLATE_URL:-}" ]]; then
  # Свой сайт: ничего не скачиваем и не перезаписываем. Пустой каталог ухудшает
  # маскировку (Caddy ответит 404), поэтому предупреждаем громко.
  if [[ -s "$SELF_STEAL_ROOT/index.html" ]]; then
    ok "Шаблон не устанавливался (none): используется свой сайт $SELF_STEAL_ROOT/index.html"
  else
    warn "SELF_STEAL_TEMPLATE=none, но $SELF_STEAL_ROOT/index.html отсутствует или пуст."
    warn "Положите туда свой index.html до запуска сканеров: иначе на self-steal domain будет 404."
  fi
else
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
fi

cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup-$(date +%F-%H%M%S)" 2>/dev/null || true
prune_matching_files /etc/caddy 'Caddyfile.backup-*' 5
render_caddyfile

caddy fmt --overwrite "$CADDYFILE_PATH" || warn "caddy fmt не удался — продолжаю."
caddy validate --config "$CADDYFILE_PATH" || die "Caddyfile невалиден — исправьте SNI/синтаксис."
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

# Логи Xray: если образ пишет файл, он окажется на хосте и будет ротироваться.
# stdout по-прежнему ограничен Docker log-opts (50m × 5).
mkdir -p "$XRAY_LOG_DIR"
chmod 755 "$XRAY_LOG_DIR" 2>/dev/null || true

if [[ "$BUILD_COMPOSE" -eq 1 ]]; then
  ( umask 077
    cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_API_PORT
SECRET_KEY=$SECRET_VALUE
NODE_IMAGE=$NODE_IMAGE
XRAY_LOG_DIR=$XRAY_LOG_DIR
CUSTOM_CORE_URL=$CUSTOM_CORE_URL
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
    image: ${NODE_IMAGE:-remnawave/node:3.4.4}
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
      - CUSTOM_CORE_URL=${CUSTOM_CORE_URL:-}
    volumes:
      - /etc/remna-certs:/etc/remna-certs:ro
      - ${XRAY_LOG_DIR:-/var/log/remnanode/xray}:/var/log/xray
EOF
  ok "Записаны $NODE_DIR/.env (0600) и docker-compose.yml"
else
  [[ -f "$NODE_DIR/docker-compose.yml" ]] || die "--no-compose, но $NODE_DIR/docker-compose.yml отсутствует."
  ( umask 077
    {
      echo "NODE_PORT=$NODE_API_PORT"
      echo "SECRET_KEY=$SECRET_VALUE"
      echo "NODE_IMAGE=$NODE_IMAGE"
      echo "XRAY_LOG_DIR=$XRAY_LOG_DIR"
      echo "CUSTOM_CORE_URL=$CUSTOM_CORE_URL"
    } > "$NODE_DIR/.env"
  )
  chmod 600 "$NODE_DIR/.env"
  ok "Обновлён $NODE_DIR/.env (compose оставлен как есть)"
fi

# Ротация файловых логов Xray. Если образ пишет только в stdout, каталог пуст
# и logrotate ничего не делает; Docker-драйвер уже ограничивает stdout.
if [[ -d /etc/logrotate.d ]]; then
  cat > /etc/logrotate.d/remnanode-xray <<EOF
$XRAY_LOG_DIR/*.log {
  size 50M
  rotate 5
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF
  chmod 644 /etc/logrotate.d/remnanode-xray
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
if [[ -n "${CUSTOM_CORE_URL:-}" ]]; then
  kv "Xray core"     "кастомный: $CUSTOM_CORE_URL"
else
  kv "Xray core"     "штатный из образа"
fi
kv "REALITY"        "minClientVer=$REALITY_MIN_CLIENT_VER, XHTTP target=$XHTTP_TARGET"
if [[ "$ACME_METHOD_USED" == "dns" ]]; then
  kv "ACME"          "DNS-01 (продление без остановки Caddy)"
else
  kv "ACME"          "HTTP-01 (краткий простой 443/tcp при продлении)"
fi
kv "Логи Xray"      "stdout: docker logs; файлы: $XRAY_LOG_DIR (logrotate 50M×5)"
echo
if (( SELF_STEAL_THEME_USED )); then
  kv "Тема фасада"    "$SELF_STEAL_TEMPLATE"
fi
kv "Config Profile" "$NODE_DIR/Multiselect.json  (вставьте в панели → Config Profiles)"
kv "Шаблон XRAY"    "$NODE_DIR/Xray_template.json  ($XRAY_TEMPLATE_CHOICE, тег $(panel_node_tag))"
kv "Лог установки"   "$LOG_FILE"
kv "Логи ноды"       "docker logs remnanode --tail 120"
kv "Логи Xray"      "docker logs remnanode --tail 120; файлы: $XRAY_LOG_DIR/*.log"
kv "Статус Caddy"    "systemctl status caddy --no-pager"
kv "Firewall"        "ufw status numbered"
echo
