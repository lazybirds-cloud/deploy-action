# deploy-action

Reusable GitHub Action **and** agent skill to deploy apps to
[LazyHost](https://portal.lazybirds.cloud) (LazyBirds hosting).

Deploy a **PocketBase** or **Next.js** app straight from your repository:
CI packs the project, sends it to the portal, the platform builds it
(validating hooks/migrations with a boot-check) and publishes it with
zero-downtime rollback available.

## Usage

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: lazybirds-cloud/deploy-action@main
        with:
          token: ${{ secrets.LAZYBIRDS_TOKEN }}
          deployment_id: ${{ secrets.LAZYBIRDS_DEPLOYMENT_ID }}
```

First deploy (creates the deployment): pass `app_slug: pocketbase`
(or `nextjs`) and `secret_env` (e.g. `PB_SUPERUSER_*`), then store the
returned `deployment_id` as the repo secret `LAZYBIRDS_DEPLOYMENT_ID`.

### Inputs

| Input | Required | Description |
|---|---|---|
| `token` | ✅ | PAT with the `deployments.write` capability |
| `deployment_id` | — | Deployment UUID for updates (portal URL) |
| `app_slug` | 1st deploy | `pocketbase` / `nextjs` |
| `secret_env` / `env` | — | JSON objects (`{"KEY":"value"}`) |
| `source_dir` | — | Project directory (default `.`) |
| `excludes` | — | Extra zip excludes (gitignore-style) |
| `root_dir` | — | Monorepo subfolder |
| `portal_url` | — | Default `https://portal.lazybirds.cloud` |
| `wait_minutes` | — | Build wait (default 15) |

### Outputs

`deployment_id`, `build_id`, `build_status`, `url`.

## One-time setup

1. Create your account at the portal and ask an admin for the feature flag
   (`pocketbase-proprio` / `nextjs-proprio`).
2. **Chaves de integração** → Nova chave → mark `deployments.write` → copy
   the PAT (shown once) → repo secret `LAZYBIRDS_TOKEN`.
3. First deploy creates the app and prints the `deployment_id` → save it as
   `LAZYBIRDS_DEPLOYMENT_ID`.

## Agent skill

Agents (Hermes, Claude Code, …) can load the same flow as a skill:
`skills/lazyhost-deploy/SKILL.md` — install it with your skills manager
(source: this repository) or copy the folder into your profile's skills
directory.

## How it works

The action talks to the portal MCP API (`/mcp/`, JSON-RPC 2.0, PAT bearer):
`create_deployment` / `upload_deployment_version` → the platform builds the
project in a sandboxed Job (install, `next build`, PocketBase boot-check)
→ the release is published. Builds are billed-free; the running app is
billed hourly (see the rate card). Full history and rollback live in the
portal (Builds tab).
