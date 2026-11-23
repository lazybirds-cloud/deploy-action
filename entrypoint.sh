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
B64=$(base64 -w0 "$WORK/app.zip")

mcp() { # $1=tool name, $2=arguments JSON
  curl -sS -X POST "$MCP" \
    -H "Authorization: Bearer ***" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}

# tool result: structuredContent = JSON summary; isError=true on tool failure
extract() { echo "$1" | jq -r '.result.structuredContent // empty'; }
check_err() {
  if echo "$1" | jq -e '.result.isError == true' >/dev/null; then
    MSG=$(echo "$1" | jq -r '.result.content[0].text // "deploy failed"')
    fail "LazyHost: $MSG"
  fi
}

if [ -n "${INPUT_DEPLOYMENT_ID:-}" ]; then
  ARGS=$(jq -n --arg id "$INPUT_DEPLOYMENT_ID" --arg b64 "$B64" \
    --arg name "${GITHUB_SHA:-source.zip}" \
    '{deployment_id:$id, source_zip_b64:$b64, source_filename:$name}')
  RESP=$(mcp upload_deployment_version "$ARGS")
  check_err "$RESP"
else
  [ -n "${INPUT_APP_SLUG:-}" ] || fail "app_slug is required for the first deploy (or pass deployment_id to update)"
  ARGS=$(jq -n --arg app "$INPUT_APP_SLUG" --arg b64 "$B64" \
    --arg name "${GITHUB_SHA:-source.zip}" \
    --argjson env "$ENV_JSON" --argjson sec "$SECRET_JSON" \
    '{app_slug:$app, source_zip_b64:$b64, source_filename:$name, env:(if $env == {} then null else $env end), secret_env:(if $sec == {} then null else $sec end)}')
  RESP=$(mcp create_deployment "$ARGS")
  check_err "$RESP"
fi
RES=$(extract "$RESP")
DEP_ID=$(echo "$RES" | jq -r '.deployment_id // .id // empty')
BUILD_ID=$(echo "$RES" | jq -r '.build.id // .build_id // empty')
URL=$(echo "$RES" | jq -r '.url // empty')
echo "LazyHost: deployment=$DEP_ID build=$BUILD_ID url=$URL"

# ── 2. Wait for the build ────────────────────────────────────────────────
if [ -n "$BUILD_ID" ]; then
  START=$(date +%s)
  while :; do
    NOW=$(date +%s); ELAPSED=$((NOW - START))
    [ "$ELAPSED" -ge "$WAIT_SECONDS" ] && fail "Timed out waiting for the build (${WAIT_SECONDS}s)."
    R=$(curl -sS -X POST "$MCP" -H "Authorization: Bearer ***" -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_build\",\"arguments\":{\"build_id\":\"$BUILD_ID\",\"tail_lines\":30}}}")
    S=$(extract "$R" | jq -r '.status // "pending"')
    echo "build: $S (${ELAPSED}s)"
    case "$S" in
      succeeded) break ;;
      failed)
        extract "$R" | jq -r '.log // empty' | tail -40
        fail "Build failed on LazyHost — see the log above."
        ;;
    esac
    sleep 10
  done
fi

{
  echo "deployment_id=$DEP_ID"
  echo "build_id=$BUILD_ID"
  echo "build_status=succeeded"
  echo "url=$URL"
} >> "$GITHUB_OUTPUT"
echo "LazyHost: deployed ✓"
