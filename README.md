# Multi-protocol Remnawave Node

Установщик ноды Remnawave с тремя протоколами на одном публичном порту:

- VLESS Reality/Vision с локальным self-steal;
- VLESS XHTTP + Reality;
- Hysteria2.

Caddy L4 принимает `443/tcp` и распределяет соединения по SNI. На `80/tcp` Caddy отвечает постоянным 301 на HTTPS с сохранением пути и query string. Hysteria2 принимает `443/udp` напрямую. Обычный браузер на self-steal-домене получает локальный TLS-сайт в стиле закрытого файлообменника.

> Форма входа на маскировочном сайте декоративная: данные никуда не отправляются и не сохраняются.

## Совместимость с Remnawave 3.x

Проверено по официальным исходникам и документации Remnawave на 13 августа 2026 года.

| Компонент | Статус | Что проверено |
|---|---|---|
| Panel `3.0.x–3.2.x` | ✅ Совместимо | Config Profiles, Hosts, Internal Squads и XRAY_JSON `injectHosts`; REST API не используется |
| Node `3.0.0–3.1.1` | ✅ Совместимо | `NODE_PORT`, `SECRET_KEY`, host network, `NET_ADMIN`, сертификаты и Xray-core `v26.7.28`; форк smux не требуется |
| Remnawave `2.x` | ⚠️ Не целевая ветка | `injectHosts` доступен с `2.6.3`, но инструкция написана для интерфейса 3.x |

Официальный compose Node 3.x использует `NODE_PORT`, `SECRET_KEY`, `network_mode: host` и `NET_ADMIN`. Установщик следует этой схеме, добавляет сертификаты, лимиты и ротацию логов, а образ по умолчанию `latest`. Для фиксации версии используйте `NODE_IMAGE=remnawave/node:3.1.1`.

Оба REALITY inbound'а содержат `minClientVer: "0.0.0"`. Это сохраняет совместимость с Mihomo и другими клиентами, которые некорректно определялись новым Xray-core. Параметры `smux` и `brutal-opts` в этом профиле не используются, поэтому `remnanode-smux`, модуль `tcp-brutal` и замена штатного ядра для данной конфигурации не нужны.

Полный интеграционный тест требует живой панели, DNS и публичного IP. CI репозитория проверяет Bash/ShellCheck, JSON5-шаблоны, JavaScript фасада, форматирование, а также поднимает настоящий Caddy и прогоняет HTTP-слой именно того Caddyfile, который генерирует установщик (`tests/caddy-http-checks.sh`: 301 с сохранением URI, HSTS, TLS 1.2/1.3, запрет TLS 1.0/1.1). После установки на конкретном сервере выполните [проверку](#проверка-после-установки).

Официальные источники:

- [Установка Remnawave Node](https://docs.rw/install/remnawave-node)
- [Config Profiles](https://docs.rw/learn-en/config-profiles)
- [XRAY_JSON и injectHosts](https://docs.rw/learn/xray-json-advanced)
- [Образы Remnawave Node](https://github.com/remnawave/node/pkgs/container/node)
- [Зависимость caddy-l4 v0.1.2 от Caddy v2.11.4](https://github.com/mholt/caddy-l4/blob/v0.1.2/go.mod)
- [Официальные архивы и SHA256 Go](https://go.dev/dl/)

## Какой файл куда загружать

Это два разных типа шаблонов. Не меняйте их местами.

| Файл | Куда в Remnawave 3.x | Назначение |
|---|---|---|
| `Multiselect.json` | **Config Profiles → Create Config Profile** | Серверная конфигурация Xray с тремя inbound'ами |
| `Xray_template.json` | **Templates → XRAY_JSON** | Клиентская подписка с балансировщиком и инжектом хостов |
| `Xray_template_split.json` | **Templates → XRAY_JSON** | Опциональный split-routing: выбранные домены через VPN, остальное напрямую |
| `remnanode-setup.sh` | Запуск от `root` на ноде | Docker, Caddy L4, сертификаты, UFW и Node |
| `self-steal-site.html` | В панель не загружается | Локальный сайт для self-steal |

## Схема портов

| Публичный вход | SNI | Локальный получатель |
|---|---|---|
| `443/tcp` | self-steal-домен | Vision `127.0.0.1:10443` |
| `443/tcp` | внешний XHTTP SNI | XHTTP `127.0.0.1:10444` |
| `443/tcp` | любой другой SNI | сайт `127.0.0.1:9443` |
| `443/udp` | Hysteria2-домен | Hysteria2 внутри Node |
| `80/tcp` | self-steal-домен | постоянный 301 на HTTPS с сохранением пути и query |

Vision использует `target: 127.0.0.1:9443`: REALITY крадёт рукопожатие у собственного TLS-сайта. XHTTP оставлен с внешним target, потому что локальный XHTTP+REALITY self-steal имеет [известную проблему в Xray-core](https://github.com/XTLS/Xray-core/issues/5923).

## Требования

- отдельный сервер ноды с Debian 11/12 или Ubuntu 20.04+ (на более старых версиях установщик предупредит о несоответствии минимума);
- `amd64` или `arm64`, root-доступ;
- желательно от 1 GB RAM и 3 GB свободного места;
- Remnawave Panel 3.x;
- публичный IPv4 ноды и IPv4/IPv6-адрес панели;
- две A-записи на IP ноды (`usa1` и `usa3`) и отсутствие AAAA-записей на протокольных доменах.

Пример для префикса `usa`:

| A-запись | Назначение |
|---|---|
| `usa1.example.com` | Reality/Vision self-steal |
| `usa3.example.com` | Hysteria2 TLS |

> [!IMPORTANT]
> Все протокольные записи должны постоянно работать в режиме **DNS only**. Если DNS управляется через Cloudflare, оставьте для них серое облако и не включайте Proxy после выпуска сертификатов. Cloudflare завершает TLS на своей стороне, поэтому исходный TLS ClientHello не доходит до Caddy/Reality и self-steal перестаёт работать. Обычный Cloudflare Proxy также ломает прямой Hysteria2 и не проксирует UDP-трафик Hysteria2. Оранжевое облако допустимо только для отдельного обычного веб-домена, который не используется этими протоколами.

Не создавайте AAAA-записи для этих доменов: Hysteria2 в профиле привязан к `0.0.0.0:443`, то есть только к IPv4. При наличии AAAA часть клиентов выберет IPv6 и получит нестабильное подключение. Установщик проверяет все A/AAAA-записи и предупреждает о лишних адресах.

До запуска проверьте DNS и доступность `80/tcp`, `443/tcp`, `443/udp`. Node Port, например `2222/tcp`, должен быть доступен только с IP панели.

Установщик выпускает и продлевает сертификаты через HTTP-01 в standalone-режиме. Поэтому A-записи должны вести прямо на публичный IPv4 ноды, а `80/tcp` должен быть доступен из интернета не только при первой установке, но и при автоматическом продлении. Поскольку `80/tcp` занимает Caddy, установщик передаёт acme.sh хуки `--pre-hook`/`--post-hook`, которые останавливают и поднимают Caddy вокруг challenge; acme.sh сохраняет их и применяет точно так же при автопродлении из cron. Порт 80 при этом должен быть свободен от посторонних сервисов (nginx, apache и т.п.).

## Пошаговая установка для Remnawave 3.x

### 1. Создайте серверный Config Profile

Откройте **Config Profiles → Create Config Profile** и вставьте `Multiselect.json`.

Замените плейсхолдеры:

| Плейсхолдер | Пример |
|---|---|
| `<prefix>1.<domain>` | `usa1.example.com` |
| `<prefix>3.<domain>` | `usa3.example.com` |

Проверьте inbound'ы:

| Tag | Listen | Port | Критичное поле |
|---|---|---:|---|
| `REALITY_VISION` | `127.0.0.1` | `10443` | `target: 127.0.0.1:9443`, `minClientVer: "0.0.0"`, self-steal-домен в `serverNames` |
| `REALITY_XHTTP` | `127.0.0.1` | `10444` | внешний SNI в `serverNames`, `minClientVer: "0.0.0"` |
| `HYSTERIA2` | `0.0.0.0` | `443/udp` | сертификат Hysteria2-домена |

`privateKey`, `shortIds` и массивы `clients` оставьте под управлением Remnawave.

### 2. Создайте ноду

Откройте **Nodes → Management → +**:

1. Укажите публичный IP ноды.
2. Укажите Node Port, например `2222`.
3. Скопируйте выданный панелью `SECRET_KEY`.
4. Выберите Config Profile из шага 1.
5. Активируйте все три inbound'а и сохраните ноду.

Сгенерированный панелью compose отдельно запускать не нужно: установщик создаёт совместимый compose сам. Нужны только `SECRET_KEY`, IP и Node Port.

### 3. Запустите установщик на ноде

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

Скрипт спросит базовый домен, префикс, self-steal-домен, внешний SNI и путь XHTTP, IP панели, Node Port и `SECRET_KEY`. SSH-порт определяется автоматически; при необходимости передайте `--ssh-port N`. Ответы сохраняются в `/root/remnanode.env`.

### 4. Проверьте статус ноды

В **Nodes → Management** нода должна стать `Online`. Если она offline, сначала проверяйте Node Port, `SECRET_KEY` и UFW — хосты и клиентский шаблон на этот статус не влияют.

### 5. Создайте три рабочих хоста

В **Hosts** создайте по хосту для каждого inbound'а. Всем трём задайте одинаковый тег, например `USA`, включите видимость и **Hide host**.

| Inbound | Address | Публичный port | Tag | Hide host |
|---|---|---:|---|---|
| `REALITY_VISION` | `usa1.example.com` | `443` | `USA` | ON |
| `REALITY_XHTTP` | `usa1.example.com` | `443` | `USA` | ON |
| `HYSTERIA2` | `usa3.example.com` | `443` | `USA` | ON |

Для первых двух хостов вручную укажите публичный порт `443`. Порты `10443–10444` локальные и не должны попадать клиентам.

В XHTTP Host укажите те же `path` и внешний SNI, что в Config Profile и установщике.

### 6. Создайте XRAY_JSON-шаблон

Откройте **Templates → XRAY_JSON** и вставьте `Xray_template.json`.

Если используете тег не `USA`, замените его в:

- `routing.balancers[].tag`;
- `remnawave.injectHosts[].selector.pattern`.

`tagPrefix: "proxy"`, `routing.balancers[].selector: ["proxy"]` и `burstObservatory.subjectSelector: ["proxy"]` должны совпадать.

### 7. Создайте виртуальный хост

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

Итого: три скрытых рабочих хоста и один видимый виртуальный.

### 8. Добавьте inbound'ы в Internal Squad

Откройте **Internal Squads** и включите все inbound'ы, к которым привязаны четыре хоста. Иначе виртуальный хост не попадёт в подписку.

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

Для воспроизводимого деплоя можно зафиксировать Node:

```bash
NODE_IMAGE=latest \
bash remnanode-setup.sh
```

Без `NODE_IMAGE` используется `latest`. Установщик автоматически выберет актуальную версию образа ноды. Версия `latest` следует за upstream-релизами Remnawave Node, однако future major-ветки могут изменить API; для воспроизводимых деплоя используйте конкретный тег, например `remnawave/node:3.1.1`. Сборка маршрутизатора также воспроизводима: `Caddy v2.11.4`, `caddy-l4 v0.1.2`, `xcaddy v0.4.5` и официальный Go `1.25.1`. Архив Go проверяется по опубликованному SHA256 и ставится отдельно в `/opt/remnanode-toolchains`, не заменяя системный Go.

## Флаги

```text
--no-compose          не заменять docker-compose.yml; обновить только .env
--no-firewall         не настраивать ufw
--reset-firewall      удалить существующие правила ufw
--no-reset-firewall   не сбрасывать ufw (по умолчанию; для совместимости)
--force-dns           продолжить при несовпадении DNS и IP ноды
--ssh-port N          явно указать SSH-порт для UFW
--node-image REF      образ ноды; по умолчанию latest
-y, --yes             подтвердить вопросы yes/no
--non-interactive     брать значения из env и дефолтов
-h, --help            показать справку
```

Переменные: `BASE_DOMAIN`, `PREFIX`, `SELF_STEAL_HOST`, `XHTTP_SNI`, `XHTTP_PATH`, `PANEL_IP`, `NODE_API_PORT`, `SECRET_KEY`, `NODE_IMAGE`, `SELF_STEAL_TEMPLATE_URL`, `XCADDY_VERSION`, `CADDY_VERSION`, `CADDY_L4_VERSION`, `NODE_DIR`, `CERT_DIR`, `ENV_STORE`.

Свой фасад можно передать через публичный HTTPS URL в `SELF_STEAL_TEMPLATE_URL`. При ошибке установщик создаст минимальную локальную страницу.

## Проверка после установки

```bash
docker ps --filter name=remnanode
docker logs remnanode --tail 120
docker exec -it remnanode tail -f /var/log/xray/current
systemctl status caddy --no-pager
ss -lntup | grep -E ':80|:443|:9443|:10443|:10444'
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

Ожидаемый итог:

- нода `Online`;
- `443/tcp` слушает Caddy, `443/udp` — Xray/Hysteria2;
- `10443–10444` слушаются только на `127.0.0.1`;
- XRAY_JSON содержит `proxy`, `proxy-2`, `proxy-3`;
- `http://usa1.example.com/<любой-путь>?x=1` отдаёт `301` c `Location: https://usa1.example.com/<любой-путь>?x=1`;
- клиент подключается, балансировщик видит три outbound'а.

## Диагностика

| Симптом | Что проверить |
|---|---|
| Сертификат не выпускается | A-запись ведёт прямо на ноду, Cloudflare Proxy выключен, `80/tcp` доступен, другой процесс не занимает порт 80 |
| Сертификаты перестали продлеваться | `crontab -l \| grep acme.sh` — установщик восстанавливает задание автопродления при каждом запуске; в логе установки видно, было ли оно добавлено |
| Self-steal перестал работать после включения Cloudflare | Верните self-steal, Hysteria2 записи в постоянный режим **DNS only**; Cloudflare Proxy для них несовместим с текущей схемы |
| Нода `Offline` | Node Port, `SECRET_KEY`, IP панели в UFW, `docker logs remnanode` |
| Клиент идёт на `1044x` | В Host заменить внутренний порт на публичный `443` |
| Нет виртуального хоста | Видимость ON, Hide host OFF, inbound в Internal Squad |
| Только один outbound | Рабочие хосты должны быть Hide host ON и иметь тег из `selector.pattern` |
| XHTTP не работает | Одинаковые `path` и SNI в Profile, Host и установщике |
| Mihomo не подключается к REALITY | В обоих REALITY inbound'ах должно быть `minClientVer: "0.0.0"`; затем сохраните профиль и дождитесь его применения на ноде |
| UDP/443 не слушается | Hysteria2 inbound активен; порт не занят другим сервисом |
| Caddy не запускается | `journalctl -u caddy -n 100`; конфликт `443/tcp` (установщик называет занявший порт процесс и останавливается до сборки) или неверный SNI |
| BBR не активен | поддержка BBR ядром или необходимость перезагрузки |
| Нет 301 на `:80` | сайт `http://<self-steal-домен>` в Caddyfile, порт 80 открыт в UFW, `curl` не перехвачен прокси |
| Панель по IPv6 не проходит в Node API | `IPV6=yes` в `/etc/default/ufw`, правило `ufw status` с адресом панели |

## IPv6, UFW и ACME

- Протокольные домены должны иметь только A-записи: Hysteria2 привязан к `0.0.0.0:443`, то есть к IPv4, и AAAA сломает часть клиентов. Установщик проверяет A/AAAA и предупреждает о лишних адресах.
- `PANEL_IP` может быть как IPv4-, так и IPv6-адресом. Правило UFW создаётся ровно для этого адреса; установщик проверяет, что правило появилось, а для IPv6 дополнительно предупреждает, если в `/etc/default/ufw` стоит `IPV6=no`.
- Node API защищён только firewall'ом. При `--no-firewall` установщик прямо предупреждает, что ограничение доступа к порту ноды не действует.
- Сертификаты выпускает и продлевает только `acme.sh`; Caddy и Xray получают готовые файлы из `/etc/remna-certs/<домен>/` и не управляют сертификатами сами.
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
