# CLAUDE.md — Project Context

## What is this

Docker Swarm infrastructure for a VPS server hosting multiple projects. Single-node swarm on Rocky Linux 10 (KVM), 6 vCPU, 24GB RAM, 300GB SSD, 1Gbps.

## Architecture

Three Docker Swarm stacks sharing two overlay networks (`traefik-public`, `internal`):

- **core** — Traefik v3 (reverse proxy, SSL), PostgreSQL 17, Redis 7, Portainer, Adminer, Playwright (browserless/chromium), docker-socket-proxy (filtered read-only Docker API for Traefik)
- **monitoring** — Prometheus, Alertmanager, Grafana (4 auto-provisioned dashboards), Node Exporter, cAdvisor, postgres-exporter, Dozzle
- **mail** (planned — not yet deployed) — docker-mailserver, Roundcube, traefik-certs-dumper

Projects live in their own repositories and are deployed independently via CI/CD: GitHub Actions builds an image → pushes to GHCR → SSHes in and runs the project's `swarm-deploy.sh` (`docker stack deploy --with-registry-auth`). No auto-update daemon.

## Key design decisions

- **Single PostgreSQL instance** shared by all projects. Each project gets an isolated DB user with `REVOKE ALL FROM PUBLIC` + `CONNECTION LIMIT`. Create via `./scripts/db-create.sh`.
- **docker-socket-proxy** (tecnativa) fronts the Docker API for Traefik — Traefik connects via `tcp://core_socket-proxy:2375` (GET-only, `POST=0`) instead of mounting the raw `/var/run/docker.sock`, so a compromised internet-facing Traefik can't get root-equivalent host access.
- **Two overlay networks only**: `traefik-public` for HTTP routing, `internal` for everything else (DB, Redis, metrics, inter-service).
- **IP whitelist** on admin tools (Traefik dashboard, Portainer, Adminer, Grafana, Prometheus, Alertmanager, Playwright, Dozzle) via Traefik `ipAllowList` middleware defined on the Traefik service in core stack.
- **Rate limiting** (100 req/s, burst 50) on public services (Roundcube, projects) via Traefik `rateLimit` middleware, also defined on Traefik.
- **Alertmanager** sends alerts via email through the internal docker-mailserver (port 25, no auth, `PERMIT_DOCKER=network`). Recipients: sarunas.pm@gmail.com, cetex.pm@gmail.com.
- **`DOMAIN` env var** is the single source for all web-facing hostnames. `MAIL_DOMAIN` was removed to avoid mismatches — everything uses `DOMAIN`.
- **Playwright** (browserless/chromium) is a shared headless browser service. Projects connect via `ws://core_playwright:3000?token=TOKEN`. Token auth via `PLAYWRIGHT_TOKEN` env var.

## OS: Rocky Linux 10

- Uses `dnf` (not `apt-get`), `firewalld` (not `ufw`), `dnf-automatic` (not `unattended-upgrades`)
- SELinux enabled by default — `setup.sh` configures Docker access via `setsebool` and `chcon`
- `firewall-setup.sh` auto-detects OS and uses `firewalld` or `ufw` accordingly
- Docker installed via `dnf install docker-ce` (requires Docker CE repo)

## Cross-stack service naming

In Docker Swarm, services from different stacks communicate via external overlay networks using `<stack>_<service>` naming:
- `core_postgresql` — PostgreSQL from any stack
- `core_redis` — Redis from any stack
- `core_traefik` — Traefik (for Prometheus metrics scraping on port 8082)
- `core_playwright` — Headless browser from any stack

Within the same stack, use just `<service>` — BUT only if that service name is UNIQUE across all stacks (see hazard below).

### ⚠ Collision hazard (learned the hard way — natars, 2026-07-21)
The short `<service>` alias is registered on the SHARED external `internal` network and is **NOT stack-isolated**. If two stacks each have a service named `redis` (e.g. `core_redis` + `natars_redis`), then `redis` resolves to **both** VIPs and round-robins — so ~half the connections hit the wrong server. natars used `REDIS_HOST=redis` → intermittent `WRONGPASS` against `core_redis` (different password). Hard rule:
- In any project `.env` / config, cross-stack hosts are ALWAYS fully qualified: `REDIS_HOST=core_redis` (or `<proj>_redis`), `DB_HOST=core_postgresql`. **Never** bare `redis`/`app`/`db`/`api`/`cache`/`worker`/`web`.
- Avoid generic compose service keys entirely. Audit: `grep -rE '_HOST=(redis|app|db|api|cache)$' /opt/*/.env` must be empty.

### New-project onboarding checklist (before deploying project N)
1. **Names**: no generic compose service keys; Traefik router/service/middleware label names = `<project>-<role>` (e.g. `natars-web`); reference shared middlewares as `rate-limit@swarm` / `admin-whitelist@swarm`.
2. **Redis**: pure cache → `core_redis` with a UNIQUE key prefix; durable (queue/session/reverb) → **own** redis service `--maxmemory-policy noeviction` + own password + AOF (copy natars). `core_redis` is `allkeys-lru` — it silently evicts jobs/sessions, never put durable data there.
3. **Postgres**: create user+DB ONLY via `./server.sh db create <name> <limit>` (never manual `CREATE USER`). Set `CONNECTION LIMIT` ≈ php-fpm pool + Horizon procs + 5 (≈20-25). Invariant: `SELECT sum(rolconnlimit) FROM pg_roles WHERE NOT rolsuper AND rolconnlimit>0` must stay ≤195 (max_connections 200 − reserved). Currently ~108.
4. **Health checks**: the app image ships a Caddy `HEALTHCHECK` (`curl :2019/metrics`). Non-web services (horizon/scheduler/reverb/queue workers) MUST set `healthcheck: { disable: true }` or Swarm kills them (exit 137).
5. **Resources**: every service needs `deploy.resources.limits.memory` (a leak with no limit can OOM the node and take down Postgres/Traefik).
6. **Deploy**: mirror `natars` — CI builds → GHCR (`read:packages` pull-only token) → `scp compose` + `swarm-deploy.sh` over SSH. Give each app service a healthcheck so `start-first` rollback has a signal.
7. **Post-deploy**: `docker service ls` desired==running; the `_HOST=` grep above is empty; router name carries the project prefix.

## Environment variables

All in `.env` (copied from `.env.example`). Key vars:
- `DOMAIN` — base domain, used for all Traefik routing and SSL
- `ADMIN_WHITELIST_IPS` — comma-separated CIDR list for admin tool access
- `POSTGRES_USER/PASSWORD` — admin DB credentials
- `PLAYWRIGHT_TOKEN` — API token for browserless/chromium
- Service-specific DB passwords: `ROUNDCUBE_DB_PASSWORD`, `GRAFANA_DB_PASSWORD`, `POSTGRES_EXPORTER_PASSWORD`

## Deploy mechanism

`./deploy.sh <stack>` does: `cd <stack>/ && source ../.env && docker stack deploy -c docker-compose.yml <stack>`. Checks for `.env` existence before sourcing. Relative config file paths in compose files are resolved relative to the stack directory.

## Scripts

All in `scripts/`. Main entry point is `./server.sh` which routes subcommands to individual scripts. Scripts that modify system state (ssh, firewall) require root.

### Multi-domain mail

`mail-manage.sh` supports multiple project domains sharing one docker-mailserver instance. Each project domain needs its own DKIM key + DNS records (SPF/DKIM/DMARC/MX). Typical flow for a new project:

```bash
./server.sh mail add-domain pickzy.app          # generates DKIM + prints DNS records
# → add DNS records in that domain's Cloudflare/registrar
# → wait 5-15 min for propagation
./server.sh mail add labas@pickzy.app           # creates mailbox (auto-checks DKIM first)
./server.sh mail test labas@pickzy.app test-abc@mail-tester.com  # verify deliverability
```

DKIM keys live at `/opt/my-server/mailserver/config/opendkim/keys/<domain>/mail.txt`. Target score on mail-tester.com: **≥8/10** before using server for time-sensitive emails (OTP, password reset). Below 8/10 → switch to hosted SMTP (Postmark, Mailgun) for those specific use cases.

Server IP reputation warms up over 3-6 weeks of consistent low-volume sending. Brand-new SMTP servers often get quarantined by Gmail/iCloud even with perfect SPF/DKIM/DMARC — plan accordingly.

## PostgreSQL tuning

Custom `postgresql.conf` mounted via Swarm config. Tuned for 24GB RAM: `shared_buffers=4GB`, `effective_cache_size=12GB`, `work_mem=64MB`. Loaded via `postgres -c config_file=/etc/postgresql/postgresql.conf`.

## Memory budget

Total limits: ~11 GB out of 24 GB. ~11 GB free for projects, ~2 GB for OS/Docker.

## Gotchas

- Docker Swarm does not support `cap_add` in deploy mode — fail2ban is disabled in docker-mailserver
- Traefik v3 uses `providers.swarm` (not `providers.docker` with swarmMode)
- Swarm config files are immutable — changing a config requires redeploying the stack (Docker creates a new config version)
- Health checks use container-level commands (not Swarm-level) — they trigger container restarts, not service rescheduling
- Rocky Linux has SELinux enabled — Docker volumes need `svirt_sandbox_file_t` context (handled by `setup.sh`)
- `alertmanager.yml` has hardcoded `smtp_from: alertmanager@example.com` — must be manually updated to match actual domain (Docker configs don't support env var substitution)

## Language

The user communicates in Lithuanian. README, comments in scripts, and alert messages are in Lithuanian.
