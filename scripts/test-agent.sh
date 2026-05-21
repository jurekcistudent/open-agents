#!/usr/bin/env bash
#
# End-to-end smoke test for the agent stack, driven by curl.
#
# What it does:
#   1. Mints a session cookie for the test bot via POST /api/dev/session
#   2. Creates a chat session via POST /api/sessions
#   3. Waits for the Vercel sandbox to become active
#   4. Sends a message via POST /api/chat and streams the response
#
# Requirements:
#   - dev server running on $BASE (default http://localhost:3000)
#   - TEST_AUTH_SECRET set in apps/web/.env.local (or exported in the shell)
#   - VERCEL_OIDC_TOKEN valid in the dev server's environment
#   - jq installed
#
# Usage:
#   bash scripts/test-agent.sh
#   bash scripts/test-agent.sh "Your custom prompt here"
#   BASE=http://localhost:3001 bash scripts/test-agent.sh
#
# See docs/agents/endpoints.md for the full curl-based testing guide.

set -euo pipefail

BASE="${BASE:-http://localhost:3000}"
PROMPT="${1:-Reply with just the digits: 42}"

# Resolve TEST_AUTH_SECRET: prefer exported env, fall back to .env.local.
if [ -z "${TEST_AUTH_SECRET:-}" ]; then
  if [ -f apps/web/.env.local ]; then
    TEST_AUTH_SECRET=$(grep -E '^TEST_AUTH_SECRET=' apps/web/.env.local | head -1 | sed -E 's/^TEST_AUTH_SECRET=//')
  fi
fi

if [ -z "${TEST_AUTH_SECRET:-}" ]; then
  echo "TEST_AUTH_SECRET is not set. Export it or add it to apps/web/.env.local." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (brew install jq)." >&2
  exit 1
fi

echo "1. Minting bot session cookie..."
MINT=$(curl -s -X POST "$BASE/api/dev/session" -H "X-Test-Auth: $TEST_AUTH_SECRET")
COOKIE=$(echo "$MINT" | jq -r .header)
USER_ID=$(echo "$MINT" | jq -r .user.id)
if [ -z "$COOKIE" ] || [ "$COOKIE" = "null" ]; then
  echo "Failed to mint session. Response:" >&2
  echo "$MINT" >&2
  exit 1
fi
echo "   bot user: $USER_ID"

echo
echo "2. Creating a chat session (kicks off Vercel sandbox provisioning)..."
CREATE=$(curl -s -X POST "$BASE/api/sessions" \
  -H "Cookie: $COOKIE" \
  -H "content-type: application/json" \
  -d '{}')
SESSION_ID=$(echo "$CREATE" | jq -r .session.id)
CHAT_ID=$(echo "$CREATE" | jq -r .chat.id)
MODEL=$(echo "$CREATE" | jq -r .chat.modelId)
if [ "$SESSION_ID" = "null" ] || [ -z "$SESSION_ID" ]; then
  echo "Failed to create session. Response:" >&2
  echo "$CREATE" >&2
  exit 1
fi
echo "   sessionId: $SESSION_ID"
echo "   chatId:    $CHAT_ID"
echo "   model:     $MODEL"

echo
echo "3. Waiting for sandbox to become active..."
for i in $(seq 1 30); do
  STATUS=$(curl -s "$BASE/api/sandbox/status?sessionId=$SESSION_ID" -H "Cookie: $COOKIE")
  STATE=$(echo "$STATUS" | jq -r '.lifecycle.state')
  printf "   [%2d] %s\n" "$i" "$STATE"
  if [ "$STATE" = "active" ]; then
    break
  fi
  if [ "$STATE" = "failed" ]; then
    echo "   sandbox provisioning failed — check VERCEL_OIDC_TOKEN in the dev server env." >&2
    echo "   full status:" >&2
    echo "$STATUS" | jq . >&2
    exit 1
  fi
  sleep 4
done

if [ "$STATE" != "active" ]; then
  echo "   gave up waiting after ~2 minutes." >&2
  exit 1
fi

echo
echo "4. Sending message: \"$PROMPT\""
echo "   (streaming response below — text-delta chunks form the agent reply)"
echo "----------------------------------------"
PAYLOAD=$(jq -n \
  --arg s "$SESSION_ID" \
  --arg c "$CHAT_ID" \
  --arg id "msg_$(date +%s)" \
  --arg text "$PROMPT" \
  '{
    sessionId: $s,
    chatId: $c,
    messages: [{
      id: $id,
      role: "user",
      parts: [{ type: "text", text: $text }]
    }]
  }')

curl -sN -X POST "$BASE/api/chat" \
  -H "Cookie: $COOKIE" \
  -H "content-type: application/json" \
  -d "$PAYLOAD"

echo
echo "----------------------------------------"
echo
echo "To send a follow-up to the same chat:"
echo "  SESSION_ID=$SESSION_ID"
echo "  CHAT_ID=$CHAT_ID"
echo "  curl -s \"$BASE/api/sessions/\$SESSION_ID/chats/\$CHAT_ID\" -H \"Cookie: \$COOKIE\""
echo "  # then POST /api/chat with messages = (prior history) + (new user turn)"
