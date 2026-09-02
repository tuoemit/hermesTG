# HermesTG

Deploy [Hermes Agent](https://hermes-agent.nousresearch.com/) to Railway using the official Hermes Agent container architecture.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/TEMPLATE_ID?referralCode=REFERRAL_CODE)

## Why this template is different

This is a thin Railway integration layer around the official Hermes image. It does **not** maintain a second Hermes runtime or install/update Hermes from Git at container startup.

The upstream image provides:

- Python 3.13 and Node 26
- s6-overlay supervision for gateway and dashboard processes
- native dashboard authentication
- non-root runtime and immutable application files
- persistent state under `/opt/data`
- browser automation dependencies
- the fixed SQLite build that avoids the WAL-reset corruption bug

The template adds only Railway-specific configuration: dynamic port handling, health checks, and deployment documentation.

## Setup

1. Deploy the template.
2. Set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` (for example `admin`).
3. Set a strong `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`.
4. Attach a Railway Volume at `/opt/data`.
5. Open the generated Railway domain and complete Hermes setup.
6. Configure an LLM provider and any messaging integrations you need.

For published Railway templates, use Railway's `secret(...)` template function to generate the dashboard password rather than committing one to the repository.

## Environment variables

| Variable | Purpose |
|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Dashboard login username |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Dashboard login password |
| `HERMES_DASHBOARD` | Enables the supervised dashboard; this template sets it to `1` |
| `HERMES_DASHBOARD_HOST` | Dashboard bind address; this template sets it to `0.0.0.0` |
| `HERMES_HOME` | Persistent Hermes state root; this template sets it to `/opt/data` |
| `PORT` | Railway-provided public HTTP port; the wrapper maps it to Hermes' dashboard port |

The old `DASHBOARD_PASSWORD`, `DASHBOARD_USER`, and `AUTO_UPDATE` variables are intentionally gone.

## Persistent storage

Attach a Railway Volume at:

```text
/opt/data
```

That is the persistent Hermes state directory. Do not mount the Railway volume at `/root/.hermes`; that is the old template layout.

## Architecture

```text
Internet
   │
   ▼
Railway public HTTP
   │
   ▼
Railway port ($PORT)
   │
   ▼
/railway-entrypoint.sh
   │
   ▼
Official Hermes /init (s6-overlay PID 1)
   ├── supervised dashboard : $PORT
   └── supervised gateway
           │
           └── persistent Hermes state -> /opt/data
```

The dashboard authentication and gateway lifecycle are handled by Hermes itself. There is no custom aiohttp auth proxy and no runtime `git pull`.

## SQLite protection

The official Hermes image currently avoids Debian's SQLite 3.46.1 and builds a fixed SQLite release. This template also performs a build-time assertion that the runtime SQLite is at least 3.51.3, so an unexpected base-image regression fails the build rather than deploying a vulnerable SQLite stack.

## Updating

Rebuild the Railway service to pick up the current upstream `nousresearch/hermes-agent:latest` image. Data in `/opt/data` is separate from the image and survives image replacement when the Railway Volume remains attached.

For release pinning, replace `latest` in the Dockerfile with a specific upstream Hermes tag.

## References

- [Hermes Agent Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Hermes Agent GitHub](https://github.com/NousResearch/hermes-agent)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway health checks](https://docs.railway.com/deployments/healthchecks)
