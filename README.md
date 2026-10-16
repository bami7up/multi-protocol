# Multi-protocol Remnawave Node

Пошаговая инструкция по установке ноды Remnawave с четырьмя протоколами на одном публичном порту:

- VLESS Reality/Vision с локальным self-steal;
- VLESS XHTTP + Reality;
- Hysteria2;
- VLESS за CDN (Cloudflare и другие CDN) — опционально, по отдельному домену.

Caddy L4 принимает `443/tcp` и распределяет соединения по SNI. На `80/tcp` Caddy отвечает постоянным 301 на HTTPS с сохранением пути и query string. Hysteria2 принимает `443/udp` напрямую. Обычный браузер на self-steal-домене получает локальный TLS-сайт в стиле закрытого файлообменника. VLESS за CDN отдельного порта не требует: клиент ходит на CDN-домен через `443/tcp`, а сам CDN — на тот же `443/tcp` ноды (см. раздел [VLESS за CDN](#vless-за-cdn-cloudflare)).

> Форма входа на маскировочном сайте декоративная: данные никуда не отправляются и не сохраняются.

**Порядок работы:**

| Шаг | Что делаете | Где |
|---|---|---|
| [0](#шаг-0-требования-и-подготовка) | Требования, домены, DNS, выбор конфигурации | локально |
| [1](#шаг-1-создайте-серверный-config-profile) | Серверный Config Profile | панель |
| [2](#шаг-2-создайте-ноду) | Нода с `SECRET_KEY` | панель |
| [3](#шаг-3-запустите-установщик-на-ноде) | Установщик: Docker, Caddy, сертификаты, UFW, Node | нода |
| [4](#шаг-4-проверьте-статус-ноды) | Нода `Online` | панель |
| [5](#шаг-5-создайте-рабочие-хосты) | Рабочие хосты (скрытые) | панель |
| [6](#шаг-6-создайте-xray_json-шаблон) | Клиентский XRAY_JSON-шаблон | панель |
| [7](#шаг-7-создайте-виртуальный-хост) | Видимый виртуальный хост | панель |
| [8](#шаг-8-добавьте-inboundы-в-internal-squad) | Internal Squad | панель |
| [9](#шаг-9-подключите-клиент) | Подписка и проверка клиента | клиент |
| [10](#проверка-после-установки) | Итоговая проверка ноды | нода |

Дополнительно, по мере необходимости: [VLESS за CDN](#vless-за-cdn-cloudflare), [темы фасада](#фасад-self-steal-темы), [split-routing](#опциональный-split-routing), [автоматические DNS-записи Cloudflare](#cloudflare-создание-поддоменов-автоматически), [неинтерактивный запуск](#неинтерактивный-запуск), [флаги](#флаги), [диагностика](#диагностика).

## Совместимость с Remnawave 3.x

Проверено по официальным исходникам и документации Remnawave на 13 августа 2026 года.

| Компонент | Статус | Что проверено |
|---|---|---|
| Panel `3.0.x–3.2.x` | ✅ Совместимо | Config Profiles, Hosts, Internal Squads и XRAY_JSON `injectHosts`; REST API не используется |
| Node `3.0.0–3.1.1` | ✅ Совместимо | `NODE_PORT`, `SECRET_KEY`, host network, `NET_ADMIN`, сертификаты и Xray-core `v26.7.28`; форк smux не требуется |
| Remnawave `2.x` | ⚠️ Не целевая ветка | `injectHosts` доступен с `2.6.3`, но инструкция написана для интерфейса 3.x |

Официальный compose Node 3.x использует `NODE_PORT`, `SECRET_KEY`, `network_mode: host` и `NET_ADMIN`. Установщик следует этой схеме, добавляет сертификаты, лимиты и ротацию логов, а образ по умолчанию `latest`. Для фиксации версии используйте `NODE_IMAGE=remnawave/node:3.1.1`.

Оба REALITY inbound'а содержат `minClientVer: "0.0.0"`. Это сохраняет совместимость с Mihomo и другими клиентами, которые некорректно определялись новым Xray-core. Параметры `smux` и `brutal-opts` в этом профиле не используются, поэтому `remnanode-smux`, модуль `tcp-brutal` и замена штатного ядра для данной конфигурации не нужны.

Полный интеграционный тест требует живой панели, DNS и публичного IP. CI репозитория проверяет Bash/ShellCheck, JSON5-шаблоны, JavaScript фасада, форматирование, разбор логических env-флагов (`tests/env-flags-checks.sh`), а также поднимает настоящий Caddy и прогоняет HTTP-слой именно того Caddyfile, который генерирует установщик (`tests/caddy-http-checks.sh`: 301 с сохранением URI, HSTS, TLS 1.2/1.3, запрет TLS 1.0/1.1, маршруты CDN-хоста вплоть до gRPC по h2c). После установки на конкретном сервере выполните [проверку](#проверка-после-установки).

Официальные источники:

- [Установка Remnawave Node](https://docs.rw/install/remnawave-node)
- [Config Profiles](https://docs.rw/learn-en/config-profiles)
- [Hosts](https://docs.rw/learn-en/hosts/)
- [XRAY_JSON и injectHosts](https://docs.rw/learn/xray-json-advanced)
- [Образы Remnawave Node](https://github.com/remnawave/node/pkgs/container/node)
- [Зависимость caddy-l4 v0.1.2 от Caddy v2.11.4](https://github.com/mholt/caddy-l4/blob/v0.1.2/go.mod)
- [Официальные архивы и SHA256 Go](https://go.dev/dl/)
- [Caddy v2.11.7 и требование Go >= 1.26](https://github.com/caddyserver/caddy/releases/tag/v2.11.7)
- [Сборка caddy-l4 с Caddy v2.11.7](https://github.com/mholt/caddy-l4/commit/77044b47bccf03b57610bb303851ab31259779bd)

## Файлы репозитория и куда их загружать

Это два разных типа шаблонов. Не меняйте их местами.

| Файл | Куда в Remnawave 3.x | Назначение |
|---|---|---|
| `Multiselect.json` | **Config Profiles → Create Config Profile** (шаг 1) | Шаблон серверной конфигурации Xray; установщик сохраняет готовую копию профиля в `$NODE_DIR/Multiselect.json` |
| `Xray_template.json` | **Templates → XRAY_JSON** (шаг 6) | Клиентская подписка с балансировщиком и инжектом хостов |
| `Xray_template_split.json` | **Templates → XRAY_JSON** (опция) | Опциональный split-routing: выбранные домены через VPN, остальное напрямую |
| `remnanode-setup.sh` | Запуск от `root` на ноде (шаг 3) | Docker, Caddy L4, сертификаты, UFW и Node |
| `self-steal-templates/*.html` | В панель не загружается | Темы локального сайта self-steal (`vaultdrop`, `mail`, `cloud`, `admin`, `docs`) |

## Как это устроено

### Схема портов

| Публичный вход | SNI | Локальный получатель |
|---|---|---|
| `443/tcp` | self-steal-домен | Vision `127.0.0.1:10443` |
| `443/tcp` | внешний XHTTP SNI | XHTTP `127.0.0.1:10444` |
| `443/tcp` | CDN-домен (при `ENABLE_CDN=y`) | origin-сайт `127.0.0.1:9444`: пути CDN-транспортов уходят в Xray `10446–10448`, остальное — фасад |
| `443/tcp` | любой другой SNI | сайт `127.0.0.1:9443` |
| `443/udp` | Hysteria2-домен | Hysteria2 внутри Node |
| `80/tcp` | self-steal-домен | постоянный 301 на HTTPS с сохранением пути и query |

Vision использует `target: 127.0.0.1:9443`: REALITY крадёт рукопожатие у собственного TLS-сайта. XHTTP оставлен с внешним target, потому что локальный XHTTP+REALITY self-steal имеет [известную проблему в Xray-core](https://github.com/XTLS/Xray-core/issues/5923). CDN-хост занимает собственный SNI-маршрут L4 и отдельный локальный TLS-сайт `127.0.0.1:9444`, который слушает только loopback.

### Маскировочный сайт

На `127.0.0.1:9443` (и на `:80`) отдаётся локальная страница-фасад: по SNI, который не совпал с протокольными, сканер видит правдоподобный сайт, а не заглушку. Тема выбирается в [шаге 0](#шаг-0-требования-и-подготовка), список тем — в разделе [Фасад self-steal: темы](#фасад-self-steal-темы).

## Шаг 0. Требования и подготовка

### Сервер и ПО

- отдельный сервер ноды с Debian 11/12 или Ubuntu 20.04+ (на более старых версиях установщик предупредит о несоответствии минимума);
- `amd64` или `arm64`, root-доступ;
- желательно от 1 GB RAM и 3 GB свободного места;
- Remnawave Panel 3.x;
- публичный IPv4 ноды и IPv4/IPv6-адрес панели.

### Домены и DNS

Минимум — две A-записи на IP ноды (`usa1` и `usa3`) и отсутствие AAAA-записей на протокольных доменах. Пример для префикса `usa`:

| A-запись | Назначение |
|---|---|
| `usa1.example.com` | Reality/Vision self-steal |
| `usa3.example.com` | Hysteria2 TLS |

Если не хотите создавать записи вручную — включите [режим Cloudflare](#cloudflare-создание-поддоменов-автоматически), и установщик создаст записи сам.

> [!IMPORTANT]
> Все протокольные записи должны постоянно работать в режиме **DNS only**. Если DNS управляется через Cloudflare, оставьте для них серое облако и не включайте Proxy после выпуска сертификатов. Cloudflare завершает TLS на своей стороне, поэтому исходный TLS ClientHello не доходит до Caddy/Reality и self-steal перестаёт работать. Обычный Cloudflare Proxy также ломает прямой Hysteria2 и не проксирует UDP-трафик Hysteria2. Единственные исключения: CDN-хост из раздела [VLESS за CDN](#vless-за-cdn-cloudflare) — там оранжевое облако обязательно, — и отдельный обычный веб-домен, который не используется этими протоколами.

Не создавайте AAAA-записи для этих доменов: Hysteria2 в профиле привязан к `0.0.0.0:443`, то есть только к IPv4. При наличии AAAA часть клиентов выберет IPv6 и получит нестабильное подключение. Установщик проверяет все A/AAAA-записи и предупреждает о лишних адресах.

До запуска проверьте, что `80/tcp`, `443/tcp`, `443/udp` доступны из интернета. Node Port, например `2222/tcp`, должен быть доступен только с IP панели.

Установщик выпускает и продлевает сертификаты через HTTP-01 в standalone-режиме. Поэтому A-записи должны вести прямо на публичный IPv4 ноды, а `80/tcp` должен быть доступен из интернета не только при первой установке, но и при автоматическом продлении. Поскольку `80/tcp` занимает Caddy, установщик передаёт acme.sh хуки `--pre-hook`/`--post-hook`, которые останавливают и поднимают Caddy вокруг challenge; acme.sh сохраняет их и применяет точно так же при автопродлении из cron. Порт 80 при этом должен быть свободен от посторонних сервисов (nginx, apache и т.п.).

### Токен Cloudflare

Токен нужен, если вы планируете один из двух режимов (оба не обязательны):

- [автоматические DNS-записи](#cloudflare-создание-поддоменов-автоматически) для `usa1`/`usa3` — флаг `--cloudflare`;
- [VLESS за CDN](#vless-за-cdn-cloudflare) — там токен требуется всегда: он выпускает DNS-01 сертификат CDN-хоста.

Создайте API-токен, привязанный к целевой зоне (не глобальный ключ), с правами `Zone:Zone:Read` и `Zone:DNS:Edit`.

### Выбор конфигурации

Всё решается переменными окружения или ответами установщика; подробности — в разделах по ссылкам.

| Что выбираете | Значения по умолчанию | Варианты | Подробнее |
|---|---|---|---|
| XHTTP в selfsteal | `ENABLE_XHTTP=y` | `y` / `n` | [неинтерактивный запуск](#неинтерактивный-запуск) |
| VLESS за CDN | `ENABLE_CDN=n` | `n` / `y` + `CDN_TRANSPORT=ws\|xhttp\|grpc\|both\|all` | [VLESS за CDN](#vless-за-cdn-cloudflare) |
| Авто-DNS в Cloudflare | по токену в env | `--cloudflare` / `--no-cloudflare` | [Cloudflare: создание поддоменов автоматически](#cloudflare-создание-поддоменов-автоматически) |
| Тема фасада | `SELF_STEAL_TEMPLATE=vaultdrop` | `vaultdrop`, `mail`, `cloud`, `admin`, `docs` | [Фасад self-steal: темы](#фасад-self-steal-темы) |
| Маршрутизация клиента | `Xray_template.json` (full-tunnel) | `Xray_template_split.json` (split-routing) | [Опциональный split-routing](#опциональный-split-routing) |

Логические переменные — `ENABLE_XHTTP`, `ENABLE_CDN` — понимают `y`, `yes`, `1`, `true`, `on` и `n`, `no`, `0`, `false`, `off` (регистр не важен). Так же они записываются и в сохраняемый `/root/remnanode.env`, поэтому значение `1`, оставшееся от установщика прежних версий, читается тем же способом, что и `y`.

## Пошаговая установка для Remnawave 3.x

### Шаг 1. Создайте серверный Config Profile

Установщик уже сохраняет готовый профиль в `$NODE_DIR/Multiselect.json` (по умолчанию `/opt/remnanode/Multiselect.json`): в нём подставлены реальные хосты, внешний SNI, `path` XHTTP и пути к сертификатам Hysteria2. Если XHTTP в selfsteal выключен (`ENABLE_XHTTP=n`), inbound `REALITY_XHTTP` из профиля удалён; если включён VLESS за CDN (`ENABLE_CDN=y`), добавляются CDN-инбаунды выбранных транспортов (`CDN_TRANSPORT`) — профиль всегда совпадает с Caddyfile на ноде.

1. Откройте **Config Profiles → Create Config Profile**.
2. Вставьте сохранённый установщиком файл `$NODE_DIR/Multiselect.json` (либо `Multiselect.json` из репозитория, если заполняете профиль до установки — тогда замените плейсхолдеры):

| Плейсхолдер | Пример |
|---|---|
| `<prefix>1.<domain>` | `usa1.example.com` |
| `<prefix>3.<domain>` | `usa3.example.com` |

В режиме Cloudflare хосты генерирует сам установщик (например `quiet-otter.example.com`): они уже подставлены в сохранённый профиль и печатаются в конце установки.

3. Проверьте inbound'ы:

| Tag | Listen | Port | Критичное поле |
|---|---|---:|---|
| `REALITY_VISION` | `127.0.0.1` | `10443` | `target: 127.0.0.1:9443`, `minClientVer: "0.0.0"`, self-steal-домен в `serverNames` |
| `REALITY_XHTTP` | `127.0.0.1` | `10444` | внешний SNI в `serverNames`, `minClientVer: "0.0.0"` |
| `HYSTERIA2` | `0.0.0.0` | `443/udp` | сертификат Hysteria2-домена |

С включённым VLESS за CDN (`ENABLE_CDN=y`) в профиле появляются ещё три (или меньше, по `CDN_TRANSPORT`) inbound'а без собственного TLS:

| Tag | Listen | Port | Критичное поле |
|---|---|---:|---|
| `VLESS_CDN_WS` | `127.0.0.1` | `10446` | `security: none`, `wsSettings.path` совпадает с Caddy и Host'ом |
| `VLESS_CDN_XHTTP` | `127.0.0.1` | `10447` | `security: none`, `xhttpSettings.mode: auto`, свой `path` |
| `VLESS_CDN_GRPC` | `127.0.0.1` | `10448` | `security: none` (h2c со стороны Caddy), `grpcSettings.serviceName` |

`privateKey`, `shortIds` и массивы `clients` оставьте под управлением Remnawave.

### Шаг 2. Создайте ноду

Откройте **Nodes → Management → +**:

1. Укажите публичный IP ноды.
2. Укажите Node Port, например `2222`.
3. Скопируйте выданный панелью `SECRET_KEY`.
4. Выберите Config Profile из шага 1.
5. Активируйте все inbound'ы профиля и сохраните ноду: три при включённом XHTTP, два — при `ENABLE_XHTTP=n`; при включённом CDN активируйте и его inbound'ы (`10446–10448`).

Сгенерированный панелью compose отдельно запускать не нужно: установщик создаёт совместимый compose сам. Нужны только `SECRET_KEY`, IP и Node Port.

### Шаг 3. Запустите установщик на ноде

Рекомендуемый вариант — сначала скачать и просмотреть:

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh -o remnanode-setup.sh
less remnanode-setup.sh
bash remnanode-setup.sh
```

Короткий вариант:

```bash
apt-get update && apt-get install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh)
```

Скрипт спросит базовый домен, префикс, self-steal-домен, нужен ли XHTTP в selfsteal (при согласии — внешний SNI и путь XHTTP), добавить ли VLESS за CDN (при согласии — CDN-домен, транспорт, пути и токен Cloudflare), IP панели, Node Port и `SECRET_KEY`. SSH-порт определяется автоматически; при необходимости передайте `--ssh-port N`. Ответы сохраняются в `/root/remnanode.env`.

Готовый неинтерактивный запуск (в том числе с CDN и Cloudflare) — в разделе [Неинтерактивный запуск](#неинтерактивный-запуск).

### Шаг 4. Проверьте статус ноды

В **Nodes → Management** нода должна стать `Online`. Если она offline, сначала проверяйте Node Port, `SECRET_KEY` и UFW — хосты и клиентский шаблон на этот статус не влияют.

### Шаг 5. Создайте рабочие хосты

В **Hosts** создайте по хосту для каждого inbound'а. Всем рабочим хостам задайте одинаковый тег, например `USA`, включите видимость и **Hide host**.

| Inbound | Address | Публичный port | Tag | Hide host |
|---|---|---:|---|---|
| `REALITY_VISION` | `usa1.example.com` | `443` | `USA` | ON |
| `REALITY_XHTTP` | `usa1.example.com` | `443` | `USA` | ON |
| `HYSTERIA2` | `usa3.example.com` | `443` | `USA` | ON |

- Для первых двух хостов вручную укажите публичный порт `443`: порты `10443–10444` локальные и не должны попадать клиентам.
- В режиме Cloudflare в поле **Address** подставьте сгенерированные установщиком хосты вместо `usa1`/`usa3`.
- В XHTTP Host укажите те же `path` и внешний SNI, что в Config Profile и установщике.
- С выключенным XHTTP (`ENABLE_XHTTP=n`) создаются только два хоста — для `REALITY_VISION` и `HYSTERIA2`; лишний XHTTP-хост панели не нужен.
- С включённым VLESS за CDN добавьте ещё по одному хосту на каждый CDN-транспорт: Inbound — `VLESS_CDN_*`, **Address** — сам CDN-домен (`CDN_HOST`), **Port** — `443`, SNI — CDN-домен, **Security layer** — `TLS`, тот же тег и **Hide host** ON (подробная таблица — в разделе [VLESS за CDN](#vless-за-cdn-cloudflare)).

### Шаг 6. Создайте XRAY_JSON-шаблон

Откройте **Templates → XRAY_JSON** и вставьте `Xray_template.json`.

Если используете тег не `USA`, замените его в:

- `routing.balancers[].tag`;
- `remnawave.injectHosts[].selector.pattern`.

`tagPrefix: "proxy"`, `routing.balancers[].selector: ["proxy"]` и `burstObservatory.subjectSelector: ["proxy"]` должны совпадать.

### Шаг 7. Создайте виртуальный хост

Это видимая оболочка для XRAY_JSON-шаблона:

| Поле | Значение |
|---|---|
| Inbound | любой inbound этого профиля |
| Address | валидный адрес, например `usa1.example.com` |
| Port | `443` |
| Tag | пусто |
| Видимость | ON |
| Hide host | **OFF** |
| XRAY_JSON template | шаблон из шага 6 |

Итого: три скрытых рабочих хоста (плюс по одному на каждый CDN-транспорт при включённом CDN) и один видимый виртуальный.

### Шаг 8. Добавьте inbound'ы в Internal Squad

Откройте **Internal Squads** и включите все inbound'ы, к которым привязаны рабочие и виртуальный хосты — включая CDN-инбаунды при включённом CDN. Иначе часть хостов не попадёт в подписку.

### Шаг 9. Подключите клиент

1. Возьмите подписку пользователя в панели и импортируйте её в клиент (v2rayNG, Hiddify, Streisand, Mihomo и т.п.).
2. В списке хостов появятся все скрытые рабочие хосты: выбирайте любой — Reality-хосты идут напрямую, CDN-хосты через CDN; балансировщик `USA` равномерно использует все outbound'ы.
3. Для split-routing назначьте клиенту второй шаблон (см. [Опциональный split-routing](#опциональный-split-routing)).

Если хостов в подписке нет или виден только один — вернитесь к шагам [5](#шаг-5-создайте-рабочие-хосты), [7](#шаг-7-создайте-виртуальный-хост) и [8](#шаг-8-добавьте-inboundы-в-internal-squad): почти всегда причина в Hide host, теге или Internal Squad.

## Проверка после установки

```bash
docker ps --filter name=remnanode
docker logs remnanode --tail 120
docker exec -it remnanode tail -f /var/log/xray/current
systemctl status caddy --no-pager
ss -lntup | grep -E ':80|:443|:9443|:9444|:10443|:10444|:10446|:10447|:10448'
ufw status numbered
```

Проверка редиректа и HSTS:

```bash
curl -sI "http://usa1.example.com/probe/path?x=1" | head -3
curl -s -D - -o /dev/null "https://usa1.example.com/" | grep -i strict-transport-security
```

Первая команда должна вернуть `301` и `Location: https://usa1.example.com/probe/path?x=1`, вторая — `strict-transport-security: max-age=31536000`.

Проверка self-steal:

```bash
echo | openssl s_client \
  -connect 127.0.0.1:9443 \
  -servername usa1.example.com \
  -verify_return_error -brief
```

Откройте `https://usa1.example.com/` в браузере. Должен появиться фасад файлообменника с валидным сертификатом.

Проверка VLESS за CDN (выполняется при `ENABLE_CDN=y`):

```bash
# origin-сайт CDN должен отдавать фасад и свой сертификат
echo | openssl s_client -connect 127.0.0.1:9444 -servername cdn.example.com -brief
# фасад и заголовки через сам CDN
curl -sI "https://cdn.example.com/" | head -3
# путь WebSocket должен уходить в Xray (пока апстрим недоступен — ошибка апстрима, но не 404)
curl -s -o /dev/null -w '%{http_code}\n' "https://cdn.example.com/api/v1/stream"
```

Ожидаемый итог:

- нода `Online`;
- `443/tcp` слушает Caddy, `443/udp` — Xray/Hysteria2;
- `10443–10444` и CDN-инбаунды `10446–10448` слушаются только на `127.0.0.1`;
- XRAY_JSON содержит `proxy`, `proxy-2`, `proxy-3` (и `proxy-4`… при включённом CDN);
- `http://usa1.example.com/<любой-путь>?x=1` отдаёт `301` c `Location: https://usa1.example.com/<любой-путь>?x=1`;
- клиент подключается, балансировщик видит три и более outbound'а (по числу скрытых хостов).

## VLESS за CDN (Cloudflare)

Опциональный четвёртый протокол: тот же VLESS, но клиент подключается не к ноде напрямую, а к домену под CDN (по умолчанию Cloudflare). CDN завершает публичный TLS и пробрасывает трафик на `443/tcp` ноды, где Caddy завершает уже свой внутренний TLS сертификатом CDN-хоста и по путям отдаёт трафик Xray, слушающему только loopback. Для клиента скрывается IP ноды, добавляется запасной маршрут на случай блокировки прямого адреса, а TLS со стороны CDN выглядит как у обычного сайта.

```text
клиент → https://cdn.example.com (TLS 443) → CDN → :443 ноды (TLS, сертификат CDN-хоста)
                                                 └→ Caddy L4 (SNI) → 127.0.0.1:9444 (TLS)
                              ├─ путь ws    → Xray 127.0.0.1:10446 (VLESS + WebSocket, без TLS)
                              ├─ путь xhttp → Xray 127.0.0.1:10447 (VLESS + XHTTP, без TLS)
                              ├─ путь grpc  → Xray 127.0.0.1:10448 (VLESS + gRPC, h2c)
                              └─ всё прочее → фасад self-steal
```

Схема следует типовому подходу «VLESS + транспорт + обычный TLS за CDN» (примеры: [braydos-h/vless-ws-cdn-tunnel-setup](https://github.com/braydos-h/vless-ws-cdn-tunnel-setup), [wpdevelopment11/xray-tutorial](https://github.com/wpdevelopment11/xray-tutorial), нюансы Cloudflare — в [XTLS/Xray-core discussion #5423](https://github.com/XTLS/Xray-core/discussions/5423)), адаптированному под Caddy L4 и Config Profiles Remnawave. Доступные транспорты:

| Транспорт | `CDN_TRANSPORT` | Inbound профиля | Путь / serviceName по умолчанию |
|---|---|---|---|
| WebSocket | `ws` (по умолчанию) | `VLESS_CDN_WS` (`10446`) | `/api/v1/stream` |
| XHTTP | `xhttp` | `VLESS_CDN_XHTTP` (`10447`) | `/api/v3/sync/c1` |
| gRPC | `grpc` | `VLESS_CDN_GRPC` (`10448`) | `/api/v4/stream` |
| WebSocket + XHTTP | `both` | оба ws-инбаунда | как выше |
| все три | `all` | все три | как выше |

### Что нужно заранее

- отдельный поддомен под CDN, например `cdn.example.com`, с A-записью **под оранжевым облаком** (proxied) — в отличие от протокольных доменов, где серое облако обязательно;
- этот домен не должен совпадать с self-steal, Hysteria2 и XHTTP SNI — установщик проверяет и останавливается при конфликте;
- Cloudflare API-токен с правами `Zone:Zone:Read` и `Zone:DNS:Edit`: он нужен и для A-записи CDN-хоста (в режиме `--cloudflare`), и для выпуска сертификата этого хоста;
- сертификат CDN-хоста выпускается через ACME **DNS-01**, а не HTTP-01: за прокси на порт `80` отвечает сам CDN, поэтому standalone-challenge до ноды не доходит; автопродление работает из cron acme.sh с тем же токеном и порт 80 не требует;
- между CDN и origin — **Full (strict)**: Caddy отвечает валидным сертификатом CDN-хоста, выпущенным на ваше имя;
- CDN должен поддерживать выбранный транспорт: WebSocket и HTTP/2 (нужен gRPC) у Cloudflare включены по умолчанию; нестандартные порты CDN не проксирует, поэтому клиент всегда ходит на `443`.

### Запуск установщика

Интерактивно установщик сам спросит «Добавить VLESS за CDN (Cloudflare и др.)?», затем домен, транспорт и пути:

```bash
bash remnanode-setup.sh
```

Неинтерактивно:

```bash
ENABLE_CDN=y \
CDN_HOST=cdn.example.com \
CDN_TRANSPORT=ws \
CLOUDFLARE_API_TOKEN=xxxx \
BASE_DOMAIN=example.com \
PREFIX=usa \
SELF_STEAL_HOST=usa1.example.com \
PANEL_IP=203.0.113.10 \
NODE_API_PORT=2222 \
SECRET_KEY='eyJ...' \
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh) \
  --non-interactive --yes
```

- `ENABLE_CDN=y` включает режим (по умолчанию `n` — поведение прежних версий);
- `CDN_TRANSPORT` — `ws`, `xhttp`, `grpc`, `both` (ws+xhttp) или `all`; пути переопределяются через `CDN_WS_PATH`, `CDN_XHTTP_PATH`, `CDN_GRPC_PATH` (у gRPC это serviceName и начинается со слэша); пути транспортов обязаны различаться — установщик проверяет;
- в интерактивном режиме токен можно не передавать в env — установщик спросит его сам;
- с флагом `--cloudflare` установщик создаст A-запись CDN-хоста сам и сразу **проксируемой** (`proxied: true`) — это единственная запись в схеме с оранжевым облаком; без режима Cloudflare создайте запись в панели CDN вручную;
- запоминать ответы не нужно: `ENABLE_XHTTP` и `ENABLE_CDN` сохраняются в `/root/remnanode.env` в виде `y`/`n` (решение «нет» тоже запоминается), а вместе с включённым CDN — `CDN_HOST`, `CDN_TRANSPORT` и пути; повторный запуск задаёт те же вопросы с готовыми значениями;
- при выключении CDN (`ENABLE_CDN=n`) CDN-инбаунды вырезаются из сохранённого Config Profile, а маршрут CDN-хоста — из Caddyfile.

Установщик при этом: добавляет SNI-маршрут CDN-хоста в layer4 Caddy (`proxy 127.0.0.1:9444`), выпускает через DNS-01 и устанавливает сертификат CDN-хоста, дописывает в Caddyfile отдельный TLS-сайт `https://<CDN_HOST>:9444` с маршрутами транспортов в Xray (gRPC — по h2c, без буферизации) и фасадом на остальных путях и оставляет в Config Profile только выбранные CDN-инбаунды.

### Что изменить в панели

Делаются после основных шагов 1–4, только для CDN-режима:

1. **Config Profile** — CDN-инбаунды `VLESS_CDN_WS` / `VLESS_CDN_XHTTP` / `VLESS_CDN_GRPC` уже входят в сохранённый установщиком профиль `$NODE_DIR/Multiselect.json` (при ручном заполнении вставьте `Multiselect.json` из репозитория). Они слушают `127.0.0.1:10446–10448` и идут **без собственного TLS** (`security: none`): публичный TLS на этой схеме терминируют CDN и Caddy, Xray наружу не смотрит.
2. **Nodes → Management** — активируйте новые inbound'ы профиля вместе с остальными и пересохраните ноду.
3. **Hosts** — добавьте по одному хосту на каждый включённый CDN-транспорт; хосты из шага 5 не трогаем:

| Поле | Значение |
|---|---|
| Inbound | `VLESS_CDN_WS` / `VLESS_CDN_XHTTP` / `VLESS_CDN_GRPC` |
| Address | `cdn.example.com` — CDN-домен, а не IP ноды |
| Port | `443` (панель подставит локальный `10446–10448` — замените на публичный `443`) |
| SNI (Advanced Options) | `cdn.example.com`, либо включите **Override SNI from address** |
| Security layer | `TLS` — клиент ходит в CDN по обычному TLS, собственного TLS у inbound'а нет |
| Path / serviceName | как в установщике (`/api/v1/stream` и т.п.; обычно наследуется из inbound'а) |
| ALPN (только для gRPC) | `h2` — Cloudflare проксирует gRPC поверх HTTP/2 |
| Tag | `USA` — тот же, что у остальных рабочих хостов |
| Hide host | ON |

4. **XRAY_JSON-шаблон менять не нужно**: `injectHosts` подхватит новые скрытые хосты и добавит в подписку outbound'ы `proxy-4` и далее — балансировщик учитывает их наравне с остальными.
5. **Internal Squads** — включите CDN-инбаунды, иначе новые хосты не попадут в подписку.

Всё: клиенту достаточно обычной подписки — при выборе CDN-хоста трафик пойдёт через CDN, при выборе остальных хостов — напрямую.

### Ограничения

- CDN не проксирует UDP: за CDN идут только TCP-транспорты VLESS, `443/udp` Hysteria2 остаётся прямым.
- CDN видит домен, SNI и объём трафика; скрывается IP ноды и содержимое (TLS). Напрямую по IP Reality/Vision продолжает работать как основной антицензурный маршрут.
- Лимиты и политика CDN (в том числе бесплатного плана Cloudflare) распространяются и на этот транспорт — при серьёзной нагрузке используйте CDN с большими лимитами или прямые маршруты.
- Origin достижим напрямую, если знать IP ноды и SNI: L4-маршрут выбирает получателя по SNI, поэтому запрос с `SNI=cdn.example.com` на `443/tcp` ноды приведёт на CDN-сайт Caddy, а пути транспортов — в CDN-инбаунды Xray (аутентификация остаётся обычной VLESS-UUID). «Скрытие IP» держится на том, что адрес ноды и домен не связаны публично; проверка `curl --resolve cdn.example.com:443:<IP ноды> https://cdn.example.com` из внешней сети как раз это показывает. Если скрывать origin нужно строго, добавьте хотя бы одно из: (а) **Authenticated Origin Pulls** в панели Cloudflare (mTLS) плюс `client_auth` с сертификатом Cloudflare в сайте CDN-хоста; (б) ограничение `443/tcp` диапазонами Cloudflare в firewall — диапазоны меняются, список нужно обновлять; (в) отдельный CDN-домен, который нигде не публикуется, кроме самой панели CDN.
- После смены токена или зоны Cloudflare перевыпустите сертификат CDN-хоста повторным запуском установщика.

## Фасад self-steal: темы

Тема — это страница, которую видит обычный браузер на протокольном домене (и на CDN-хосте). В репозитории пять автономных тем — каждая без внешних запросов, шрифтов и ссылок, с инлайновым скриптом (CSP установщика разрешает только инлайновые стили и скрипты):

| Тема | Что изображает |
|---|---|
| `vaultdrop` | тёмное рабочее пространство для файлов (по умолчанию, поведение прежних версий) |
| `mail` | светлый веб-клиент почты |
| `cloud` | светлый облачный диск |
| `admin` | тёмная консоль мониторинга с графиками |
| `docs` | светлый портал документации |

Выбор темы — флагом или переменной:

```bash
bash remnanode-setup.sh --self-steal-template mail
# или
SELF_STEAL_TEMPLATE=admin bash remnanode-setup.sh --non-interactive --yes
```

- Неизвестная тема останавливает установку и печатает список доступных.
- `SELF_STEAL_TEMPLATE_URL` важнее темы: свой фасад можно отдать публичным HTTPS URL, и тема тогда не используется.
- Если шаблон не удалось скачать (например, нет доступа к GitHub), установщик поставит минимальную локальную заглушку и предупредит — установка продолжится.
- Тема не печатается в исходном коде страницы: по HTML нельзя понять, что фасад выбран установщиком.

## Cloudflare: создание поддоменов автоматически

Вместо ручного создания A-записей установщик может создать их сам через Cloudflare API — и сразу с **осмысленными случайными именами**, не похожими друг на друга: вместо связанной нумерации `usa1`/`usa3` получаются что-то вроде `quiet-otter.example.com` и `brisk-lantern.example.com`. Имена собираются из двух словарей (прилагательное-существительное), каждое слово берётся один раз — два хоста различаются в обеих частях.

### Токен

Создайте API-токен, привязанный к целевой зоне (не глобальный ключ), с правами:

- `Zone:Zone:Read` — поиск зоны;
- `Zone:DNS:Edit` — создание и обновление A-записей.

### Запуск

```bash
CLOUDFLARE_API_TOKEN=xxxx bash remnanode-setup.sh --cloudflare
```

- `--cloudflare` — режим обязателен: без токена установщик остановится с подсказкой; при `--non-interactive` токен передаётся только через `CLOUDFLARE_API_TOKEN`.
- Без флага режим включается сам, если `CLOUDFLARE_API_TOKEN` уже есть в окружении. `--no-cloudflare` отключает его принудительно (например, если токен есть в env, но для этого запуска нужен ручной DNS).
- `CLOUDFLARE_ZONE` — имя зоны, если `BASE_DOMAIN` является её поддоменом (по умолчанию равен `BASE_DOMAIN`).
- Токен не попадает ни в лог, ни в `ps`: curl читает его из временного файла `0600` и удаляет после работы.

### Поведение

- Создаются или обновляются две A-записи — self-steal (Vision/XHTTP) и Hysteria2 — на определённый публичный IPv4 ноды; `proxied: false` и `ttl: auto`: эти записи всегда **DNS only**, оранжевое облако несовместимо с ними и API его для них никогда не включает. Исключение — CDN-хост при включённом `ENABLE_CDN`: для него создаётся проксируемая запись (`proxied: true`, оранжевое облако) — проксирование и есть весь смысл режима (см. [VLESS за CDN](#vless-за-cdn-cloudflare)).
- Свежая генерация сначала проверяет занятость имени в зоне и не перезаписывает существующие чужие записи: имя перебирается до свободного.
- Повторный запуск переиспользует хосты, сохранённые в `remnanode.env`, и просто обновляет записи на текущий IP — панель и сертификаты не нужно пересобирать. Запуск без токена тоже не затирает эти имена (шаблонные `usa1`/`usa3` не подставляются).
- После создания установщик ждёт появления записей в резолвере и печатает итоговые хосты.
- HTTP-01 через порт 80 и автопродление работают как обычно: записи DNS-only, поэтому challenge доходит до ноды.

### Неинтерактивный запуск с Cloudflare

Токен в этом режиме передаётся только через env — без него установщик с `--cloudflare` остановится с подсказкой. Имена хостов сгенерируются сами, поэтому `PREFIX`, `SELF_STEAL_HOST` и DNS-плейсхолдеры задавать не нужно:

```bash
CLOUDFLARE_API_TOKEN=xxxx \
BASE_DOMAIN=example.com \
PANEL_IP=203.0.113.10 \
NODE_API_PORT=2222 \
SECRET_KEY='eyJ...' \
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh) \
  --cloudflare --non-interactive --yes
```

- если `BASE_DOMAIN` — поддомен зоны, добавьте `CLOUDFLARE_ZONE=example.com`;
- при необходимости переопределите `SERVER_IP` (например, если нода за NAT и определить публичный адрес не удалось): значение из env или из сохранённого `/root/remnanode.env` имеет приоритет над автодетектом через `ifconfig.me`/`api.ipify.org`; приватный адрес для A-записей не годится и заменяется автодетектом с предупреждением;
- готовые хосты печатаются в конце установки — подставьте их в Config Profile и Hosts панели (см. ниже).

### Что подставить в панели

Сгенерированные хосты используются вместо `<prefix>1.<domain>` / `<prefix>3.<domain>`:

- в Config Profile (`Multiselect.json`): `serverNames`, `serverName` и пути сертификатов `/etc/remna-certs/<хост>/` — в сохранённом установщиком профиле они уже подставлены;
- в Hosts (шаг 5) и виртуальном хосте (шаг 7): поле **Address**; для CDN-хостов Address — сам CDN-домен `CDN_HOST`;
- в диагностических командах и примерах README — вместо `usa1.example.com`.

Остальные шаги (префикс `PREFIX`, порт 80, HTTP-01, DNS-only) не меняются; `PREFIX` в этом режиме ни на что не влияет и остаётся только для совместимости.

## Опциональный split-routing

`Xray_template.json` — безопасный full-tunnel: весь пользовательский трафик, кроме заблокированного BitTorrent, идёт через VPN.

`Xray_template_split.json` — режим выборочной маршрутизации:

- домены из актуального на момент генерации списка [itdoginfo/allow-domains — Russia inside](https://github.com/itdoginfo/allow-domains/blob/main/Russia/inside-raw.lst) идут через балансировщик `USA`;
- дополнительно подключены отдельные списки Telegram и Google AI;
- IPv4/IPv6-подсети Telegram, Meta/Instagram и Twitter тоже идут через VPN — это важно для приложений, которые подключаются прямо к IP;
- используется публичный AdGuard DNS `94.140.14.14` и `94.140.15.15`: он блокирует известные рекламные, трекинговые и вредоносные домены;
- в split-routing запросы к AdGuard DNS также идут через VPN, поэтому DNS не раскрывается провайдеру;
- тяжёлый список `geosite:category-ads-all` не загружается в Xray, что экономит память на мобильных устройствах;
- DNS-фильтрация не блокирует рекламу, которая приходит с тех же доменов, что и контент (например, встроенную рекламу YouTube или Instagram);
- UDP/443 блокируется, чтобы приложения откатывались с QUIC на маршрутизируемый TCP;
- весь трафик, не совпавший со списком, идёт через `direct`;
- BitTorrent блокируется: выводить его через `direct`, как в исходном примере, небезопасно — клиент раскрывает реальный IP.

Для split-routing создайте второй шаблон типа **XRAY_JSON** и вставьте в него `Xray_template_split.json`. Затем назначьте его нужному виртуальному хосту или отдельной группе пользователей.

> Split-routing не является режимом полной приватности. Любой отсутствующий или новый домен пойдёт напрямую до следующего обновления списка. Для обычной VPN-подписки оставляйте `Xray_template.json`.

## Неинтерактивный запуск

```bash
BASE_DOMAIN=example.com \
PREFIX=usa \
SELF_STEAL_HOST=usa1.example.com \
XHTTP_SNI=www.gstatic.com \
XHTTP_PATH=/api/v3/sync/r1 \
PANEL_IP=203.0.113.10 \
NODE_API_PORT=2222 \
SECRET_KEY='eyJ...' \
bash <(curl -fsSL https://raw.githubusercontent.com/bami7up/multi-protocol/main/remnanode-setup.sh) \
  --non-interactive --yes
```

Для воспроизводимого деплоя версию Node нужно фиксировать конкретным тегом (иначе `latest` — это «то, что сейчас в реестре»):

```bash
NODE_IMAGE=remnawave/node:3.1.1 \
bash remnanode-setup.sh
```

Пример неинтерактивного запуска с автоматическими DNS-записями Cloudflare — в разделе [Cloudflare: создание поддоменов автоматически](#cloudflare-создание-поддоменов-автоматически).

`ENABLE_XHTTP=n` отключает XHTTP в selfsteal: установщик не спрашивает SNI и path, не пишет их в `/root/remnanode.env`, не добавляет маршрут XHTTP в Caddyfile и вырезает inbound `REALITY_XHTTP` из сохранённого Config Profile. Значение по умолчанию — `y`, то есть поведение прежних версий.

`ENABLE_CDN=y` включает VLESS за CDN (см. раздел [VLESS за CDN](#vless-за-cdn-cloudflare)): установщик дополнительно спрашивает/берёт из env `ENABLE_CDN`, `CDN_HOST`, `CDN_TRANSPORT` (`ws`, `xhttp`, `grpc`, `both`, `all`), `CDN_WS_PATH`, `CDN_XHTTP_PATH`, `CDN_GRPC_PATH` и токен Cloudflare для DNS-01 сертификата. По умолчанию — `n`, то есть без CDN, как в прежних версиях.

Без `NODE_IMAGE` используется `latest`. Установщик автоматически выберет актуальную версию образа ноды. Версия `latest` следует за upstream-релизами Remnawave Node, однако future major-ветки могут изменить API; для воспроизводимых деплоя используйте конкретный тег, например `remnawave/node:3.1.1`. Сборка маршрутизатора также воспроизводима: `Caddy v2.11.7`, `caddy-l4 v0.1.2`, `xcaddy v0.4.7` и официальный Go `1.26.9`. Архив Go проверяется по опубликованному SHA256 и ставится отдельно в `/opt/remnanode-toolchains`, не заменяя системный Go. Версии связаны: Caddy начиная с v2.11.6 для сборки требует Go >= 1.26, а `caddy-l4` собирается с Caddy v2.11.7 — пара проверяется в CI, чтобы патч Caddy не «уехал» на старый Go.

Шаблон Config Profile берётся из файла `Multiselect.json` рядом со скриптом (запуск из клона репозитория) или скачивается из `MULTISELECT_TEMPLATE_URL`. Если скачать не удалось, установщик предупредит и продолжит без сохранённого профиля — тогда вставьте `Multiselect.json` из репозитория вручную.

## Флаги

```text
--no-compose          не заменять docker-compose.yml; обновить только .env
--no-firewall         не настраивать ufw
--reset-firewall      удалить существующие правила ufw
--no-reset-firewall   не сбрасывать ufw (по умолчанию; для совместимости)
--force-dns           продолжить при несовпадении DNS и IP ноды
--ssh-port N          явно указать SSH-порт для UFW
--node-image REF      образ ноды; по умолчанию latest
--self-steal-template T
                      тема фасада self-steal (vaultdrop, mail, cloud, admin, docs)
--cloudflare          создать A-записи через Cloudflare API
--no-cloudflare       не использовать Cloudflare, даже если токен в env
-y, --yes             подтвердить вопросы yes/no
--non-interactive     брать значения из env и дефолтов
-h, --help            показать справку
```

Переменные: `BASE_DOMAIN`, `PREFIX`, `SELF_STEAL_HOST`, `ENABLE_XHTTP`, `XHTTP_SNI`, `XHTTP_PATH`, `ENABLE_CDN`, `CDN_HOST`, `CDN_TRANSPORT`, `CDN_WS_PATH`, `CDN_XHTTP_PATH`, `CDN_GRPC_PATH`, `PANEL_IP`, `NODE_API_PORT`, `SECRET_KEY`, `NODE_IMAGE`, `SELF_STEAL_TEMPLATE`, `SELF_STEAL_TEMPLATE_URL`, `MULTISELECT_TEMPLATE_URL`, `XCADDY_VERSION`, `CADDY_VERSION`, `CADDY_L4_VERSION`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE`, `NODE_DIR`, `CERT_DIR`, `ENV_STORE`.

Тема фасада выбирается переменной `SELF_STEAL_TEMPLATE` или флагом `--self-steal-template` (см. [«Фасад self-steal: темы»](#фасад-self-steal-темы)). Свой фасад можно передать через публичный HTTPS URL в `SELF_STEAL_TEMPLATE_URL` — он важнее темы. При ошибке скачивания установщик создаст минимальную локальную страницу.

## Внешние источники и воспроизводимость

Установщик ставит и собирает компоненты из сети — это перечислено таблицей, чтобы источники можно было проверить или заменить.

| Источник | Что берётся | Как зафиксировать |
|---|---|---|
| `get.docker.com` (установка через `sh`) | Docker Engine и compose-plugin, **только если docker ещё не установлен** | никак; на машинах с внутренним реестром поставьте `docker-ce` заранее — установщик увидит готовый docker и скрипт не тронет |
| `get.acme.sh` (установка через `sh`) | `acme.sh` в `/root/.acme.sh`, если его ещё нет | никак; при каждом запуске выполняется `acme.sh --upgrade --auto-upgrade`, то есть клиент ACME обновляет себя сам |
| `dl.google.com/go` (то же, что на `go.dev/dl`) | архив Go для сборки Caddy | `GO_VERSION` в скрипте + SHA256: архив проверяется до распаковки и ставится в `/opt/remnanode-toolchains` |
| GitHub Releases `caddyserver/caddy` | исходники Caddy (сборка через `xcaddy`) | `CADDY_VERSION` |
| Go-модуль `mholt/caddy-l4` | плагин layer4 | `CADDY_L4_VERSION` |
| `raw.githubusercontent.com` (ветка `main`) | темы фасада и `Multiselect.json` — если установщик запущен не из клона репозитория | `SELF_STEAL_RAW_BASE` и `MULTISELECT_TEMPLATE_URL`: можно указать свой форк, тег или коммит |
| реестр образов | образ ноды `remnawave/node` | `NODE_IMAGE`; для воспроизводимости — конкретный тег, вплоть до `@sha256:…` |

Практические следствия:

- `bash <(curl …)` доверяет содержимому ветки `main`; для аудируемого деплоя скачайте скрипт, проверьте его и запускайте из клона — тогда темы и профиль берутся из файлов рядом со скриптом, без сети;
- версии из таблицы (`GO_VERSION`, `CADDY_VERSION`, `XCADDY_VERSION`, `CADDY_L4_VERSION`) связаны между собой: Caddy начиная с v2.11.6 требует Go >= 1.26, а CI проверяет, что пины не разъехались;
- если нужна неизменность шаблонов, укажите тег или коммит в `SELF_STEAL_RAW_BASE` / `MULTISELECT_TEMPLATE_URL`; значения по умолчанию следуют за `main`.

## Диагностика

| Симптом | Что проверить |
|---|---|
| Сертификат не выпускается | A-запись ведёт прямо на ноду, Cloudflare Proxy выключен, `80/tcp` доступен, другой процесс не занимает порт 80 |
| Сертификаты перестали продлеваться | `crontab -l \| grep acme.sh` — установщик восстанавливает задание автопродления при каждом запуске; в логе установки видно, было ли оно добавлено |
| Self-steal перестал работать после включения Cloudflare | Верните self-steal, Hysteria2 записи в постоянный режим **DNS only**; Cloudflare Proxy для них несовместим с текущей схемой |
| Нода `Offline` | Node Port, `SECRET_KEY`, IP панели в UFW, `docker logs remnanode` |
| Клиент идёт на `1044x` | В Host заменить внутренний порт на публичный `443` |
| Нет виртуального хоста | Видимость ON, Hide host OFF, inbound в Internal Squad |
| Только один outbound | Рабочие хосты должны быть Hide host ON и иметь тег из `selector.pattern` |
| XHTTP не работает | Одинаковые `path` и SNI в Profile, Host и установщике |
| Клиент за CDN не подключается | В CDN-Host: Port `443` (не локальный `1044x`), Address — CDN-домен, SNI — CDN-домен (или Override SNI from address), Security layer `TLS`, path/serviceName как в установщике; запись CDN-хоста именно под оранжевым облаком |
| CDN-хост отдаёт ошибку сертификата | Между CDN и origin должен быть Full (strict): `echo \| openssl s_client -connect 127.0.0.1:9444 -servername cdn.example.com` — сертификат CDN-хоста, не самоподписанный |
| Сертификат CDN-хоста не выпускается | Это DNS-01, порт 80 не нужен: токен с правами `Zone:Read` + `Zone:DNS:Edit`, корректный `CLOUDFLARE_ZONE`; ошибка печатается в логе установки |
| gRPC за CDN не работает | Cloudflare обязан проксировать HTTP/2 (значение по умолчанию), в CDN-Host задан ALPN `h2`, serviceName начинается со слэша и не совпадает с путями ws/xhttp |
| Mihomo не подключается к REALITY | В обоих REALITY inbound'ах должно быть `minClientVer: "0.0.0"`; затем сохраните профиль и дождитесь его применения на ноде |
| UDP/443 не слушается | Hysteria2 inbound активен; порт не занят другим сервисом |
| Caddy не запускается | `journalctl -u caddy -n 100`; конфликт `443/tcp` (установщик называет занявший порт процесс и останавливается до сборки) или неверный SNI |
| BBR не активен | поддержка BBR ядром или необходимость перезагрузки |
| Нет 301 на `:80` | сайт `http://<self-steal-домен>` в Caddyfile, порт 80 открыт в UFW, `curl` не перехвачен прокси |
| Панель по IPv6 не проходит в Node API | `IPV6=yes` в `/etc/default/ufw`, правило `ufw status` с адресом панели |
| Cloudflare не создаёт записи | Токен с правами `Zone:Read` + `Zone:DNS:Edit` именно на нужную зону; для поддомена задайте `CLOUDFLARE_ZONE`; в выводе установщика видно сообщение ошибки API |

## IPv6, UFW и ACME

- Протокольные домены должны иметь только A-записи: Hysteria2 привязан к `0.0.0.0:443`, то есть к IPv4, и AAAA сломает часть клиентов. Установщик проверяет A/AAAA и предупреждает о лишних адресах.
- `PANEL_IP` может быть как IPv4-, так и IPv6-адресом. Правило UFW создаётся ровно для этого адреса; установщик проверяет, что правило появилось, а для IPv6 дополнительно предупреждает, если в `/etc/default/ufw` стоит `IPV6=no`.
- Node API защищён только firewall'ом. При `--no-firewall` установщик прямо предупреждает, что ограничение доступа к порту ноды не действует.
- Сертификаты выпускает и продлевает только `acme.sh`; Caddy и Xray получают готовые файлы из `/etc/remna-certs/<домен>/` и не управляют сертификатами сами. Для CDN-хоста сертификат выпускается тем же acme.sh, но через DNS-01 (`dns_cf`): креденшелы токена сохраняются в конфиг сертификата, поэтому cron продлевает его без участия порта 80 и без остановки Caddy.
- Поскольку `:80` занимает Caddy (постоянный 301), acme.sh получает хуки `--pre-hook`/`--post-hook`, которые останавливают Caddy на время HTTP-01 challenge и поднимают обратно. Эти же хуки сохраняются в конфиг сертификата и работают при автопродлении из cron: на несколько секунд недоступен и `443/tcp`.
- `80/tcp` должен быть свободен от посторонних сервисов (nginx, apache и т.п.): acme.sh умеет освободить порт только от Caddy.
- Если определённый публичный адрес сервера оказался приватным (сервер за NAT/CGNAT) или `PANEL_IP` совпадает с адресом самого сервера, установщик предупреждает: в таких схемах сверку DNS и правила firewall нужно читать вручную.

Лог установки: `/var/log/remnanode-setup-<дата>.log` (права `0600` — в нём адреса и детали инфраструктуры, читать может только root).

## Повторный запуск и безопасность

- `.env` с секретом создаётся с правами `0600` и принудительно приводится к ним при повторном запуске: перезапись через redirection сами права файла не меняет, а файл от старой версии мог остаться читаемым для всех.
- Установочный лог создаётся с правами `0600` — он содержит адреса и детали инфраструктуры.
- `SECRET_KEY` не печатается ни на экран, ни в установочный лог: при `--non-interactive` выводится только число символов, при интерактивном вводе символы не отображаются.
- Повторный запуск проверяет срок действия уже выпущенного сертификата acme.sh: если он нечитаем или истекает менее чем через 7 дней, выпуск выполняется заново с `--force`, а не пропускается — иначе просроченный сертификат продолжал бы работать.
- Если `443/tcp` занят посторонним процессом (nginx и т.п.), установщик останавливается сразу и называет процесс, а не после многоминутной сборки Caddy.
- Одновременно может работать только один экземпляр установщика (flock на `/run/lock/remnanode-setup.lock`): параллельный запуск не перепишет Caddyfile, `.env` и правила ufw на лету.
- После успешной сборки Caddy кэш сборки Go очищается, чтобы не занимать диск на малых VPS.
- Каждый запуск проверяет, что в crontab root есть задание автопродления acme.sh, и восстанавливает его (`acme.sh --install-cronjob`, идемпотентно) — иначе сертификаты протухли бы молча через ~90 дней.
- Сертификаты внутри контейнера перечисляются busybox-совместимо (`ls` вместо GNU `find -printf`); если том с сертификатами не смонтирован, установщик предупреждает, а не молчит.
- Ключи сертификатов монтируются в Node read-only.
- Node Port разрешается в UFW только с IP панели.
- При повторном запуске старое управляемое правило Node Port удаляется перед добавлением актуальных IP/порта панели. Остальные пользовательские правила UFW не затрагиваются.
- Повторный запуск не сбрасывает UFW и не перезапускает Docker без необходимости.
- Compose не пересоздаёт контейнер принудительно.
- Если выпуск сертификата или пересборка прерываются, EXIT-обработчик пытается сразу вернуть Caddy в рабочее состояние.
- Установщик хранит не более трёх резервных бинарников Caddy, пяти копий Caddyfile и десяти установочных логов.
- Финал считается успешным только после появления всех TCP/UDP-слушателей и прохождения TLS-проверок Vision, XHTTP и локального self-steal.
- `--reset-firewall` применяйте только на чистом сервере: он удаляет существующие правила.
- Для обновления Node измените `NODE_IMAGE` и повторите запуск. Перед сменой версии проверьте [официальные релизы](https://github.com/remnawave/panel/releases).

## Лицензия

В репозитории, как и в апстриме [`1atex/multi-protocol`](https://github.com/1atex/multi-protocol), нет файла `LICENSE`: правовая рамка не определена. Формально это значит, что использование, изменение и распространение кода требуют согласования с авторами — считать его свободным нельзя. Если планируете распространять форк или использовать его в коммерческом продукте, добавьте лицензию (например, MIT) и согласуйте её с автором апстрима.

Сообщения об уязвимостях — по процедуре из [SECURITY.md](SECURITY.md): установщик работает от root и обращается с ключами, поэтому такие находки лучше не публиковать в открытом виде.
