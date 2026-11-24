#!/usr/bin/env bash
# LazyHost Deploy — calls the portal MCP deploy tools.
# Requires: zip, curl, jq (present on GitHub runners).
set -euo pipefail

PORTAL_URL="${INPUT_PORTAL_URL%/}"
MCP="$PORTAL_URL/mcp/"
TOKEN="$INPUT_TOKEN"
WAIT_SECONDS=$(( ${INPUT_WAIT_MINUTES:-15} * 60 ))

fail() { echo "::error::$1"; exit 1; }
command -v zip >/dev/null || fail "zip is required"
command -v jq >/dev/null || fail "jq is required"

ENV_JSON="${INPUT_ENV:-}"
SECRET_JSON="${INPUT_SECRET_ENV:-}"
[ -z "$ENV_JSON" ] && ENV_JSON='{}'
[ -z "$SECRET_JSON" ] && SECRET_JSON='{}'

# ── 1. Package the source ────────────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$INPUT_SOURCE_DIR"
EXCLUDES=(-x 'node_modules/*' '.git/*' '.next/*' 'pb_data/*' '.DS_Store' '__MACOSX/*')
if [ -n "${INPUT_EXCLUDES:-}" ]; then
  for e in $INPUT_EXCLUDES; do EXCLUDES+=("-x" "$e"); done
fi
zip -qr "$WORK/app.zip" . "${EXCLUDES[@]}"
SIZE=$(wc -c < "$WORK/app.zip")
MAX=$((50 * 1024 * 1024))
[ "$SIZE" -le "$MAX" ] || fail "app.zip is $SIZE bytes; the limit is 50 MB (check your excludes)."
# base64 em arquivo (linha-a-linha ok: o servidor ignora whitespace) —
# o JSON da requisição é montado com --rawfile p/ não estourar ARG_MAX.
base64 -i "$WORK/app.zip" > "$WORK/app.b64"

# ── 2. Build the request JSON ────────────────────────────────────────────
if [ -n "${INPUT_DEPLOYMENT_ID:-}" ]; then
  jq -n --arg tool "upload_deployment_version" \
    --arg id "$INPUT_DEPLOYMENT_ID" \
    --arg name "${GITHUB_SHA:-source.zip}" \
    --rawfile b64 "$WORK/app.b64" \
    '{jsonrpc:"2.0", id:1, method:"tools/call",
      params:{name:$tool,
        arguments:{deployment_id:$id, source_zip_b64:$b64, source_filename:$name}}}' \
    > "$WORK/req.json"
else
  [ -n "${INPUT_APP_SLUG:-}" ] || fail "app_slug is required for the first deploy (or pass deployment_id to update)"
  jq -n --arg tool "create_deployment" \
    --arg app "$INPUT_APP_SLUG" \
    --arg name "${GITHUB_SHA:-source.zip}" \
    --argjson env "$ENV_JSON" --argjson sec "$SECRET_JSON" \
    --rawfile b64 "$WORK/app.b64" \
    '{jsonrpc:"2.0", id:1, method:"tools/call",
      params:{name:$tool,
        arguments:{app_slug:$app,
          env:(if $env == {} then null else $env end),
          secret_env:(if $sec == {} then null else $sec end),
          source_zip_b64:$b64, source_filename:$name}}}' \
    > "$WORK/req.json"
fi

# ── 3. Call the MCP endpoint ─────────────────────────────────────────────
# The token goes in a header file (curl -H @file), so it never shows on the command line.
[ -n "$TOKEN" ] || fail "token is empty (set the LAZYBIRDS_TOKEN secret)"
echo "::add-mask::$TOKEN"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$WORK/auth.h"
chmod 600 "$WORK/auth.h"

# mcp_call <request file> <response file> → prints the HTTP status code (000 = no answer)
mcp_call() {
  curl -sS -X POST "$MCP" \
    -H @"$WORK/auth.h" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    --data-binary "@$1" -o "$2" -w '%{http_code}' || echo 000
}

HTTP=$(mcp_call "$WORK/req.json" "$WORK/resp.txt")
case "$HTTP" in
  200) ;;
  401|403) fail "LazyHost: HTTP $HTTP — the token was refused (needs the deployments.write capability)." ;;
  000) fail "LazyHost: no answer from $MCP." ;;
  *) echo "Response: $(head -c 300 "$WORK/resp.txt")"; fail "LazyHost: HTTP $HTTP from $MCP." ;;
esac
jq -e . "$WORK/resp.txt" >/dev/null 2>&1 || { echo "Response: $(head -c 300 "$WORK/resp.txt")"; fail "LazyHost: the answer is not JSON."; }
RESP=$(cat "$WORK/resp.txt")
if echo "$RESP" | jq -e '.error' >/dev/null; then
  fail "LazyHost: $(echo "$RESP" | jq -r '.error.message // "JSON-RPC error"')"
fi
if echo "$RESP" | jq -e '.result.isError == true' >/dev/null; then
  MSG=$(echo "$RESP" | jq -r '.result.content[0].text // "deploy failed"')
  fail "LazyHost: $MSG"
fi
DEP_ID=$(echo "$RESP" | jq -r '.result.structuredContent.deployment_id // .result.structuredContent.id // empty')
BUILD_ID=$(echo "$RESP" | jq -r '.result.structuredContent.build.id // .result.structuredContent.build_id // empty')
URL=$(echo "$RESP" | jq -r '.result.structuredContent.url // empty')
echo "LazyHost: deployment=$DEP_ID build=$BUILD_ID url=$URL"

# ── 4. Wait for the build ────────────────────────────────────────────────
# A failed poll (network blip, 502) is retried; only 5 failures in a row stop the job.
if [ -n "$BUILD_ID" ]; then
  jq -n --arg id "$BUILD_ID" \
    '{jsonrpc:"2.0", id:2, method:"tools/call", params:{name:"get_build", arguments:{build_id:$id, tail_lines:40}}}' \
    > "$WORK/poll.json"
  START=$(date +%s)
  MISSES=0
  while :; do
    ELAPSED=$(( $(date +%s) - START ))
    [ "$ELAPSED" -ge "$WAIT_SECONDS" ] && fail "Timed out waiting for the build (${WAIT_SECONDS}s)."
    HTTP=$(mcp_call "$WORK/poll.json" "$WORK/poll.txt")
    if [ "$HTTP" != 200 ] || ! jq -e '.result.structuredContent' "$WORK/poll.txt" >/dev/null 2>&1; then
      MISSES=$((MISSES + 1))
      echo "build: status check failed (HTTP $HTTP, $MISSES/5)"
      [ "$MISSES" -ge 5 ] && fail "LazyHost: could not read the build status (HTTP $HTTP)."
      sleep 10
      continue
    fi
    MISSES=0
    S=$(jq -r '.result.structuredContent.status // "pending"' "$WORK/poll.txt")
    echo "build: $S (${ELAPSED}s)"
    case "$S" in
      succeeded) break ;;
      failed|cancelled)
        jq -r '.result.structuredContent.log // empty' "$WORK/poll.txt" | tail -40
        fail "Build $S on LazyHost — see the log above."
        ;;
    esac
    sleep 10
  done
fi

OUT="${GITHUB_OUTPUT:-/dev/null}"
{
  echo "deployment_id=$DEP_ID"
  echo "build_id=$BUILD_ID"
  echo "build_status=succeeded"
  echo "url=$URL"
} >> "$OUT"
echo "LazyHost: deployed ✓"
