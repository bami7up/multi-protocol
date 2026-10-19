# Аудит установщика и план исправлений — авто должно быть авто

Дата: 2026-10-19
Ветка: `arena/ec6913c9-multi-protocol` (коммиты `eff5d2b` + `41be3e9`, PR #5)
Статус: план зафиксирован для реализации

## Контекст

PR #5 добавил 4-блочный мастер (`ask_choice`, `write_xray_template`, `REMNAWAVE_PANEL_URL/TOKEN/AUTO_SETUP`, `XRAY_TEMPLATE_CHOICE`) и переписал README в схему авто/ручная. UX заметно улучшился, но авто-режим обещает больше, чем делает.

---

## Аудит: что не так

### P0 — блокируют «авто» / ломают установку

1. **panel_auto_setup создаёт только Config Profile, остальное — подсказки.**
   Код `panel_auto_setup()` в `remnanode-setup.sh` (~строки 793–880) делает `POST /api/config-profiles` и печатает `note` про ноду/хосты/шаблон. README же говорит «сам создаёт поддомены, сохраняет Config Profile и помогает настроить панель через API». Пользователь ожидает полный авто-сетап без ручных шагов 1–8. Сейчас это полуавто.

2. **Неверный payload Config Profile.**
   Текущий payload: `jq -n --argjson config "$profile_json" '{name: $name, config: $config}'` где `profile_json` — весь `Multiselect.json` (уже отфильтрованный). По контракту Remnawave `POST /api/config-profiles` ожидает `{ name, config: <full Xray JSON> }` — это совпадает, но поле `config` в ответах панели вложено, а успех проверяется как `'.response != null or .success == true or .data != null'` — слишком широкое, маскирует ошибки валидации (A061: Config doesn't have inbounds и т.п.). Также имя `Multi-protocol $(date +%Y-%m-%d)` не идемпотентно и не проверяет дубликаты.

3. **Xray_template не попадает в панель вообще.**
   `write_xray_template` сохраняет файл локально, `panel_auto_setup` только пишет `note` «Загрузите вручную → Templates → XRAY_JSON». Эндпоинт панели — `POST /api/subscription-templates` (или `/api/templates` в зависимости от версии, в контракте 3.3.x — subscription-templates). Авто не делает запрос.

4. **Нода не создаётся.**
   После `docker compose up` нода работает, но в панели её нет. Для настоящего авто нужен `POST /api/nodes` с `{ name, address: SERVER_IP, port: NODE_API_PORT, configProfile: { activeConfigProfileUuid, activeInbounds }, countryCode }`. Требуется получить UUID инбаундов из созданного профиля (`GET /api/config-profiles/{uuid}/inbounds`).

5. **Хосты не создаются.**
   Нужен `POST /api/hosts` на каждый inbound: `{ inbound: { configProfileUuid, configProfileInboundUuid }, remark, address, port: 443, ... }`. Для CDN — отдельные хосты с `securityLayer: TLS`, SNI, path. Сейчас только `note`.

6. **Токен и URL не нормализуются.**
   `CF_MODE`/`REMNAWAVE_AUTO_SETUP` пишутся в `ENV_STORE` как `bool_yn` (y/n), но читаются позже как `(( VAR ))` без `parse_bool`. В `panel_auto_setup` проверяется `(( ! REMNAWAVE_AUTO_SETUP ))` — для `y`/`n` это арифметическая ошибка / неверное ветвление. Аналогично `CF_MODE` после `source ENV_STORE` остаётся строкой `y/n`, а `if (( CF_MODE ))` ожидает 0/1.

7. **Отсутствует обработка существующих ресурсов (идемпотентность).**
   Повторный запуск с тем же доменом должен находить существующий профиль по имени (`GET /api/config-profiles` → фильтр по name) и делать `PATCH` вместо `POST`, иначе дубли. То же для нод (`GET /api/nodes` по address/port) и хостов (`GET /api/hosts`). Иначе замусоривание панели.

### P1 — важно для надёжности

8. **panel_api_success слабая.**
   `jq -e '.response != null or .success == true or .data != null' or 'has("response")...'` — пропускает ошибки, где поле `response` пустое или `errors[]` есть параллельно. Должен проверять `success == true` или отсутствие `errors` + http код 2xx.

9. **panel_api не проверяет HTTP код.**
   `curl -sS --max-time 20 ...` без `-w %{http_code}` и без `fail`. 401/403/422 выглядят как «успех» если тело JSON парсится.

10. **Отсутствует retry и таймаут для panel API.**
    Сетевой сбой роняет авто-настройку без повтора. Нужен `retry 3 5 panel_api ...` как у Docker/Caddy.

11. **Не сохраняется связь профиль→нода→хосты для отката.**
    Если создание хостов частично упало, нет лога какие UUID созданы, чтобы удалить/пересоздать.

12. **Валидация PANEL_URL слабая.**
    Только `=~ ^https?://`, без удаления trailing `/`, без проверки что URL достижим до запроса токена. `panel_check_connection` делает `GET /config-profiles` и `GET /nodes` — но обе могут вернуть 200 с пустым `success=false`; проверка должна требовать именно success.

13. **Токен в ENV_STORE — риск утечки.**
    Сохранение `CLOUDFLARE_API_TOKEN` и `REMNAWAVE_API_TOKEN` в `/root/remnanode.env` (0600) удобно для повтора, но токен живёт в plaintext. Нужен комментарий про ротацию и опция не сохранять (`--no-save-token`). Минимум — предупредить в `note` и в README.

14. **flags.sh в тестах хрупкий.**
    `sed -n '/^ask_bool ENABLE_XHTTP/,/^ask PANEL_IP /p' | sed '$d'` зависит от порядка строк. После добавления `ask_choice` порядок может поехать. Нужен маркер `# -- flags block --` или явный range по комментарию.

15. **write_xray_template не проверяет выбор.**
    `XRAY_TEMPLATE_CHOICE` нормализуется к `standard|split` только в `write_xray_template`, но `ask_choice` уже пишет ключ `standard`/`split` напрямую. Если пользователь задаст `XRAY_TEMPLATE_CHOICE=Split` через env, `case "${choice,,}"` сработает, но `ask_choice` в non-interactive режиме берёт номер варианта, а не ключ — расхождение.

### P2 — полировка

16. **Имя профиля неинформативно.**
    `Multi-protocol YYYY-MM-DD` без указания домена/префикса. Лучше `multi-protocol-<BASE_DOMAIN>-YYYYMMDD` или как в README.

17. **Нет вывода итогов авто-настройки.**
    После `panel_auto_setup` не печатается сводка UUID ноды/профиля/хостов для проверки в панели.

18. **Squad не трогается.**
    Даже после создания ноды и хостов inbound'ы не попадут в подписку без включения в Internal Squad. Нужен `GET /api/internal-squads` → `PATCH /api/internal-squads/{uuid}` с добавлением inbound UUIDs.

---

## План исправлений

### Этап 1 — зафиксировать аудит (этот файл)
- [x] Создать `AUDIT_FIX_PLAN.md` и закоммитить как есть. (`97265ff`)

### Этап 2 — сделать авто реально авто (следующий коммит)

**A. Нормализация флагов (P0-6, P1-14):** ✓ done (`687c0b1` + `d0e5bd3`)
- На старте после `source ENV_STORE` прогнать `REMNAWAVE_AUTO_SETUP="$(parse_bool "$REMNAWAVE_AUTO_SETUP" 0)"` и `CF_MODE="$(parse_bool "$CF_MODE" 0)"` (как для `ASSUME_YES`).
- В `ENV_STORE` писать `bool_yn`, при чтении — сразу `parse_bool`.
- Добавить маркеры `# === flags block start/end ===` для надёжного извлечения в `env-flags-checks.sh`, обновить тест.

**B. Исправить panel_api (P1-8, P1-9, P1-12):** ✓ done (`687c0b1`)
- `panel_api()` возвращает HTTP код: `curl -sS -w "\n%{http_code}" ...`, разбирать тело и код отдельно.
- `panel_api_success()` проверяет `http_code 2xx && (.success == true или .response != null без errors)`.
- `panel_api_error()` достаёт `message || errors[].message`.
- `panel_check_connection()` требует `GET /api/config-profiles` с success.

**C. Полный panel_auto_setup (P0-1..5, P0-7, P2-16..18):** ✓ done (`687c0b1`)
  1. **Config Profile:** `GET /api/config-profiles` → найти по `name == "multi-$BASE_DOMAIN"` (или `Multi-protocol $BASE_DOMAIN`). Если есть — `PATCH /api/config-profiles/{uuid}` с `uuid + config`; иначе `POST`. Сохранить `profile_uuid`. Retry 3.
  2. **Получить inbounds:** `GET /api/config-profiles/{uuid}/inbounds` → распарсить массив `inbounds[]` (поля `uuid`, `tag`). Сохранить мапу tag→uuid.
  3. **Node:** `GET /api/nodes` → найти по `address == SERVER_IP && port == NODE_API_PORT`. Если есть — `PATCH /api/nodes/{uuid}` с обновлением `configProfile.{activeConfigProfileUuid, activeInbounds}`; иначе `POST /api/nodes` с `name: "node-$PREFIX-$BASE_DOMAIN"`, `address: SERVER_IP`, `port: NODE_API_PORT`, `countryCode: XX`, `configProfile`. Retry.
  4. **Hosts:** для каждого inbound в профиле создать хост:
     - `VLESS_VISION` → `{ remark: "VLESS Vision $PREFIX", address: VLESS_HOST, port: 443, inbound: {configProfileUuid, configProfileInboundUuid} }`
     - `XHTTP` (если ENABLE_XHTTP) → аналогично с path/sni
     - `HYSTERIA2` → `address: HY_HOST`
     - `VLESS_CDN_*` (если ENABLE_CDN) → `address: CDN_HOST`, `securityLayer: TLS`, `sni: CDN_HOST`
     Перед POST проверить `GET /api/hosts` на дубликат по `remark+address`; если есть — PATCH.
  5. **Internal Squad:** `GET /api/internal-squads` → выбрать дефолтный (первый) или создать; `PATCH` с `inbounds: [ все uuid из профиля ]`.
  6. **Subscription Template (XRAY_JSON):** `POST /api/subscription-templates` с содержимым `Xray_template.json` (или `Xray_template_split.json`). Проверить дубликат по имени.

**D. Безопасность токена (P1-13):** ✓ done — note в установщике + README security block; `--no-save-token` перенесён в Этап 4 (не критично)
- В `ENV_STORE` добавить комментарий `# Токены — ротируйте после утечки`.
- В `note` после сохранения вывести предупреждение: «Токены сохранены в ENV_STORE (0600) — ограничьте доступ».
- Добавить флаг `--no-save-token` (опционально, если успеем).

**E. Тесты и CI:** ✓ done — shellcheck пробелы пофикшены (`d0e5bd3`), CI зелёный `39233275182`; flags.sh маркеры добавлены
- Расширить `installer-funcs-checks.sh` моками panel_api (HTTP код + success).
- Обновить `env-flags-checks.sh` на новый range.
- Добавить инвариант в `validate.yml`: проверка что `panel_auto_setup` содержит `POST /api/nodes` и `POST /api/hosts`.

### Этап 3 — документация
- Обновить README раздел «Что получите» — перечислить что авто создаёт в панели (профиль, нода, хосты, squad, шаблон).
- Добавить troubleshooting для 401/422 панели.

---

## Критерии готовности

- [x] `bash --non-interactive --cloudflare` с валидным `REMNAWAVE_API_TOKEN` создаёт профиль, ноду, хосты, squad без ручных шагов — проверено моком и ручным прогоном.
- [x] Повторный запуск идемпотентен (PATCH, не дубли).
- [x] `REMNAWAVE_AUTO_SETUP=y/n` и `CF_MODE=y/n` из `ENV_STORE` корректно нормализуются. (`parse_bool` после source)
- [x] CI `validate.yml` 45+ проверок зелёные. (run `39233275182` success)

## Не делаем сейчас

- UI панели (subscription page configs) — вне scope установщика.
- Автоматическое создание пользователей/подписок — остаётся ручным.
- Поддержка нескольких нод — одна нода за запуск.
