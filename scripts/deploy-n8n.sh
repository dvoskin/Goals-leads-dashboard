#!/usr/bin/env bash
# Деплой обоих workflow в n8n через Public API (создаёт или обновляет по имени, затем активирует).
#
# Использование:
#   export N8N_URL="https://dvoskin.app.n8n.cloud"
#   export N8N_KEY="<api key из n8n: Settings → n8n API>"
#   export DASHBOARD_API_KEY="<опционально: секрет для x-api-key — попробуем создать Variable>"
#   ./scripts/deploy-n8n.sh
#
# Требуются: curl, jq.
set -euo pipefail

: "${N8N_URL:?Set N8N_URL, e.g. https://dvoskin.app.n8n.cloud}"
: "${N8N_KEY:?Set N8N_KEY (n8n Public API key)}"
API="$N8N_URL/api/v1"
AUTH=(-H "X-N8N-API-KEY: $N8N_KEY" -H "Content-Type: application/json")
DIR="$(cd "$(dirname "$0")/.." && pwd)"

api() { # method path [json-file]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "${AUTH[@]}" --data-binary "@$body" "$API$path"
  else
    curl -sS -X "$method" "${AUTH[@]}" "$API$path"
  fi
}

check_auth() {
  local resp
  resp="$(api GET "/workflows?limit=1")"
  if ! echo "$resp" | jq -e '.data' >/dev/null 2>&1; then
    echo "✗ n8n API не принял запрос. Ответ:" >&2
    echo "  $resp" >&2
    echo "  Проверьте N8N_KEY (Settings → n8n API) и N8N_URL=$N8N_URL" >&2
    exit 1
  fi
  echo "✓ Доступ к n8n API подтверждён ($N8N_URL)"
}

deploy() { # file
  local file="$1"
  local name payload id
  name="$(jq -r '.name' "$file")"
  # Public API принимает только name/nodes/connections/settings; нодам нужны id.
  payload="$(mktemp)"
  jq '{name, nodes, connections, settings}
      | .nodes |= [ .[] | .id = (.id // ("dash-" + (.name | gsub("[^A-Za-z0-9]"; "-") | ascii_downcase))) ]
      | .nodes |= [ .[] | if .type == "n8n-nodes-base.webhook" then .webhookId = (.webhookId // .parameters.path) else . end ]' \
      "$file" > "$payload"

  id="$(api GET "/workflows?limit=250" | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -1)"
  if [ -n "$id" ]; then
    echo "≫ Обновляю существующий workflow: $name (id=$id)"
    api PUT "/workflows/$id" "$payload" | jq -r '"  updated: " + .id'
  else
    echo "≫ Создаю workflow: $name"
    id="$(api POST "/workflows" "$payload" | jq -r '.id')"
    echo "  created: $id"
  fi
  rm -f "$payload"
  echo "≫ Активирую $name"
  api POST "/workflows/$id/activate" >/dev/null && echo "  active ✓"
}

check_auth
deploy "$DIR/n8n/lead-create.workflow.json"
deploy "$DIR/n8n/leads-list.workflow.json"

if [ -n "${DASHBOARD_API_KEY:-}" ]; then
  echo "≫ Пробую создать Variable DASHBOARD_API_KEY"
  RESP="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${AUTH[@]}" \
    -d "{\"key\":\"DASHBOARD_API_KEY\",\"value\":\"$DASHBOARD_API_KEY\"}" "$API/variables" || true)"
  case "$RESP" in
    2*) echo "  variable создана ✓" ;;
    *)  echo "  не удалось (HTTP $RESP) — создайте вручную: Settings → Variables → DASHBOARD_API_KEY (нужен план с Variables), либо оставьте поле токена в дашборде пустым" ;;
  esac
fi

echo
echo "Webhook-URL для вкладки «Настройки» дашборда:"
echo "  POST $N8N_URL/webhook/lead-create"
echo "  GET  $N8N_URL/webhook/leads-list"
echo
echo "Проверка (read-only):"
echo "  curl '$N8N_URL/webhook/leads-list?limit=3' -H 'x-api-key: <токен>'"
