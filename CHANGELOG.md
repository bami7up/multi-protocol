# Changelog

## [1.2.0] — 2026-11-03

### Added
- `--reconfigure`: интерактивное изменение настроек уже установленной ноды без переустановки
  (тема фасада, XHTTP/CDN, `REALITY_MIN_CLIENT_VER`, `ACME_METHOD`). Пересобирает профиль,
  XRAY-шаблон и Caddyfile, валидирует и перезапускает Caddy, обновляет панель при авто-режиме.
- `CUSTOM_CORE_URL` / `--custom-core-url`: кастомный Xray-core для ноды. Пресет `uwuray`
  (форк `MakostaDev/UwURay`) или свой `https://` URL; попадает в `.env` и compose.
- `REALITY_MIN_CLIENT_VER` / `--min-client-ver`: минимальная версия клиента REALITY.
  Дефолт `0.0.0` сохранён для совместимости с Mihomo (`1.8.2`), строгие значения — opt-in.
- `XHTTP_TARGET` / `--xhttp-target`: target REALITY для XHTTP (`host:port`, `self`/`local`).
  В мастере — выбор `external`/`local`; для `local` Caddy поднимает loopback-сайт
  `XHTTP_SNI` с `tls internal`, а публичный `443/tcp` по-прежнему идёт в Xray.
  Дефолт остаётся внешним (`www.gstatic.com:443`) до подтверждения local target тестом.
- `ACME_METHOD` / `--acme-method`: `auto|dns|http`. `auto` выбирает DNS-01 при наличии
  Cloudflare-токена, поэтому продление не останавливает Caddy и не рвёт `443/tcp`.
- `SELF_STEAL_TEMPLATE=none` и `SELF_STEAL_ROOT`: режим «свой сайт» без установки темы;
  предупреждение, если `index.html` отсутствует.
- `selfcheck.sh`: срок сертификатов, локальный TLS, CDN `525/526/530`, слушатели, диск.
- Ротация файловых логов Xray: `XRAY_LOG_DIR`, volume в compose и
  `/etc/logrotate.d/remnanode-xray` (`50M × 5`, compress, `copytruncate`).

### Changed
- Авто-тег ноды получает короткий стабильный суффикс от адреса (`QUIET_OTTER_631F`):
  две ноды с одинаковым `PREFIX` больше не смешивают `injectHosts`. Явный `NODE_TAG`
  не переписывается.
- README: явная модель угроз CDN + Hysteria2, ACME-методы, логи/диск, selfcheck,
  матрица версий и диагностика новых параметров.

## [1.1.0] — 2026-11-03

### Security
- Go для сборки Caddy обновлён до `1.26.10` (security-релиз `crypto/x509`).
- Панель Remnawave принимается только по HTTPS; `http://` разрешён лишь для
  `localhost`/приватных адресов, чтобы Bearer-токен не уходил в открытую сеть.
- Docker install script и acme.sh закреплены по commit/tag и SHA256;
  CI-бинарь Caddy проверяется по официальному `checksums.txt`.
- `Multiselect.json` с REALITY privateKey создаётся через `mktemp` и пишется с `0600`;
  `ENV_STORE` принудительно приводится к `0600`.
- Удалён флаг `--api-token`: токен в argv был виден в `ps` и истории.
- Caddy admin API отключён (`admin off`), сертификаты применяются через restart.

### Fixed
- Multi-node больше не перезаписывает чужую ноду: поиск ноды только по address,
  конфликты имени/профиля/хоста останавливают установку; remark’и хостов стабильны
  по `NODE_TAG`.
- `panel_api_success` больше не считает `{"response":null}` успехом; restart ноды
  идёт прямым POST с проверкой 2xx и не ретраится по 202.
- Internal Squad выбирается по имени `Default-Squad`, чужие отряды не трогаются.
- `openssl`/`iproute2` ставятся на шаге 0; базовые пакеты стали фатальными.
- `NODE_IMAGE` сохраняется в `ENV_STORE`; дефолт закреплён на `remnawave/node:3.4.4`.
- При смене Cloudflare-токена CDN-сертификат перевыпускается, чтобы acme.sh обновил креды.
- Чтения Panel API переведены на retry; `MULTISELECT_TEMPLATE_URL`/`SELF_STEAL_RAW_BASE`
  требуют HTTPS.
- Валидация `CERT_DIR`, `SERVER_IP`, `--ssh-port`; CF-токен очищается перед curl-config.
- `acme_cert_days_left` учитывает только ECC-сертификаты; 409 при создании ноды
  переискивается.
- Документация синхронизирована с кодом (6 вопросов, `--node-tag`, `NODE_TAG`,
  privateKey, Go `1.26.10`, `NODE_IMAGE`, `Zone:Read`, токен-ротация).

### Changed
- Установщик разбит на модули `lib/*.sh`; `remnanode-setup.sh` собирается `build.sh` и проверяется в CI.
  Тесты импортируют модули напрямую, без sed-извлечения функций.

### Added
- В быстром режиме появился выбор транспорта VLESS за CDN (`ws`, `xhttp`, `grpc`,
  `both`, `all`); раньше молча использовался только `ws`.
- `--uninstall` — удаление managed-компонентов (нода, Caddyfile, сертификаты,
  UFW-правила, env-файл) с защитой от опасных путей.
- `--dry-run` — показать план `--uninstall` без изменений.
- `--version` — вывод ревизии/тега из git.

## [0.1.0] — 2026-10-20

- Базовая версия: multi-protocol нода Remnawave, Caddy L4, VLESS Reality/XHTTP,
  Hysteria2, VLESS за CDN, авто-настройка панели, темы фасада, тесты и CI.
