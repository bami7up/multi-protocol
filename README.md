# Multi-protocol Remnawave Node

Установщик ноды Remnawave с четырьмя протоколами на одном публичном порту:

- VLESS Reality/Vision с локальным self-steal;
- VLESS XHTTP + Reality;
- Trojan TLS;
- Hysteria2.

Caddy L4 принимает `443/tcp` и распределяет соединения по SNI. Hysteria2 принимает `443/udp` напрямую. Обычный браузер на self-steal-домене получает локальный TLS-сайт в стиле закрытого файлообменника.

> Форма входа на маскировочном сайте декоративная: данные никуда не отправляются и не сохраняются.

## Совместимость с Remnawave 3.x

Проверено по официальным исходникам и документации Remnawave на 13 августа 2026 года.

| Компонент | Статус | Что проверено |
|---|---|---|
| Panel `3.0.x–3.2.x` | ✅ Совместимо | Config Profiles, Hosts, Internal Squads и XRAY_JSON `injectHosts`; REST API не используется |
| Node `3.0.0–3.1.1` | ✅ Совместимо | `NODE_PORT`, `SECRET_KEY`, host network, `NET_ADMIN`, сертификаты и Xray-core `v26.7.28` |
| Remnawave `2.x` | ⚠️ Не целевая ветка | `injectHosts` доступен с `2.6.3`, но инструкция написана для интерфейса 3.x |

Официальный compose Node 3.x использует `NODE_PORT`, `SECRET_KEY`, `network_mode: host` и `NET_ADMIN`. Установщик следует этой схеме, добавляет сертификаты, лимиты и ротацию логов, а образ фиксирует на проверенной версии `remnawave/node:3.1.1`.

Полный интеграционный тест требует живой панели, DNS и публичного IP. CI репозитория проверяет Bash/ShellCheck, JSON5-шаблоны, JavaScript фасада и форматирование. После установки на конкретном сервере выполните [проверку](#проверка-после-установки).

Официальные источники:

- [Установка Remnawave Node](https://docs.rw/install/remnawave-node)
- [Config Profiles](https://docs.rw/learn-en/config-profiles)
- [XRAY_JSON и injectHosts](https://docs.rw/learn/xray-json-advanced)
- [Образы Remnawave Node](https://github.com/remnawave/node/pkgs/container/node)

## Какой файл куда загружать

Это два разных типа шаблонов. Не меняйте их местами.

| Файл | Куда в Remnawave 3.x | Назначение |
|---|---|---|
| `Multiselect.json` | **Config Profiles → Create Config Profile** | Серверная конфигурация Xray с четырьмя inbound'ами |
| `Xray_template.json` | **Templates → XRAY_JSON** | Клиентская подписка с балансировщиком и инжектом хостов |
| `Xray_template_split.json` | **Templates → XRAY_JSON** | Опциональный split-routing: выбранные домены через VPN, остальное напрямую |
| `remnanode-setup.sh` | Запуск от `root` на ноде | Docker, Caddy L4, сертификаты, UFW и Node |
| `self-steal-site.html` | В панель не загружается | Локальный сайт для self-steal |

## Схема портов

| Публичный вход | SNI | Локальный получатель |
|---|---|---|
| `443/tcp` | self-steal-домен | Vision `127.0.0.1:10443` |
| `443/tcp` | внешний XHTTP SNI | XHTTP `127.0.0.1:10444` |
| `443/tcp` | Trojan-домен | Trojan `127.0.0.1:10445` |
| `443/tcp` | любой другой SNI | сайт `127.0.0.1:9443` |
| `443/udp` | Hysteria2-домен | Hysteria2 внутри Node |

Vision использует `target: 127.0.0.1:9443`: REALITY крадёт рукопожатие у собственного TLS-сайта. XHTTP оставлен с внешним target, потому что локальный XHTTP+REALITY self-steal имеет [известную проблему в Xray-core](https://github.com/XTLS/Xray-core/issues/5923).

## Требования

- отдельный сервер ноды с Debian 11/12 или Ubuntu 20.04+;
- `amd64` или `arm64`, root-доступ;
- желательно от 1 GB RAM и 3 GB свободного места;
- Remnawave Panel 3.x;
- публичный IPv4 ноды и IP панели;
- три A-записи на IP ноды.

Пример для префикса `usa`:

| A-запись | Назначение |
|---|---|
| `usa1.example.com` | Reality/Vision self-steal |
| `usa2.example.com` | Trojan TLS |
| `usa3.example.com` | Hysteria2 TLS |

До запуска проверьте DNS и доступность `80/tcp`, `443/tcp`, `443/udp`. Node Port, например `2222/tcp`, должен быть доступен только с IP панели.

## Пошаговая установка для Remnawave 3.x

### 1. Создайте серверный Config Profile

Откройте **Config Profiles → Create Config Profile** и вставьте `Multiselect.json`.

Замените плейсхолдеры:

| Плейсхолдер | Пример |
|---|---|
| `<prefix>1.<domain>` | `usa1.example.com` |
| `<prefix>2.<domain>` | `usa2.example.com` |
| `<prefix>3.<domain>` | `usa3.example.com` |

Проверьте inbound'ы:

| Tag | Listen | Port | Критичное поле |
|---|---|---:|---|
| `REALITY_VISION` | `127.0.0.1` | `10443` | `target: 127.0.0.1:9443`, self-steal-домен в `serverNames` |
| `REALITY_XHTTP` | `127.0.0.1` | `10444` | внешний SNI в `serverNames` |
| `TROJAN` | `127.0.0.1` | `10445` | сертификаты в `/etc/remna-certs/<домен>/` |
| `HYSTERIA2` | `0.0.0.0` | `443/udp` | сертификат Hysteria2-домена |

`privateKey`, `shortIds` и массивы `clients` оставьте под управлением Remnawave.

### 2. Создайте ноду

Откройте **Nodes → Management → +**:

1. Укажите публичный IP ноды.
2. Укажите Node Port, например `2222`.
3. Скопируйте выданный панелью `SECRET_KEY`.
4. Выберите Config Profile из шага 1.
5. Активируйте все четыре inbound'а и сохраните ноду.

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

### 5. Создайте четыре рабочих хоста

В **Hosts** создайте по хосту для каждого inbound'а. Всем четырём задайте одинаковый тег, например `USA`, включите видимость и **Hide host**.

| Inbound | Address | Публичный port | Tag | Hide host |
|---|---|---:|---|---|
| `REALITY_VISION` | `usa1.example.com` | `443` | `USA` | ON |
| `REALITY_XHTTP` | `usa1.example.com` | `443` | `USA` | ON |
| `TROJAN` | `usa2.example.com` | `443` | `USA` | ON |
| `HYSTERIA2` | `usa3.example.com` | `443` | `USA` | ON |

Для первых трёх хостов вручную укажите публичный порт `443`. Порты `10443–10445` локальные и не должны попадать клиентам.

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

Итого: четыре скрытых рабочих хоста и один видимый виртуальный.

### 8. Добавьте inbound'ы в Internal Squad

Откройте **Internal Squads** и включите все inbound'ы, к которым привязаны пять хостов. Иначе виртуальный хост не попадёт в подписку.

## Опциональный split-routing

`Xray_template.json` — безопасный full-tunnel: весь пользовательский трафик, кроме заблокированного BitTorrent, идёт через VPN.

`Xray_template_split.json` — режим выборочной маршрутизации:

- домены из актуального на момент генерации списка [itdoginfo/allow-domains — Russia inside](https://github.com/itdoginfo/allow-domains/blob/main/Russia/inside-raw.lst) идут через балансировщик `USA`;
- запросы к Cloudflare DNS `1.1.1.1` и `1.0.0.1` также идут через VPN;
- реклама из `geosite:category-ads-all` блокируется;
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
NODE_IMAGE=remnawave/node:3.1.1 \
bash remnanode-setup.sh
```

Без `NODE_IMAGE` используется `remnawave/node:3.1.1`. Версия зафиксирована намеренно: будущий `latest` может перейти на несовместимую major-ветку.

## Флаги

```text
--no-compose          не заменять docker-compose.yml; обновить только .env
--no-firewall         не настраивать ufw
--reset-firewall      удалить существующие правила ufw
--force-dns           продолжить при несовпадении DNS и IP ноды
--ssh-port N          явно указать SSH-порт для UFW
--node-image REF      образ ноды; по умолчанию remnawave/node:3.1.1
-y, --yes             подтвердить вопросы yes/no
--non-interactive     брать значения из env и дефолтов
-h, --help            показать справку
```

Переменные: `BASE_DOMAIN`, `PREFIX`, `SELF_STEAL_HOST`, `XHTTP_SNI`, `XHTTP_PATH`, `PANEL_IP`, `NODE_API_PORT`, `SECRET_KEY`, `NODE_IMAGE`, `SELF_STEAL_TEMPLATE_URL`, `XCADDY_VERSION`, `CADDY_L4_VERSION`, `NODE_DIR`, `CERT_DIR`, `ENV_STORE`.

Свой фасад можно передать через публичный HTTPS URL в `SELF_STEAL_TEMPLATE_URL`. При ошибке установщик создаст минимальную локальную страницу.

## Проверка после установки

```bash
docker ps --filter name=remnanode
docker logs remnanode --tail 120
docker exec -it remnanode tail -f /var/log/xray/current
systemctl status caddy --no-pager
ss -lntup | grep -E ':443|:9443|:10443|:10444|:10445'
ufw status numbered
```

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
- `10443–10445` слушаются только на `127.0.0.1`;
- XRAY_JSON содержит `proxy`, `proxy-2`, `proxy-3`, `proxy-4`;
- клиент подключается, балансировщик видит четыре outbound'а.

## Диагностика

| Симптом | Что проверить |
|---|---|
| Сертификат не выпускается | A-запись, `80/tcp`, другой процесс на порту 80 |
| Нода `Offline` | Node Port, `SECRET_KEY`, IP панели в UFW, `docker logs remnanode` |
| Клиент идёт на `1044x` | В Host заменить внутренний порт на публичный `443` |
| Нет виртуального хоста | Видимость ON, Hide host OFF, inbound в Internal Squad |
| Только один outbound | Рабочие хосты должны быть Hide host ON и иметь тег из `selector.pattern` |
| XHTTP не работает | Одинаковые `path` и SNI в Profile, Host и установщике |
| Trojan не стартует | Пути `/etc/remna-certs/<домен>/...` в Config Profile |
| UDP/443 не слушается | Hysteria2 inbound активен; порт не занят другим сервисом |
| Caddy не запускается | `journalctl -u caddy -n 100`; конфликт `443/tcp` или неверный SNI |
| BBR не активен | поддержка BBR ядром или необходимость перезагрузки |

Лог установки: `/var/log/remnanode-setup-<дата>.log`.

## Повторный запуск и безопасность

- `.env` с секретом создаётся с правами `0600`.
- Ключи сертификатов монтируются в Node read-only.
- Node Port разрешается в UFW только с IP панели.
- Повторный запуск не сбрасывает UFW и не перезапускает Docker без необходимости.
- Compose не пересоздаёт контейнер принудительно.
- `--reset-firewall` применяйте только на чистом сервере: он удаляет существующие правила.
- Для обновления Node измените `NODE_IMAGE` и повторите запуск. Перед сменой версии проверьте [официальные релизы](https://github.com/remnawave/panel/releases).
