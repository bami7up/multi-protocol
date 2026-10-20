# Multi-protocol Remnawave Node

Нода Remnawave с четырьмя протоколами на одном порту `443/tcp` + отдельный `443/udp`:

- **VLESS Reality/Vision** с локальным self-steal (маскируется под свой же сайт);
- **VLESS XHTTP + Reality** (современный транспорт);
- **Hysteria2** (QUIC на `443/udp`);
- **VLESS за CDN** (опционально, прячет IP за Cloudflare).

Caddy L4 на `443/tcp` раскладывает соединения по SNI, на `80/tcp` отдаёт 301 на HTTPS, Hysteria2 идёт напрямую. Сканер, открывший ваш домен в браузере, видит обычный сайт-фасад, а не заглушку.

> Форма входа на фасадном сайте декоративная — данные никуда не отправляются.

---

## Выберите способ установки

| Способ | Кому подходит | Что делает установщик |
|---|---|---|
| **[Автоустановка](#-автоустановка-рекомендуется)** | Есть домен в Cloudflare и доступ к панели Remnawave | Сам создаёт поддомены, выпускает сертификаты, создаёт Config Profile, ноду, хосты, squad и шаблон подписки через API — без ручных шагов 1–8 |
| **[Ручная установка](#-ручная-установка-пошагово)** | Нет Cloudflare или хотите всё контролировать вручную | Вы создаёте DNS и записи в панели по инструкции, установщик ставит только ноду |

Оба способа ставят одну и ту же схему — разница только в том, сколько шагов вы делаете руками.

> **Совместимость:** Panel `3.0.x–3.2.x`, Node `3.0.0–3.1.1`, Xray-core `v26.7.28`. Проверено 13 августа 2026. `smux`/`brutal` не нужны.

---

## ⚡ Автоустановка (рекомендуется)

### Что это и зачем

Обычная установка требует 8 ручных шагов в панели. Автоустановка убирает самые скучные:

- **Авто-домены:** вместо ручного создания `usa1.example.com`/`usa3.example.com` установщик сам заводит в Cloudflare две случайные записи вида `quiet-otter.example.com` / `brisk-lantern.example.com` (DNS only, без прокси). **Куда:** Cloudflare → DNS вашей зоны. **Зачем:** имена не пересекаются, не нужно лезть в DNS, сертификаты сразу совпадают с записями.
- **Авто-панель:** если дадите URL панели и API-токен, установщик через Remnawave API создаст всё нужное: Config Profile (`POST /api/config-profiles`), ноду (`POST /api/nodes` с `activeConfigProfileUuid` и всеми inbound'ами), хосты (`POST /api/hosts` по одному на каждый inbound — Vision, XHTTP, Hysteria2 + CDN), включит inbound'ы в Internal Squad и загрузит шаблон подписки (`POST /api/subscription-templates`). **Куда:** Remnawave → Config Profiles / Nodes / Hosts / Squads / Templates. **Зачем:** не делать 8 ручных шагов, нода сразу `Online` с готовыми хостами. Повторный запуск идемпотентен (находит по имени/remark и делает `PATCH` вместо дубля).
- **Авто-шаблоны:** выбор темы фасада и шаблона подписки (`standard` — весь трафик через VPN, `split` — только RU/частные через VPN) прямо в мастере. **Куда:** `$NODE_DIR/Multiselect.json` и `$NODE_DIR/Xray_template.json` + загрузка в панель. **Зачем:** не искать файлы в репозитории — шаблон сразу в Templates.

### Что нужно заранее

1. **Домен в Cloudflare** (например `example.com`), NS зоны — на Cloudflare.
2. **Cloudflare API Token** с правами `Zone:Zone:Read` + `Zone:DNS:Edit` на вашу зону. Создаётся: Cloudflare → My Profile → API Tokens → Create Token (привяжите к конкретной зоне, не глобальный ключ). **Куда:** понадобится установщику для A-записей и DNS-01 сертификата CDN. **Зачем:** без токена нельзя автоматически завести DNS.
3. **Remnawave Panel 3.x** и её **API токен**: Panel → Settings → API Tokens → Create. Нужны права на **чтение и запись** для `config-profiles`, `nodes`, `hosts`, `internal-squads` — проще всего выдать `config-profiles:*`, `nodes:*`, `hosts:*`, `internal-squads:*` (или полный доступ `*`). Только `:write` недостаточно: проверка соединения и поиск существующих объектов читают эти разделы, и панель ответит `403`. **Куда:** панель. **Зачем:** чтобы установщик мог создать профиль без вашего участия. Можно пропустить — тогда сделаете руками по [ручной инструкции](#-ручная-установка-пошагово).
4. **Сервер ноды:** Debian 11/12 или Ubuntu 20.04+, `amd64`/`arm64`, root, 1 ГБ RAM, 3 ГБ диска, публичный IPv4.

### Запуск

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh -o remnanode-setup.sh
less remnanode-setup.sh   # просмотрите, если хотите
bash remnanode-setup.sh
```

Короткий вариант:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh)
```

### Что спросит мастер

Первым делом мастер спросит **режим установки** (пропускается флагами `--quick`/`--advanced` или env `QUICK_SETUP=y/n`; выбор сохраняется в `/root/remnanode.env`):

- **Быстрая автоустановка (рекомендуется)** — всего **5 вводов**, остальное установщик выбирает сам — меньше действий, меньше ошибок:
  1. `Базовый домен` — просто домен без `https://`, `www` и слэшей (например `example.com`); вставленный «как из браузера» вид (`https://Example.COM/`) установщик сам приведёт к чистому.
  2. `Cloudflare API Token` (скрытый ввод) — после этого поддомены VLESS/Hysteria2 создадутся сами со случайными именами, а CDN-домен `cdn.<ваш домен>` — с проксируемой записью.
  3. `Домен панели` — **полным URL с `https://`**: правильно `https://panel.example.com` и `https://panel.example.com/` — хвостовой слэш срезается автоматически. Можно ввести просто `panel.example.com` — `https://` добавится сам. Неправильно — с путём: `panel.example.com/login`.
  4. `API токен панели` (скрытый ввод) — соединение сразу проверяется. Длина токена (например, 228 символов у JWT) роли не играет; важен только выданный набор прав.
  5. `IP сервера панели` для firewall — обычно уже подставлен автоматически (определяется по домену панели), остаётся нажать Enter. Если панель за Cloudflare-прокси, мастер предупредит: нужен реальный IP сервера, а не IP Cloudflare.

  Автоматически и без вопросов: XHTTP включён (SNI `www.gstatic.com`), пути транспортов XHTTP/CDN — случайные, CDN включён (`cdn.<домен>`, транспорт `ws`, запись создаёт сам установщик), тема фасада на свежей установке — случайная из пяти, шаблон подписки — `standard`, **порт ноды — случайный** из диапазона 11000–59999 (показывается в сводке и сохраняется; повторный запуск порт, пути и тему не меняет). `SECRET_KEY` ноды установщик получает сам через API панели (`GET /keygen`), а затем связывает ноду, хосты и шаблон подписки — без ручного ввода ключа.
- **Расширенная настройка** — прежние 4 блока с полным ручным контролем (ниже). Нужна, если нет Cloudflare, поддомены создаёте вручную или хотите свои пути/транспорт CDN/шаблон `split`.

**Расширенный режим — 4 блока:**

Мастер специально разбит на блоки простым языком — отвечаете `y`/`n` или выбираете номер:

**Блок 1/4 — Домены и DNS:**
- `Базовый домен` — например `example.com` (ваш домен в Cloudflare).
- `Создавать поддомены автоматически через Cloudflare?` — `y` (рекомендуется) или `n` (ручной режим). **Зачем:** в авто-режиме не нужно создавать `usa1`/`usa3` руками.
- При `y` — `Cloudflare API Token` (ввод скрыт). При `n` — `Префикс поддомена` (например `usa`) → получите `usa1.example.com` / `usa3.example.com`.
- `Домен self-steal для Vision/Reality` — обычно совпадает с VLESS-доменом (маскирует REALITY под свой сайт).

**Блок 2/4 — Шаблоны:**
- `Выберите тему маскировочного сайта` — меню 1–5: `vaultdrop` (файлообменник, по умолчанию), `mail` (почта), `cloud` (облако), `admin` (консоль), `docs` (документация). **Куда:** ставится в `/var/www/remnanode-self-steal/index.html`. **Зачем:** сканер видит правдоподобный сайт.
- `Выберите шаблон подписки` — `standard` (весь трафик через VPN, для обхода блокировок) или `split` (только RU/частные через VPN, экономия трафика). **Куда:** `$NODE_DIR/Xray_template.json`. **Зачем:** определяет, что уйдёт в VPN у клиента.

**Блок 3/4 — Протоколы:**
- `Включить XHTTP?` — `y` (рекомендуется, современный транспорт) → спросит маскировочный `SNI` (`www.gstatic.com`) и `путь` (`/api/v3/sync/r1`).
- `Добавить VLESS за CDN?` — `y`/`n`. При `y` — `CDN_HOST` (например `cdn.example.com` под оранжевым облаком), `транспорт` (`ws`/`xhttp`/`grpc`/`both`/`all`) и пути. **Куда:** отдельный SNI-маршрут Caddy `127.0.0.1:9444` → `10446–10448`. **Зачем:** прячет IP ноды за CDN.

**Блок 4/4 — Панель Remnawave:**
- `IP панели` и `Порт ноды` (обычно `2222`) — нужны для UFW (открыть `NODE_PORT` только с IP панели). **Куда:** firewall ноды.
- `Настроить панель автоматически через Remnawave API?` — `y`/`n`. При `y` — `URL панели` (`https://panel.example.com`, слэш в конце допустим) и `API токен` (скрытый ввод). Нужны права на **чтение и запись**: `config-profiles`, `nodes`, `hosts`, `internal-squads` (например, `config-profiles:*`, `nodes:*`, `hosts:*`, `internal-squads:*`). Мастер проверит соединение и после установки ноды полностью настроит панель: создаст/обновит Config Profile, ноду, хосты, squad и шаблон подписки.

После блоков мастер покажет сводку (`SERVER_IP`, `VLESS`, `HYSTERIA2`, `SELF_STEAL`, `Фасад`, `XHTTP`, `CDN`, `DNS`, `Авто-панель`) и спросит `Всё верно, продолжаем?`.

Дальше идут автоматические шаги 2–10 (DNS-проверка, Docker, Caddy, сертификаты, firewall, нода, проверки) — без вопросов.

### Что получите

- A-записи в Cloudflare (DNS only, кроме CDN — proxied).
- Сертификаты в `/etc/remna-certs/<домен>/` (автопродление через `acme.sh` cron).
- **Чистка за собой:** после сборки Caddy удаляются Go-тулчейн, кэши сборки и модулей Go, `xcaddy`, `build-essential` (если его поставил установщик), а в конце — архивы `.deb` и индексы apt и неиспользуемые (dangling) образы Docker. Работающие сервисы не затрагиваются, а `build-essential` удаляется только если установщик поставил его сам. Если Caddy понадобится пересобрать, инструменты установщик скачает заново; чтобы оставить их, запустите с `--keep-build-tools` или `KEEP_BUILD_TOOLS=y`.
- `Caddyfile` с L4-маршрутами и локальными сайтами `127.0.0.1:9443` (self-steal) и `127.0.0.1:9444` (CDN).
- `docker-compose.yml` в `/opt/remnanode` и ноду `remnanode` (host network).
- `Multiselect.json` и `Xray_template.json` в `/opt/remnanode`.
- **В панели (при авто-режиме):** Config Profile (`multi-example.com-YYYYMMDD`), нода (`node-usa-example.com` → `SERVER_IP:<порт ноды>`; в быстром режиме порт случайный и показывается в сводке мастера, в расширенном по умолчанию `2222`), хосты по каждому inbound (Vision/XHTTP/Hysteria2/CDN, `Hide ON`, `Tag USA`, `Port 443`), Internal Squad с включёнными inbound'ами, шаблон подписки. Нода сразу `Online` — без ручных шагов 1–8. Повторный запуск обновляет существующие объекты, не дублируя.

Ручной режим: проверьте `Online` в **Nodes → Management** и продолжите с [шага 5 ручной инструкции](#шаг-5-создайте-рабочие-хосты) (хосты, virtual host, squad, клиент). В авто-режиме эти шаги уже выполнены — проверьте хосты и выдайте подписку пользователю.

### Неинтерактивный вариант (CI)

Все ответы можно задать env:

```bash
BASE_DOMAIN=example.com \
CLOUDFLARE_API_TOKEN=xxxx \
CLOUDFLARE_ZONE=example.com \
SELF_STEAL_TEMPLATE=mail \
XRAY_TEMPLATE_CHOICE=split \
ENABLE_XHTTP=y XHTTP_SNI=www.gstatic.com XHTTP_PATH=/api/v3/sync/r1 \
ENABLE_CDN=y CDN_HOST=cdn.example.com CDN_TRANSPORT=ws \
REMNAWAVE_PANEL_URL=https://panel.example.com REMNAWAVE_API_TOKEN=xxxx REMNAWAVE_AUTO_SETUP=y \
PANEL_IP=203.0.113.10 NODE_API_PORT=2222 SECRET_KEY='eyJ...' \
bash remnanode-setup.sh --non-interactive --yes --cloudflare
```

Тот же быстрый режим без вопросов (`--quick`): нужны только домен, токены и панель — пути, CDN-домен и поддомены выберутся автоматически (`PANEL_IP` можно не задавать, если домен панели резолвится в её реальный IP). `NODE_API_PORT` здесь зафиксирован тем портом, с которым нода уже создана в панели ради `SECRET_KEY`; без него порт сгенерируется случайно и сохранится для повторных запусков:

```bash
BASE_DOMAIN=example.com \
CLOUDFLARE_API_TOKEN=xxxx \
REMNAWAVE_PANEL_URL=https://panel.example.com REMNAWAVE_API_TOKEN=xxxx \
NODE_API_PORT=2222 SECRET_KEY='eyJ...' \
bash remnanode-setup.sh --quick --non-interactive --yes
```

Для воспроизводимости зафиксируйте образ: `NODE_IMAGE=remnawave/node:3.1.1`.

> **Безопасность токенов:** `CLOUDFLARE_API_TOKEN` и `REMNAWAVE_API_TOKEN` сохраняются в `/root/remnanode.env` (0600) для идемпотентного повторного запуска — ограничьте доступ к файлу и ротируйте токены при утечке. В логе `/var/log/remnanode-setup-*.log` токены не пишутся (ввод скрыт).

---

## 🔧 Ручная установка (пошагово)

Если нет Cloudflare или не хотите давать токены — делайте всё руками. Каждый шаг имеет **Куда** (где настраивать) и **Зачем** (что это даёт).

### Шаг 0. Требования и подготовка

**Куда:** ваш компьютер / панель управления доменом.
**Зачем:** без выполненных требований установщик упрётся в DNS или firewall.

- **Сервер ноды:** Debian 11/12 / Ubuntu 20.04+, `amd64`/`arm64`, root, 1 ГБ RAM, 3 ГБ диска.
- **Панель:** Remnawave 3.x, публичный IPv4 ноды + IP панели.
- **Домены:** минимум две A-записи на IP ноды, без AAAA (Hysteria2 — только IPv4):

| A-запись | Назначение | Куда создать |
|---|---|---|
| `usa1.example.com` | Reality/Vision self-steal | DNS-провайдер → A на IP ноды |
| `usa3.example.com` | Hysteria2 TLS | туда же |

> [!IMPORTANT]
> Протокольные записи — всегда **DNS only** (серое облако, если DNS в Cloudflare). Оранжевое облако ломает REALITY и Hysteria2 (только UDP). Исключение — CDN-домен (см. [VLESS за CDN](#vless-за-cdn-cloudflare)).

- **Порты:** `80/tcp`, `443/tcp`, `443/udp` открыты из интернета; `2222/tcp` (Node Port) — только с IP панели.
- **Токен Cloudflare** (опционально): для [авто-DNS](#cloudflare-создание-поддоменов-автоматически) (`usa1`/`usa3`) и для CDN (DNS-01 сертификат). Права `Zone:Zone:Read` + `Zone:DNS:Edit` на зону.
- **Выбор конфигурации:** XHTTP (`ENABLE_XHTTP=y`), CDN (`ENABLE_CDN=n`), тема фасада (`vaultdrop`), шаблон (`Xray_template.json`).

Логические env `ENABLE_XHTTP`/`ENABLE_CDN`/`REMNAWAVE_AUTO_SETUP` понимают `y/yes/1/true/on` и `n/no/0/false/off`.

### Шаг 1. Создайте серверный Config Profile

**Куда:** Remnawave → **Config Profiles → Create Config Profile**.
**Зачем:** панель отдаёт этот JSON ноде как конфиг Xray — без него нода не знает, какие inbound'ы слушать.

Установщик сохраняет готовый профиль в `$NODE_DIR/Multiselect.json` (уже с вашими хостами, SNI, путём XHTTP и путями сертификатов). Если делаете до установки — возьмите `Multiselect.json` из репозитория и замените плейсхолдеры:

| Плейсхолдер | Пример |
|---|---|
| `<prefix>1.<domain>` | `usa1.example.com` |
| `<prefix>3.<domain>` | `usa3.example.com` |

В авто-режиме Cloudflare хосты уже сгенерированы (`quiet-otter.example.com`) — они подставлены и печатаются в конце установки.

Проверьте inbound'ы:

| Tag | Listen | Port | Критичное |
|---|---|---:|---|
| `REALITY_VISION` | `127.0.0.1` | `10443` | `target: 127.0.0.1:9443`, `minClientVer: "0.0.0"`, self-steal в `serverNames` |
| `REALITY_XHTTP` | `127.0.0.1` | `10444` | внешний SNI, `minClientVer` |
| `HYSTERIA2` | `0.0.0.0` | `443/udp` | сертификат Hysteria2 |

С CDN (`ENABLE_CDN=y`) добавится `VLESS_CDN_WS`/`XHTTP`/`GRPC` на `10446–10448` без TLS (`security: none`), пути совпадают с Caddy.

`privateKey`, `shortIds`, `clients` — оставляет панель.

### Шаг 2. Создайте ноду

**Куда:** **Nodes → Management → +**.
**Зачем:** связывает панель и сервер ноды; панель даёт `SECRET_KEY` для аутентификации ноды.

1. IP ноды, Node Port (например `2222`).
2. Скопируйте `SECRET_KEY`.
3. Выберите Config Profile из шага 1.
4. Включите все inbound'ы профиля и сохраните (2 без XHTTP, 3 с XHTTP, + CDN при `ENABLE_CDN=y`).

Compose от панели запускать не нужно — установщик создаст свой.

### Шаг 3. Запустите установщик на ноде

**Куда:** SSH на сервер ноды от `root`.
**Зачем:** ставит Docker, Caddy L4, сертификаты, UFW, ноду — всё, что нужно для приёма трафика.

Рекомендуется просмотреть скрипт:

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh -o remnanode-setup.sh
less remnanode-setup.sh
bash remnanode-setup.sh
```

Коротко:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh)
```

В начале мастера выберите **расширенный режим** (или запустите с `--advanced`) — он задаст 4 блока вопросов (см. автоустановку выше); быстрый режим рассчитан на Cloudflare и авто-панель. Ответы сохранятся в `/root/remnanode.env` (0600) и подхватятся в `.bashrc`.

Неинтерактивно — см. [Неинтерактивный запуск](#неинтерактивный-запуск).

### Шаг 4. Проверьте статус ноды

**Куда:** **Nodes → Management** в панели.
**Зачем:** если нода не `Online`, проблема в `SECRET_KEY`/порту/UFW, а не в хостах/шаблонах.

### Шаг 5. Создайте рабочие хосты

**Куда:** **Hosts** → +.
**Зачем:** хост = адрес, который видит клиент; он наследует порт/протокол inbound'а, но его `Address`/`Port` можно переопределить на публичные.

Создайте по хосту на каждый inbound, тег `USA`, **Hide host ON**:

| Inbound | Address | Port (публичный) | Tag | Hide |
|---|---|---:|---|---|
| `REALITY_VISION` | `usa1.example.com` | `443` | `USA` | ON |
| `REALITY_XHTTP` | `usa1.example.com` | `443` | `USA` | ON |
| `HYSTERIA2` | `usa3.example.com` | `443` | `USA` | ON |

- Порт `443` вручную — `10443–10444` локальные.
- В Cloudflare-режиме Address — сгенерированные хосты.
- XHTTP-хост — тот же `path` и SNI, что в профиле.
- Без XHTTP (`ENABLE_XHTTP=n`) — только 2 хоста.
- С CDN — по хосту на каждый `VLESS_CDN_*`: Address=`CDN_HOST` (`cdn.example.com`), Port=`443`, SNI=`cdn.example.com`, Security layer `TLS`, Tag `USA`, Hide ON (подробнее [VLESS за CDN](#vless-за-cdn-cloudflare)).

### Шаг 6. Создайте XRAY_JSON-шаблон

**Куда:** **Templates → XRAY_JSON**.
**Зачем:** из шаблона панель собирает подписку для клиента (балансер, routing, DNS).

Вставьте `Xray_template.json` (или `Xray_template_split.json` для [split-routing](#опциональный-split-routing)). Если тег не `USA`, замените в `routing.balancers[].tag` и `remnawave.injectHosts[].selector.pattern`. `tagPrefix: "proxy"` и `selector: ["proxy"]` должны совпадать.

### Шаг 7. Создайте виртуальный хост

**Куда:** **Hosts** → + (видимый).
**Зачем:** это оболочка для XRAY_JSON-шаблона — без него шаблон не попадёт в подписку.

| Поле | Значение | Зачем |
|---|---|---|
| Inbound | любой inbound профиля | хост должен быть привязан к inbound'у |
| Address | `usa1.example.com` | валидный адрес, виден в подписке |
| Port | `443` | публичный порт |
| Tag | пусто | не участвует в балансировке |
| Видимость | ON | чтобы подписка его видела |
| Hide host | OFF | видимый |
| XRAY_JSON template | шаблон из шага 6 | подключает логику клиента |

Итого: 3 скрытых + 1 видимый (плюс CDN-хосты при `ENABLE_CDN=y`).

### Шаг 8. Добавьте inbound'ы в Internal Squad

**Куда:** **Internal Squads**.
**Зачем:** squad — выключатель: даже если inbound есть в профиле, без включения в squad пользователи не получат его хосты.

Включите все inbound'ы, к которым привязаны хосты из шагов 5 и 7 (включая CDN при `ENABLE_CDN=y`).

### Шаг 9. Подключите клиент

**Куда:** клиент (v2rayNG, Hiddify, Streisand, Mihomo).
**Зачем:** проверить, что всё работает end-to-end.

1. Возьмите подписку пользователя в панели и импортируйте.
2. Появятся скрытые хосты — выбирайте любой (Reality напрямую, CDN через CDN). Балансер `USA` раскидывает по `proxy`, `proxy-2`...

Если хостов нет/один — проверьте Hide host, тег, Internal Squad (шаги 5,7,8).

### Проверка после установки

**Куда:** SSH ноды.
**Зачем:** убедиться, что все слушатели и сертификаты на месте.

```bash
docker ps --filter name=remnanode
docker logs remnanode --tail 120
docker exec -it remnanode tail -f /var/log/xray/current
systemctl status caddy --no-pager
ss -lntup | grep -E ':80|:443|:9443|:9444|:10443|:10444|:10446|:10447|:10448'
ufw status numbered
```

Редирект и HSTS:

```bash
curl -sI "http://usa1.example.com/probe/path?x=1" | head -3
curl -s -D - -o /dev/null "https://usa1.example.com/" | grep -i strict-transport-security
```

Должно: `301` → `Location: https://usa1.example.com/probe/path?x=1`, HSTS `max-age=31536000`.

Self-steal:

```bash
echo | openssl s_client -connect 127.0.0.1:9443 -servername usa1.example.com -verify_return_error -brief
```

В браузере `https://usa1.example.com/` — фасад с валидным сертификатом.

CDN (при `ENABLE_CDN=y`):

```bash
echo | openssl s_client -connect 127.0.0.1:9444 -servername cdn.example.com -brief
curl -sI "https://cdn.example.com/" | head -3
curl -s -o /dev/null -w '%{http_code}\n' "https://cdn.example.com/api/v1/stream"
```

Итог: `Online`, `443/tcp` — Caddy, `443/udp` — Hysteria2, `10443–10448` на `127.0.0.1`, в XRAY_JSON `proxy`, `proxy-2`, `proxy-3` (+ CDN).

---

## Файлы репозитория и куда их загружать

Это два типа шаблонов — не меняйте местами.

| Файл | Куда в Remnawave 3.x | Назначение |
|---|---|---|
| `Multiselect.json` | **Config Profiles → Create Config Profile** (шаг 1) | Серверный конфиг Xray; установщик сохраняет готовую копию в `$NODE_DIR/Multiselect.json` |
| `Xray_template.json` | **Templates → XRAY_JSON** (шаг 6) | Клиентская подписка full-tunnel |
| `Xray_template_split.json` | **Templates → XRAY_JSON** (опция) | Split-routing: часть через VPN |
| `remnanode-setup.sh` | Запуск от `root` на ноде (шаг 3) | Docker, Caddy L4, сертификаты, UFW, Node |
| `self-steal-templates/*.html` | В панель не загружается | Темы фасада (`vaultdrop`, `mail`, `cloud`, `admin`, `docs`) |

Служебные: `tests/` (проверки), `.github/workflows/validate.yml` (CI), `LICENSE`, `SECURITY.md`, `AUDIT.md`.

## Как это устроено

### Схема портов

| Публичный вход | SNI | Локальный получатель | Зачем |
|---|---|---|---|
| `443/tcp` | self-steal-домен | Vision `127.0.0.1:10443` | Reality крадёт handshake у своего сайта |
| `443/tcp` | внешний XHTTP SNI | XHTTP `127.0.0.1:10444` | современный транспорт |
| `443/tcp` | CDN-домен (`ENABLE_CDN=y`) | origin `127.0.0.1:9444` → `10446–10448` | CDN → Caddy → Xray |
| `443/tcp` | любой другой SNI | сайт `127.0.0.1:9443` | фасад для сканеров |
| `443/udp` | Hysteria2-домен | Hysteria2 в Node | QUIC |
| `80/tcp` | self-steal | 301 на HTTPS | для HTTP-01 |

Vision `target: 127.0.0.1:9443` — REALITY использует свой TLS-сайт. XHTTP — с внешним target (известная проблема Xray-core [#5923](https://github.com/XTLS/Xray-core/issues/5923)). CDN — отдельный TLS-сайт `127.0.0.1:9444` (только loopback).

### Маскировочный сайт

На `127.0.0.1:9443` (и `:80`) — фасад: сканер видит сайт, а не заглушку. Тема выбирается в блоке 2/4 мастера, список — [ниже](#фасад-self-steal-темы).

---

## VLESS за CDN (Cloudflare)

**Куда:** Cloudflare (оранжевое облако) + Caddy на ноде + Xray inbound'ы.
**Зачем:** прячет IP ноды, даёт запасной маршрут при блокировке прямого IP. Клиент → `https://cdn.example.com` (TLS) → CDN → `:443` ноды (TLS origin) → Caddy L4 → Xray.

```text
клиент → https://cdn.example.com → CDN → :443 ноды (сертификат CDN-хоста)
                               └→ Caddy L4 (SNI) → 127.0.0.1:9444
                  ├─ /api/v1/stream → Xray 10446 (ws, без TLS)
                  ├─ /api/v3/sync/c1 → Xray 10447 (xhttp, без TLS)
                  ├─ /api/v4/stream → Xray 10448 (grpc h2c)
                  └─ прочее → фасад
```

Адаптировано из `braydos-h/vless-ws-cdn-tunnel-setup`, `wpdevelopment11/xray-tutorial`, обсуждение XTLS [#5423](https://github.com/XTLS/Xray-core/discussions/5423).

| Транспорт | `CDN_TRANSPORT` | Inbound | Путь по умолчанию |
|---|---|---|---|
| WebSocket | `ws` | `VLESS_CDN_WS` `10446` | `/api/v1/stream` |
| XHTTP | `xhttp` | `VLESS_CDN_XHTTP` `10447` | `/api/v3/sync/c1` |
| gRPC | `grpc` | `VLESS_CDN_GRPC` `10448` | `/api/v4/stream` |
| ws+xhttp | `both` | оба | как выше |
| все три | `all` | все три | как выше |

**Что нужно заранее (куда и зачем):**

- Отдельный поддомен `cdn.example.com` с A **под оранжевым облаком** (proxied) — **куда:** Cloudflare DNS. **Зачем:** только proxied гонит трафик через CDN (для протокольных — серое).
- Не совпадает с self-steal/Hysteria2/XHTTP SNI — проверка в установщике.
- Токен `Zone:Read`+`Zone:DNS:Edit` — **куда:** Cloudflare API. **Зачем:** для A-записи CDN (если `--cloudflare`) и DNS-01 сертификата origin (HTTP-01 не дойдёт — на `:80` отвечает CDN).
- Между CDN и origin — **Full (strict)**: Caddy отвечает валидным сертификатом CDN-хоста.
- CDN должен поддерживать транспорт: WS и HTTP/2 (для gRPC) у Cloudflare включены, порты только `443`.

**Запуск:** мастер спросит `Добавить VLESS за CDN?` → домен, транспорт, пути. Неинтерактивно:

```bash
ENABLE_CDN=y CDN_HOST=cdn.example.com CDN_TRANSPORT=ws CLOUDFLARE_API_TOKEN=xxxx \
BASE_DOMAIN=example.com PANEL_IP=... bash remnanode-setup.sh --non-interactive --yes
```

Проксируемая A-запись CDN (`proxied:true`, единственная такая в схеме) создаётся установщиком автоматически при включённом CDN и заданном токене Cloudflare — в быстром режиме и в расширенном, даже если поддомены VLESS/Hysteria2 вы создавали вручную (без `--cloudflare`): зона для CDN-домена находится по его суффиксам, поэтому работает и CDN-домен в другой зоне. Ручной вариант остался только при явном `--no-cloudflare` (или если токен зону не видит) — тогда мастер предупредит и покажет в сводке строку `CDN DNS: ВРУЧНУЮ`, а запись нужно завести самому. При `ENABLE_CDN=n` CDN-инбаунды вырезаются из профиля и Caddyfile.

**Что изменить в панели (куда и зачем):**

1. **Config Profile** — уже содержит `VLESS_CDN_*` (`127.0.0.1:10446–10448`, `security: none` — TLS терминируют CDN и Caddy). **Зачем:** Xray не смотрит наружу.
2. **Nodes → Management** — включите новые inbound'ы и пересохраните ноду. **Зачем:** иначе Xray не слушает их.
3. **Hosts** — по хосту на каждый CDN-транспорт: Inbound=`VLESS_CDN_*`, Address=`cdn.example.com`, Port=`443`, SNI=`cdn.example.com` (или Override SNI), Security layer `TLS`, Path как в установщике, Tag=`USA`, Hide ON. **Куда:** Hosts. **Зачем:** клиенты видят CDN-хосты.
4. **XRAY_JSON** менять не нужно — `injectHosts` подхватит outbound'ы `proxy-4`….
5. **Internal Squads** — включите CDN-инбаунды. **Зачем:** без squad хосты не попадут в подписку.

Клиенту достаточно подписки — выбор CDN-хоста гонит через CDN, остальных — напрямую.

**Ограничения:** CDN не проксирует UDP (Hysteria2 прямой), видит SNI/объём (но не содержимое), действуют лимиты плана. Origin достижим по IP+SNI — для строгого скрытия включите Authenticated Origin Pulls (mTLS) + `client_auth` в Caddy или ограничьте `443/tcp` диапазонами Cloudflare. После смены токена — перезапустите установщик для перевыпуска сертификата.

## Фасад self-steal: темы

**Куда:** `/var/www/remnanode-self-steal/index.html` (ставит установщик) и Caddyfile `tls ...` + `file_server`.
**Зачем:** чтобы на протокольном домене был правдоподобный сайт, а не ошибка.

| Тема | Что изображает |
|---|---|
| `vaultdrop` | тёмный файлообменник (по умолчанию) |
| `mail` | светлый почтовый клиент |
| `cloud` | облачный диск |
| `admin` | тёмная консоль |
| `docs` | портал документации |

Выбор в мастере блок 2/4 или:

```bash
bash remnanode-setup.sh --self-steal-template mail
SELF_STEAL_TEMPLATE=admin bash remnanode-setup.sh --non-interactive --yes
```

`SELF_STEAL_TEMPLATE_URL=https://...` важнее темы (свой фасад). При ошибке скачивания — минимальная заглушка. HTML не выдаёт тему.

## Cloudflare: создание поддоменов автоматически

**Куда:** Cloudflare DNS вашей зоны.
**Зачем:** не создавать A-записи руками, получить непохожие случайные имена (`quiet-otter.example.com` / `brisk-lantern.example.com` из словарей прилагательное-существительное).

**Токен:** `Zone:Zone:Read` + `Zone:DNS:Edit` на зону (не глобальный).

**Запуск:**

```bash
CLOUDFLARE_API_TOKEN=xxxx bash remnanode-setup.sh --cloudflare
```

- `--cloudflare` — требовать режим (без токена — стоп с подсказкой); без флага включится сам, если `CLOUDFLARE_API_TOKEN` в env; `--no-cloudflare` — принудительно выключить.
- `CLOUDFLARE_ZONE` — если `BASE_DOMAIN` — поддомен зоны (по умолчанию `BASE_DOMAIN`).
- Токен в лог/`ps` не попадает: `curl -K` с файлом 0600, удаляется после.

**Поведение:** две A-записи на IPv4 ноды (`proxied:false`, DNS only) — кроме CDN-хоста (`proxied:true`). Проверка занятости имён, повторный запуск переиспользует сохранённые хосты из `remnanode.env`, ждёт резолвер, HTTP-01 работает как обычно.

**Неинтерактивно:**

```bash
CLOUDFLARE_API_TOKEN=xxxx BASE_DOMAIN=example.com PANEL_IP=... NODE_API_PORT=2222 SECRET_KEY='eyJ...' \
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh) --cloudflare --non-interactive --yes
```

Переопределите `SERVER_IP` за NAT (`SERVER_IP` из env важнее автодетекта), `CLOUDFLARE_ZONE` для поддомена зоны. Хосты печатаются в конце — подставьте в Config Profile/Hosts.

**Что подставить в панели (куда и зачем):** вместо `<prefix>1.<domain>`/`<prefix>3.<domain>` — сгенерированные хосты в `serverNames`/`serverName`/`/etc/remna-certs/<хост>/` (в сохранённом профиле уже подставлены) и в Hosts → Address.

## Опциональный split-routing

**Куда:** **Templates → XRAY_JSON** второй шаблон.
**Зачем:** `Xray_template.json` — full-tunnel (всё через VPN кроме BitTorrent), `Xray_template_split.json` — только RU/частные через VPN (экономия трафика, но не полная приватность).

Split берёт `allow-domains Russia inside` + Telegram/Google AI, подсети Telegram/Meta/Twitter, AdGuard DNS `94.140.14.14`/`15.15`, без `geosite:category-ads-all` (экономия памяти), блокирует `UDP/443` (QUIC → TCP).

Создайте второй XRAY_JSON из `Xray_template_split.json` и назначьте виртуал-хосту/группе.

> Любой новый домен вне списка пойдёт напрямую до обновления списка — для обхода блокировок оставляйте full-tunnel.

## Неинтерактивный запуск

**Куда:** CI/автоматизация.
**Зачем:** без вопросов, из env.

```bash
BASE_DOMAIN=example.com PREFIX=usa SELF_STEAL_HOST=usa1.example.com XHTTP_SNI=www.gstatic.com XHTTP_PATH=/api/v3/sync/r1 \
PANEL_IP=203.0.113.10 NODE_API_PORT=2222 SECRET_KEY='eyJ...' \
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh) --non-interactive --yes
```

С CDN/Cloudflare — см. выше. `ENABLE_XHTTP=n` отключает XHTTP в selfsteal (не спрашивает SNI/path, вырезает inbound/маршрут). `ENABLE_CDN=y` включает CDN. `NODE_IMAGE=remnawave/node:3.1.1` фиксирует образ (иначе `latest`). Версии Caddy `v2.11.7`/`l4 v0.1.2`/`xcaddy v0.4.7`/Go `1.26.9` (проверка SHA256, `caddy-l4` требует Caddy `v2.11.7`). Шаблоны берутся из `Multiselect.json` рядом со скриптом или `MULTISELECT_TEMPLATE_URL`/`SELF_STEAL_RAW_BASE`.

## Флаги

```text
--no-compose          не заменять docker-compose.yml; обновить только .env
--no-firewall         не настраивать ufw
--reset-firewall      удалить правила ufw
--no-reset-firewall   не сбрасывать ufw (по умолчанию)
--force-dns           продолжить при несовпадении DNS
--keep-build-tools    не удалять Go, xcaddy, build-essential и кэши сборки (по умолчанию удаляются)
--ssh-port N          SSH-порт для UFW
--node-image REF      образ ноды; по умолчанию latest
--self-steal-template T  тема фасада (vaultdrop, mail, cloud, admin, docs)
--xray-template T     шаблон подписки: standard или split
--cloudflare          создать A-записи через Cloudflare API
--no-cloudflare       не использовать Cloudflare
--panel-url URL       URL панели Remnawave (для авто-настройки)
--api-token TOKEN     API токен панели
--quick               быстрый режим мастера: 5 вопросов, остальное — авто/случайно
--advanced            расширенный режим мастера: все вопросы по блокам
-y, --yes             подтвердить yes/no
--non-interactive     из env/дефолтов
-h, --help            справка
```

Переменные: `BASE_DOMAIN`, `PREFIX`, `SELF_STEAL_HOST`, `ENABLE_XHTTP`, `XHTTP_SNI`, `XHTTP_PATH`, `ENABLE_CDN`, `CDN_HOST`, `CDN_TRANSPORT`, `CDN_WS_PATH`, `CDN_XHTTP_PATH`, `CDN_GRPC_PATH`, `PANEL_IP`, `NODE_API_PORT`, `SECRET_KEY`, `NODE_IMAGE`, `SELF_STEAL_TEMPLATE`, `SELF_STEAL_TEMPLATE_URL`, `MULTISELECT_TEMPLATE_URL`, `XCADDY_VERSION`, `CADDY_VERSION`, `CADDY_L4_VERSION`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE`, `REMNAWAVE_PANEL_URL`, `REMNAWAVE_API_TOKEN`, `REMNAWAVE_AUTO_SETUP`, `QUICK_SETUP`, `XRAY_TEMPLATE_CHOICE`, `NODE_DIR`, `CERT_DIR`, `ENV_STORE`, `KEEP_BUILD_TOOLS`. Логические понимают `y/yes/1/true/on`/`n/no/0/false/off`. `SERVER_IP` из env важнее автодетекта (для NAT).

## Внешние источники и воспроизводимость

| Источник | Что берётся | Как зафиксировать |
|---|---|---|
| `get.docker.com` | Docker, если не установлен | поставьте docker заранее |
| `get.acme.sh` | `acme.sh` в `/root/.acme.sh` | `--upgrade --auto-upgrade` |
| `dl.google.com/go` | Go для сборки Caddy | `GO_VERSION` + SHA256 |
| `caddyserver/caddy` | исходники Caddy | `CADDY_VERSION` |
| `mholt/caddy-l4` | layer4 | `CADDY_L4_VERSION` |
| `raw.githubusercontent.com` | темы и `Multiselect.json` | `SELF_STEAL_RAW_BASE`/`MULTISELECT_TEMPLATE_URL` |
| реестр образов | `remnawave/node` | `NODE_IMAGE` (`@sha256:`) |

`bash <(curl …)` доверяет `main`; для аудита — качайте, проверяйте, запускайте из клона. Версии связаны: Caddy ≥2.11.6 требует Go ≥1.26 (проверка в CI).

## Диагностика

| Симптом | Куда смотреть | Зачем |
|---|---|---|
| Сертификат не выпускается | A-запись DNS only, `80/tcp` свободен | HTTP-01 требует прямого IP:80 |
| Сертификаты не продлеваются | `crontab -l \| grep acme.sh` | cron восстанавливается каждый запуск |
| Self-steal сломался после Cloudflare | DNS only | прокси ломает REALITY |
| Нода `Offline` | Node Port/`SECRET_KEY`/UFW/`docker logs` | не зависит от хостов |
| Клиент на `1044x` | Host → Port `443` | `10443` локальный |
| Нет виртуального хоста | Видимость ON, Hide OFF, squad | без него нет шаблона |
| Один outbound | Hide ON, тег `USA` | иначе не в `injectHosts` |
| XHTTP не работает | одинаковые path/SNI в профиле/хосте/установщике | рассогласование |
| CDN не подключается | Host: Port `443`, Address/CDN-домен, SNI `cdn`, TLS, path | локальный порт не для клиента |
| CDN ошибка сертификата | Full (strict): `openssl s_client -connect 127.0.0.1:9444 -servername cdn...` | origin должен быть валидным |
| gRPC не работает | ALPN `h2`, serviceName `/...` | Cloudflare нужен HTTP/2 |
| Mihomo | `minClientVer: "0.0.0"` | совместимость |
| BBR нет | ядро/перезагрузка | `tcp_bbr` |
| Нет 301 на `:80` | Caddyfile, UFW, `curl` | 301 обязателен |
| IPv6 панель | `IPV6=yes` в `/etc/default/ufw` | иначе правило не сработает |
| Панель: «не удалось проверить» / HTTP 401 | токен из Settings → API Tokens (не `SECRET_KEY` ноды и не пароль) | 401 — токен неверный, просрочен или удалён |
| Панель: HTTP 403 | права токена: чтение **и** запись для `config-profiles`, `nodes`, `hosts`, `internal-squads` | `:write` без `:read` не даёт читать список; проще выдать `config-profiles:*` и т.п. |
| Панель: HTTP 404 | URL — корень панели без пути: `https://panel.example.com` | `/api` установщик добавляет сам |
| Панель: HTML вместо JSON | Cloudflare Access/страница входа перед панелью | API недоступен без обхода Access |
| Панель: нет соединения (`000`) | DNS/сертификат/доступность домена с сервера ноды | проверьте `curl -I https://panel.example.com` |
| Панель: «Авто-настройка завершена с ошибками» | строка выше с HTTP-кодом: права токена или конфликт имён; перезапуск установщика идемпотентен | установщик больше не пишет «успешно», если хосты/нода не созданы |
| Cloudflare не создаёт | права токена, `CLOUDFLARE_ZONE` | ошибка API в логе |
| CDN-домена нет в Cloudflare | сводка мастера, строка `CDN DNS`: при `ВРУЧНУЮ` запись не создавалась (`--no-cloudflare`, нет токена или токен не видит зону CDN-домена) | без проксируемой A-записи CDN не заработает — создайте её или перезапустите без `--no-cloudflare` |

## IPv6, UFW и ACME

- Только A, без AAAA (Hysteria2 `0.0.0.0:443` — IPv4). Проверка A/AAAA в установщике.
- `PANEL_IP` IPv4/IPv6 — правило UFW проверяется, `IPV6=no` — предупреждение.
- Node API — только firewall; `--no-firewall` — предупреждение.
- Сертификаты — только `acme.sh` в `/etc/remna-certs/`; Caddy/Xray не управляют. CDN — DNS-01 (`dns_cf`), cron без `:80`.
- `:80` — `pre-hook`/`post-hook` останавливают Caddy на challenge (сохраняются для продления, на секунды недоступен `443/tcp`).
- `:80` свободен от nginx/apache.
- Приватный `SERVER_IP` или `PANEL_IP==SERVER_IP` — предупреждение.
- Лог `/var/log/remnanode-setup-*.log` 0600 (только root).

## Повторный запуск и безопасность

- `.env` 0600, лог 0600, `SECRET_KEY` не в лог/экран (только число символов).
- Проверка срока сертификата (<7 дней → `--force`), ранняя проверка занятого `443/tcp`, `flock` против параллельного запуска, очистка кэша Go, восстановление cron `acme.sh`.
- `ls` в контейнере (busybox), ключи read-only, UFW только с IP панели, удаление старых правил Node Port, не более 3/5/10 бэкапов, финал только после слушателей и TLS-проверок.
- `--reset-firewall` только на чистом сервере. Обновление Node — `NODE_IMAGE` + повторный запуск.

## Совместимость с Remnawave 3.x

Проверено по исходникам Remnawave на 13 августа 2026. Официальный compose использует `NODE_PORT`/`SECRET_KEY`/`host`/`NET_ADMIN`; установщик добавляет лимиты/логи/сертификаты, образ `latest` (фиксируйте `NODE_IMAGE=remnawave/node:3.1.1`). `minClientVer: "0.0.0"` для Mihomo, `smux`/`brutal` не нужны. CI: Bash/ShellCheck, JSON5, JS, `env-flags`/`caddy-http`. После установки — [проверка](#проверка-после-установки).

Источники: [Node](https://docs.rw/install/remnawave-node), [Config Profiles](https://docs.rw/learn-en/config-profiles), [Hosts](https://docs.rw/learn-en/hosts/), [XRAY_JSON](https://docs.rw/learn/xray-json-advanced), [образы Node](https://github.com/remnawave/node/pkgs/container/node), [caddy-l4 v0.1.2](https://github.com/mholt/caddy-l4/blob/v0.1.2/go.mod), [Go SHA256](https://go.dev/dl/), [Caddy v2.11.7](https://github.com/caddyserver/caddy/releases/tag/v2.11.7), [caddy-l4 + Caddy v2.11.7](https://github.com/mholt/caddy-l4/commit/77044b47bccf03b57610bb303851ab31259779bd)

## Лицензия

MIT ([LICENSE](LICENSE)): можно использовать/менять/распространять с сохранением лицензии и авторства. Форк [`1atex/multi-protocol`](https://github.com/1atex/multi-protocol) — в исходном нет лицензии, в `LICENSE` оба автора. Если автор апстрима не согласен — issue, приведём в соответствие. Уязвимости — по [SECURITY.md](SECURITY.md) (установщик от root, не публикуйте открыто).

