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
RESP=$(curl -sS -X POST "$MCP" \
  -H "Authorization: Bearer ***" \
  -H 'Content-Type: application/json' \
  --data-binary "@$WORK/req.json" -o "$WORK/resp.txt" -w "%{http_code}")
echo "MCP HTTP code: $RESP" || true
echo "RESP bytes: $(wc -c < "$WORK/resp.txt")" || true
head -c 200 "$WORK/resp.txt" | tr -d '\n' ; echo "" || true
RESP=$(cat "$WORK/resp.txt")
if echo "$RESP" | jq -e '.result.isError == true' >/dev/null; then
  MSG=$(echo "$RESP" | jq -r '.result.content[0].text // "deploy failed"')
  fail "LazyHost: $MSG"
fi
DEP_ID=$(echo "$RESP" | jq -r '.result.structuredContent.deployment_id // .result.structuredContent.id // empty')
BUILD_ID=$(echo "$RESP" | jq -r '.result.structuredContent.build.id // empty')
URL=$(echo "$RESP" | jq -r '.result.structuredContent.url // empty')
echo "LazyHost: deployment=$DEP_ID build=$BUILD_ID url=$URL"

# ── 4. Wait for the build ────────────────────────────────────────────────
if [ -n "$BUILD_ID" ]; then
  START=$(date +%s)
  while :; do
    NOW=$(date +%s); ELAPSED=$((NOW - START))
    [ "$ELAPSED" -ge "$WAIT_SECONDS" ] && fail "Timed out waiting for the build (${WAIT_SECONDS}s)."
    R=$(curl -sS -X POST "$MCP" -H "Authorization: Bearer ***" -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_build\",\"arguments\":{\"build_id\":\"$BUILD_ID\",\"tail_lines\":30}}}")
    S=$(echo "$R" | jq -r '.result.structuredContent.status // "pending"')
    echo "build: $S (${ELAPSED}s)"
    case "$S" in
      succeeded) break ;;
      failed)
        echo "$R" | jq -r '.result.structuredContent.log // empty' | tail -40
        fail "Build failed on LazyHost — see the log above."
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
