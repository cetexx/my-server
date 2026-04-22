# CLAUDE.md — Project Context

## What is this

Docker Swarm infrastructure for a VPS server hosting multiple projects. Single-node swarm on Rocky Linux 10 (KVM), 4 vCPU, 16GB RAM, 160GB SSD, 1Gbps.

## Architecture

Three Docker Swarm stacks sharing two overlay networks (`traefik-public`, `internal`):

- **core** — Traefik v3 (reverse proxy, SSL), PostgreSQL 17, Redis 7, Portainer, Adminer, Playwright (browserless/chromium), Shepherd (auto-update)
- **monitoring** — Prometheus, Alertmanager, Grafana (4 auto-provisioned dashboards), Node Exporter, cAdvisor, postgres-exporter, Dozzle
- **mail** — docker-mailserver, Roundcube, traefik-certs-dumper

Projects live in their own repositories and are deployed independently on the server. Shepherd (in core stack) auto-updates services labeled `shepherd.enable=true` when new images are pushed to the registry.

## Key design decisions

- **Single PostgreSQL instance** shared by all projects. Each project gets an isolated DB user with `REVOKE ALL FROM PUBLIC` + `CONNECTION LIMIT`. Create via `./scripts/db-create.sh`.
- **Shepherd** (containrrr/shepherd) auto-updates Swarm services with `shepherd.enable=true` label when new images appear in registry. Checks every 15 min, auto-rollback on failure.
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

Within the same stack, use just `<service>` (e.g., `prometheus` can reach `node-exporter` directly).

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

Custom `postgresql.conf` mounted via Swarm config. Tuned for 16GB RAM: `shared_buffers=4GB`, `effective_cache_size=12GB`, `work_mem=64MB`. Loaded via `postgres -c config_file=/etc/postgresql/postgresql.conf`.

## Memory budget

Total limits: ~10.1 GB out of 16 GB. ~3.9 GB free for projects, ~2 GB for OS/Docker.

## Gotchas

- Docker Swarm does not support `cap_add` in deploy mode — fail2ban is disabled in docker-mailserver
- Traefik v3 uses `providers.swarm` (not `providers.docker` with swarmMode)
- Swarm config files are immutable — changing a config requires redeploying the stack (Docker creates a new config version)
- Health checks use container-level commands (not Swarm-level) — they trigger container restarts, not service rescheduling
- Rocky Linux has SELinux enabled — Docker volumes need `svirt_sandbox_file_t` context (handled by `setup.sh`)
- `alertmanager.yml` has hardcoded `smtp_from: alertmanager@example.com` — must be manually updated to match actual domain (Docker configs don't support env var substitution)

## Language

The user communicates in Lithuanian. README, comments in scripts, and alert messages are in Lithuanian.
