---
name: lazyhost-deploy
description: Deploy apps to LazyHost (LazyBirds hosting) via the portal MCP — create deployments, push new versions, manage env/secrets and watch builds.
---

# LazyHost Deploy

Deploy **PocketBase** and **Next.js** apps to LazyHost through the LazyBirds
Portal MCP API. Works from any agent that can run `curl`.

## Requirements (one-time)

1. A LazyBirds account (portal.lazybirds.cloud) with the **feature flag** for
   the app kind (admins grant it — e.g. `pocketbase-proprio`).
2. A PAT with the **deployments.write** capability: Portal →
   **Chaves de integração** → Nova chave → mark `deployments.write`.
   The key is shown once; store it safely.
3. Env for this session: `LAZYHOST_TOKEN=<PAT>` (do not echo the token).

## Endpoint and auth

```
POST https://portal.lazybirds.cloud/mcp/
Authorization: Bearer <PAT>
Content-Type: application/json
```

JSON-RPC 2.0, stateless: every call is independent. Responses put the tool
result in `result.structuredContent`; **tool failures return HTTP 200 with
`result.isError: true` and the PT-BR message in `result.content[0].text`**
— always check `isError`.

## Zip rules (the build validates these)

- ≤ 50 MB, ≤ 20.000 files, no symlinks.
- **PocketBase**: `pb_hooks/` (`.pb.js`), `pb_migrations/` and/or `pb_public/`
  in the zip root. Never include `pb_data/` (data lives on the deployment's
  own volume and is wiped from uploads).
- **Next.js**: source with `package.json` listing `next`; `node_modules/`,
  `.next/`, `.git/` are stripped. `NEXT_PUBLIC_*` env vars are inlined at
  build time.

## Tools (all require deployments.write except reads)

| Tool | Purpose |
|---|---|
| `create_deployment` | First deploy: app_slug + subdomain(optional) + cpu/memory/storage + env/secret_env + zip (base64). Returns the deployment URL and build id. |
| `upload_deployment_version` | New version: deployment_id + zip → build → auto-publish. |
| `get_build` | Build status + log tail (`build_id`, `tail_lines`). Poll until `status` is `succeeded`/`failed`. |
| `set_deployment_env` | Set/remove env and secret vars (`secret_env` is write-only; `null` removes a key). Redeploys by default. |
| `update_deployment_settings` | Change idle policy / CPU / memory of a running deployment. |
| `list_deployments` / `get_deployment` / `list_builds` | Reads. |

## Recipe: deploy (create)

Build the request in a **file**: a zip of more than ~100 KB doesn't fit in one
command-line argument (`-d "$ZIP64"` fails with "Argument list too long").

```bash
base64 < app.zip > app.b64          # GNU and BSD; line breaks are fine
jq -n --rawfile b64 app.b64 \
  --arg email "$PB_SUPERUSER_EMAIL" --arg pass "$PB_SUPERUSER_PASSWORD" \
  '{jsonrpc:"2.0", id:1, method:"tools/call", params:{name:"create_deployment",
    arguments:{app_slug:"pocketbase",
      secret_env:{PB_SUPERUSER_EMAIL:$email, PB_SUPERUSER_PASSWORD:$pass},
      source_zip_b64:$b64}}}' > req.json
printf 'Authorization: Bearer %s\n' "$LAZYHOST_TOKEN" > auth.h   # keeps the token off the command line
curl -sS https://portal.lazybirds.cloud/mcp/ -H @auth.h \
  -H "Content-Type: application/json" --data-binary @req.json | jq
rm -f auth.h
```

Read `result.structuredContent`: `.id` (deployment), `.build.id` (build),
`.url` (public URL). Poll `get_build` every 10 s until the build reaches
`succeeded` (the platform restarts the release with the new version).
HTTP 401/403 = the token is missing, wrong or lacks `deployments.write`.

## Recipe: update (new version)

Same request file with `name:"upload_deployment_version"` and
`arguments:{deployment_id:"<uuid>", source_zip_b64:$b64}`. Env and secrets
already set on the deployment are kept.

## Secrets and env

- `secret_env` values are stored in a Kubernetes Secret (write-only) and
  referenced by `secretKeyRef` — never echoed back by any tool, view or API.
- Changes redeploy the release automatically (pods restart). Use
  `restart: false` only when the app reads the var at boot time.

## GitHub Actions

For repo-based deploys, use the reusable action in this repository:

```yaml
- uses: lazybirds-cloud/deploy-action@main
  with:
    token: ${{ secrets.LAZYBIRDS_TOKEN }}
    deployment_id: ${{ secrets.LAZYBIRDS_DEPLOYMENT_ID }}
```

First deploy: set `app_slug: pocketbase` instead of `deployment_id`, then
store the returned `deployment_id` as a repo secret for future runs.

## Troubleshooting

- `isError` with "Restaure a implantação..." → the deployment is trashed;
  restore it in the portal first.
- Build `failed` with hook/migration errors → the log tail in `get_build`
  names the offending file (PocketBase boot-check catches them before
  publish).
- 4xx from the API (not `isError`) → auth/token/capability problem: check
  the PAT and the feature flag.
- PocketBase admin: `https://<subdomain>.lazybirds.cloud/_/`, login with
  `PB_SUPERUSER_EMAIL`/`PB_SUPERUSER_PASSWORD` (set at creation, or run
  `./pocketbase superuser upsert EMAIL PASS` from the deployment Terminal).
