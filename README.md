# Goals Leads Dashboard — GitHub Pages + n8n + Zoho CRM

Веб-дашборд лидов: статический фронтенд на **GitHub Pages** + два webhook-workflow в **n8n**, которые держат весь доступ к **Zoho CRM** и **Google Sheets**. Никаких секретов в репозитории и во фронтенде.

```
┌────────────────────┐   POST /webhook/lead-create    ┌─────────────────────────┐
│  index.html        │ ─────────────────────────────► │ n8n: Lead Create        │──► Zoho: Search Contact
│  (GitHub Pages)    │   заголовок x-api-key          │  валидация, нормализация│──► Zoho: Upsert Contact
│                    │                                │  телефона, ZIP→штат/TZ, │──► Zoho: Search Deal (дедуп 2 дня)
│  Отчёт | Новый лид │   GET /webhook/leads-list      │  разбор времени связи   │──► Zoho: Upsert Deal
│  | Настройки       │ ◄───────────────────────────── │                         │──► Google Sheet «Dashboard Leads»
└────────────────────┘   JSON-массив лидов            ├─────────────────────────┤
                                                      │ n8n: Leads List         │◄── Zoho COQL (Deals + Contact)
                                                      └─────────────────────────┘
```

Логика создания лида повторяет существующие автоматизации **DEAL CREATOR** и **Facebook Form MAIN**: нормализация телефона до `+1XXXXXXXXXX`, поиск дублей по вариантам номера, окно дедупликации сделки 2 дня (стадия «Duplicates / Junk» пропускается), Owner — Ariel (`5212466000034327806`), Pipeline `Standard`, разбор «удобного времени связи» (CALL NOW / Call Scheduled, рабочие часы 8:00–23:00 ET, воскресенье → перенос, «tomorrow» никогда не CALL NOW).

## Файлы

| Файл | Назначение |
|---|---|
| `index.html` | Дашборд для GitHub Pages (без внешних зависимостей, тёмная тема, адаптив) |
| `n8n/lead-create.workflow.json` | Workflow приёма лида: `POST /webhook/lead-create` → Zoho + журнал |
| `n8n/leads-list.workflow.json` | Workflow отчёта: `GET /webhook/leads-list` → COQL по Zoho Deals |
| `.github/workflows/deploy-pages.yml` | Автодеплой дашборда на GitHub Pages |

## 1. Импорт workflow в n8n

### Вариант 0: автопилот через GitHub Actions (рекомендуется)

Один раз добавьте секрет: GitHub → репозиторий → **Settings → Secrets and variables → Actions → New repository secret** → имя `N8N_API_KEY`, значение — ключ из n8n (Settings → n8n API). После этого workflow `.github/workflows/deploy-n8n.yml` будет **автоматически** заливать изменения `n8n/*.workflow.json` в n8n при каждом push (или вручную: Actions → Deploy n8n workflows → Run workflow).

### Вариант А: вручную через n8n API с компьютера

```bash
export N8N_URL="https://dvoskin.app.n8n.cloud"
export N8N_KEY="<ключ из n8n: Settings → n8n API>"
export DASHBOARD_API_KEY="<опционально: секрет для x-api-key>"
./scripts/deploy-n8n.sh
```

Скрипт создаст (или обновит по имени) оба workflow, активирует их и попробует завести Variable `DASHBOARD_API_KEY`.

### Вариант Б: вручную

1. n8n → **Workflows → Create Workflow → ⋯ → Import from File**.
2. Импортируйте `n8n/lead-create.workflow.json`, затем `n8n/leads-list.workflow.json`.
3. Откройте каждый workflow и проверьте credentials (см. ниже), затем **Activate**.

Продакшен-URL после активации:

- `https://<ваш-инстанс>.app.n8n.cloud/webhook/lead-create` (POST)
- `https://<ваш-инстанс>.app.n8n.cloud/webhook/leads-list` (GET)

### Credentials

Workflow уже ссылаются на существующие credentials (те же, что в DEAL CREATOR):

| Нода | Credential |
|---|---|
| Все `Zoho: …` HTTP-ноды | **Zoho account** (`zohoOAuth2Api`) |
| `Sheets: Append Journal` | **Google Sheets account** (`googleSheetsOAuth2Api`) |
| `AI-Smart Parser` | **OpenAi account** (`openAiApi`) — тот же, что в DEAL CREATOR |

Если после импорта credential не подхватился (другой инстанс n8n) — откройте ноду и выберите его вручную из списка.

### Режимы приёма лида

`POST /webhook/lead-create` принимает:

1. **Структурированную форму** — поля `first_name, last_name, phone, email, city, zip, contact_time, source, interest, notes`.
2. **Сырой текст** — поле `raw_text` (окно «⚡ Quick Paste», работает как вставка в Telegram): текст разбирает клон AI-Smart Parser из DEAL CREATOR (тот же промпт и модель GPT-4.1), дальше лид идёт по общему конвейеру. Исходный текст целиком сохраняется в `Description`.
3. **Фото** — поля `photo_base64` + `photo_mime` (кнопка «📷 Attach photo» в Quick Paste): скриншот переписки, анкета или рукописная заметка распознаётся OpenAI Vision (gpt-4.1, тот же промпт) и создаёт лид. Дашборд сжимает фото на клиенте до ~1600px/JPEG.
4. **Проверка по фото** — `mode: "check"` + фото: распознаёт лида, ищет его в Zoho по вариантам телефона и возвращает `{parsed, deals, contacts, bct_matches}` — полные карточки и сравнение Best Contact Time (вкладка Lookup → «Check a lead by photo»). Ничего не создаёт.
5. **Обновление времени** — `mode: "update_bct"` + `deal_id, contact_time, timezone, current_stage`: пересчитывает Best Contact Time движком DEAL CREATOR и обновляет сделку (`Best_Contact_Time`, `Call_Scheduled_Date_Time`, `Contact_Time_Raw`; `Stage` меняется только если сделка ещё в New Deal / Call Scheduled — поздние стадии не откатываются).

### Поля Zoho, которые пишутся

- **Contact**: `First_Name`, `Last_Name`, `Phone`, `Email`, `Lead_Source`, `Best_Contact_Time`, `Client_Timezone`, `Mailing_Zip`, `Mailing_State` (город), `Contact_Time_Raw`, `Description` (интерес + заметки). Upsert по `duplicate_check_fields: ["Phone"]`.
- **Deal**: `Deal_Name`, `Stage` (`New Deal` / `Call Scheduled`), `Lead_Source`, `Phone`, `Best_Contact_Time`, `Client_Timezone`, `Timezone`, `Contact_Time_Raw`, `Contact_Name` (lookup), `Call_Scheduled_Date_Time`, `Zip_Code`, `Description`, `Pipeline: Standard`, `Owner`.

### Google Sheet — журнал

Журнал пишется в таблицу **DEAL CREATOR CHAT TRACKER** (`10Yr6hkRJK2C6PCvQ1P_t5s1VUls-LZi-1xi8N4j91Z8`), лист **`Dashboard Leads`**.

⚠️ Создайте этот лист заранее и добавьте в первую строку заголовки:

```
Added | First Name | Last Name | Phone | Email | City | ZIP | Contact Time | Best Contact Time | Source | Interest | Notes | Status | Deal Stage | Deal ID | Contact ID
```

Ошибка записи в Sheet не ломает создание лида (нода настроена «continue on error»), Zoho — источник истины.

## 2. Секретный токен `x-api-key`

Оба webhook сравнивают заголовок `x-api-key` со значением `DASHBOARD_API_KEY`:

- **n8n Cloud**: Admin Panel → ваш инстанс → **Settings → Variables** → добавьте переменную `DASHBOARD_API_KEY` с любой длинной случайной строкой (workflow читает `$vars.DASHBOARD_API_KEY`).
- **Self-hosted**: задайте переменную окружения `DASHBOARD_API_KEY=<строка>` (workflow также читает `$env.DASHBOARD_API_KEY`).

Тот же токен впишите в дашборде на вкладке «Настройки». Если переменная не задана и поле токена в дашборде пустое — проверка проходит (режим без токена); заданный с одной стороны токен даст `401`.

## 3. Отчёт (leads-list): три режима

`GET /webhook/leads-list` работает в трёх режимах:

1. **Список** (без параметров, `?limit=1..200`, `?search=строка`) — последние сделки прямо из Zoho (`GET /crm/v2/Deals`, тот же OAuth-scope, что у upsert-нод), т.е. **все** лиды из всех автоматизаций (Telegram, Facebook Forms, Instagram DM, SMS, Dashboard). Вкладки «Today» / «All» на дашборде.
2. **Журнал дашборда** (`?via=dashboard`) — вся история лидов, добавленных через дашборд, из листа Google Sheets **Dashboard Leads** (без ограничения по датам). Вкладка «Via Dashboard».
3. **Lookup** (`?lookup=<телефон или имя>`) — поиск по Zoho: телефон ищется точным совпадением по вариантам номера, имя — word-поиском; возвращаются полные карточки `{ok, term, deals:[], contacts:[]}`. Вкладка «Lookup» на дашборде.

4. **Переписка из Meta** (`?chat=<имя>&chat_phone=<10 цифр>`) — ищет диалог лида во входящих Facebook-страницы (Graph API v25.0, механика Meta AI Chat MAIN): совпадение по телефону в тексте переписки или по имени клиента; возвращает `{found, conversations:[{customer, matched_by, messages}]}`. Кнопка «💬 Load Meta chat» в Lookup. Требуется переменная n8n **`META_PAGE_TOKEN`** — page access token из ноды «Get FB Conversations» workflow «Meta AI Chat MAIN» (в репозитории токен не хранится); задаётся через `Settings → Variables` или `META_PAGE_TOKEN=... ./scripts/deploy-n8n.sh`. Пока только Facebook (Instagram — отдельным шагом).

5. **Google Sheets-отчёты** (`?sheets=list&doc=<key>` — список вкладок; `?sheet=<название вкладки>&doc=<key>` — последние 500 строк вкладки, новые сверху). Вкладка «Sheets» на дашборде. Ключи `doc`: `tracker` (DEAL CREATOR CHAT TRACKER, по умолчанию), `deals` (DEALS TRACKER), `ads` (Goals Ads Facebook Forms To CRM) — белый список зашит в ноде `Resolve Doc`. Чтение идёт тем же credential «Google Sheets account», новых доступов не требуется.

Формат массива лидов (режимы 1–2):

```json
[{ "added": "2026-07-16 10:12", "first_name": "...", "last_name": "...", "phone": "+1...",
   "zip": "...", "contact_time": "...", "source": "...", "status": "...",
   "deal_stage": "...", "deal_id": "...", "via_dashboard": true }]
```

## 4. Деплой дашборда на GitHub Pages

1. GitHub → репозиторий → **Settings → Pages → Build and deployment → Source: GitHub Actions**.
2. Workflow `.github/workflows/deploy-pages.yml` публикует корень репозитория при каждом push в основную ветку (или запустите его вручную: Actions → Deploy dashboard to GitHub Pages → Run workflow).
3. Дашборд будет доступен по адресу `https://<owner>.github.io/<repo>/`.
4. Откройте дашборд → вкладка **«Настройки»** → впишите оба webhook-URL и токен → «Сохранить». Настройки хранятся в localStorage браузера.

## 5. Проверка

```bash
# создать лид
curl -X POST 'https://<инстанс>.app.n8n.cloud/webhook/lead-create' \
  -H 'Content-Type: application/json' -H 'x-api-key: <токен>' \
  -d '{"first_name":"Test","last_name":"Lead","phone":"(803) 664-1909","zip":"33101","contact_time":"tomorrow 3pm","source":"Dashboard"}'
# → {"ok":true,"id":"...","contact_id":"...","duplicate":false,"stage":"Call Scheduled"}

# отчёт
curl 'https://<инстанс>.app.n8n.cloud/webhook/leads-list?limit=5' -H 'x-api-key: <токен>'
```

## Замечания

- **CORS**: в обеих Webhook-нодах включён `Allowed Origins: *` — n8n сам отвечает на preflight `OPTIONS`; Respond-ноды дополнительно шлют `Access-Control-Allow-Origin: *`. При желании сузьте `*` до адреса вашего Pages-сайта.
- **ZIP → штат/таймзона** решается детерминированной таблицей префиксов (без OpenAI-ноды); город берётся из поля формы.
- Ошибки отдаются строгим JSON: `400` — валидация (`{"ok":false,"error":"..."}`), `401` — неверный `x-api-key`, `500` — сбой Zoho.
- Колонки таблицы отчёта строятся динамически из ответа — при добавлении полей в workflow фронтенд менять не нужно.
