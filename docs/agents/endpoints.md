# Testing the App from the Command Line

The app is designed so every user-facing feature is reachable via a curl-able HTTP endpoint — the same endpoints the browser uses. This means an agent (or human) working on the codebase can verify changes end-to-end without signing in through a browser.

This document covers:

1. How to authenticate curl requests with `POST /api/dev/session`
2. The endpoint surface and how to find what you need
3. A few worked examples

## Authenticating with curl

The browser authenticates via OAuth (Vercel or GitHub) and stores a Better Auth session cookie. To do the same from curl, use the dev-only endpoint that mints a real session cookie for a dedicated **test bot user**.

The endpoint cannot impersonate real users. It only ever mints a session for a single hardcoded bot identity (user id `__test_bot__`, username `test-bot`). The bot is auto-created the first time the endpoint is called.

### Prerequisites

Set these in your local `.env` (or via Vercel preview env vars):

```bash
# Generate with: openssl rand -hex 32
TEST_AUTH_SECRET=...64+ hex characters...

# Only needed to enable in a local `next start` build (NODE_ENV=production
# without VERCEL_ENV). Not needed for `next dev` or Vercel previews.
OPEN_AGENTS_ALLOW_TEST_AUTH=true
```

The endpoint is disabled on production deployments (`VERCEL_ENV=production`) regardless of these vars.

### Minting a session

```bash
curl -s -X POST http://localhost:3000/api/dev/session \
  -H "X-Test-Auth: $TEST_AUTH_SECRET"
```

No request body is needed. Any body sent is ignored.

Response:

```json
{
  "cookie": {
    "name": "better-auth.session_token",
    "value": "<token>.<signature>"
  },
  "header": "better-auth.session_token=<token>.<signature>",
  "token": "<token>",
  "expiresAt": "2026-05-21T15:30:00.000Z",
  "user": { "id": "__test_bot__", "username": "test-bot" }
}
```

The session lasts 1 hour. The bot user owns its own sessions, chats, and sandboxes — entirely separate from any real user's data.

### Using the session in subsequent requests

```bash
# Stash the cookie header
COOKIE=$(curl -s -X POST http://localhost:3000/api/dev/session \
  -H "X-Test-Auth: $TEST_AUTH_SECRET" | jq -r .header)

# Use it on any authenticated endpoint
curl -s "http://localhost:3000/api/auth/info" -H "Cookie: $COOKIE"
```

### Security boundary

- The endpoint can ONLY mint sessions for the dedicated bot user (id `__test_bot__`). Real users cannot be impersonated, by design.
- 404 in production deployments (`VERCEL_ENV=production`).
- 404 if `TEST_AUTH_SECRET` is unset or shorter than 64 hex characters.
- 401 on a missing or wrong `X-Test-Auth` header (constant-time comparison).
- The bot user id is a fixed sentinel (`__test_bot__`, 12 chars) that cannot collide with Better Auth's nanoid-generated user IDs (21 chars), so OAuth signups cannot become the bot.
- Every successful mint is logged.
- The signed cookie is identical in structure to a browser session — no auth bypass logic runs in any other handler.

## Endpoint surface

Endpoints live under `apps/web/app/api/`. The directory structure maps to the URL — for example `apps/web/app/api/sessions/[sessionId]/chats/route.ts` serves `GET/POST /api/sessions/:sessionId/chats`.

Run this to list all current routes:

```bash
find apps/web/app/api -name "route.ts" | sed 's|.*/api/||; s|/route.ts||' | sort
```

Most routes follow the same conventions:

- Authentication via the Better Auth session cookie (`Cookie: better-auth.session_token=...`).
- JSON request and response bodies.
- Validation with Zod; invalid input returns `400`.
- Sessions belong to users — `:sessionId` and `:chatId` must reference rows owned by the authenticated user.

## Worked examples

### Create a session and send a message

```bash
SECRET="$TEST_AUTH_SECRET"
BASE="http://localhost:3000"

# 1. Mint a session cookie (for the test bot user)
COOKIE=$(curl -s -X POST "$BASE/api/dev/session" \
  -H "X-Test-Auth: $SECRET" | jq -r .header)

# 2. Create a new chat session (this also provisions a sandbox)
SESSION_ID=$(curl -s -X POST "$BASE/api/sessions" \
  -H "Cookie: $COOKIE" \
  -H "content-type: application/json" \
  -d '{"initialMessage": "List the files in this repo"}' \
  | jq -r .session.id)

# 3. Inspect the session and its sandbox status
curl -s "$BASE/api/sessions/$SESSION_ID" -H "Cookie: $COOKIE" | jq .

curl -s "$BASE/api/sandbox/status?sessionId=$SESSION_ID" \
  -H "Cookie: $COOKIE" | jq .
```

### Inspect who you are

```bash
curl -s "$BASE/api/auth/info" -H "Cookie: $COOKIE" | jq .
```

### List available models

```bash
curl -s "$BASE/api/models" -H "Cookie: $COOKIE" | jq .
```

## Adding new testable endpoints

When you add a feature, follow these rules so the next agent can verify it from curl:

1. Prefer an API route (`apps/web/app/api/.../route.ts`) over a server action when the behavior is worth testing. Server actions use an RSC wire format that is awkward to curl.
2. Keep route handlers thin. Put logic in plain async functions (in `lib/`) so the function is also unit-testable and so the route is easy to read.
3. Validate inputs with Zod; return `400` on bad input.
4. If the route needs state (a session, a chat, a sandbox), make the corresponding `POST` to create that state curl-able as well — scenarios are usually sequences of curls.

If a new endpoint is part of the common test path, add a worked example here so it stays discoverable.
