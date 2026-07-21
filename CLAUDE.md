# CLAUDE.md — Project Context

## What is this

Docker Swarm infrastructure for a VPS server hosting multiple projects. Single-node swarm on Rocky Linux 10 (KVM), 6 vCPU, 24GB RAM, 300GB SSD, 1Gbps.

## Architecture

Four Docker Swarm infrastructure stacks sharing two overlay networks (`traefik-public`, `internal`):

- **core** — Traefik v3 (reverse proxy, SSL), PostgreSQL 17, Redis 7, Portainer, Adminer, Playwright (browserless/chromium), docker-socket-proxy (filtered read-only Docker API for Traefik)
- **monitoring** — Prometheus, Alertmanager, Grafana (4 auto-provisioned dashboards), Node Exporter, cAdvisor, postgres-exporter, Dozzle
- **mail** — docker-mailserver **v15** (Rspamd for spam + DKIM), Roundcube webmail at `mail.cetex.dev`. TLS read directly from Traefik `acme.json` (`SSL_TYPE=letsencrypt`, no certs-dumper). One instance serves natars.mobi, xheroes.agency, cetex.dev.
- **landing** — nginx static page at `cetex.dev` + Traefik redirects (www→https, bare server-IP→`https://cetex.dev`)

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

`./deploy.sh <stack>` does: `cd <stack>/; set -a; source ../.env; set +a; docker stack deploy -c docker-compose.yml <stack>`. The `set -a` is **essential** — plain `source` does NOT export the vars, so `docker stack deploy` would interpolate empty `${VARS}` and bring the stack up with blank config. Checks for `.env` before sourcing. Relative config paths resolve relative to the stack directory.

## Scripts

All in `scripts/`. Main entry point is `./server.sh` which routes subcommands to individual scripts. Scripts that modify system state (ssh, firewall) require root.

### Mail (docker-mailserver v15 + Rspamd)

`MAIL_DOMAIN` in `.env` (= `cetex.dev`) is the mailserver identity — SEPARATE from `DOMAIN` (`pickzy.app`, whose mail is on Google Workspace). Mailserver FQDN + webmail = `mail.cetex.dev`. One instance serves all project domains, each fully independent (own DKIM/MX/SPF/mailboxes).

**Sending IP = 176 (the host default), NOT a dedicated IP** (learned the hard way 2026-07-21). Docker Swarm overlay containers egress via the host's *default route* IP (176); forcing a second IP (212) via SNAT fights Docker+firewalld iptables reconciliation and is unreliable — tried and reverted. So SPF and PTR must reference **176**. True per-IP mail isolation would need a standalone host-networked mailserver *outside* Swarm.

Add a new project domain:
```bash
./server.sh mail add-domain natars.mobi      # gen DKIM (Rspamd) + ensure it's in dkim_signing.conf + print DNS
./server.sh mail add info@natars.mobi <pw>   # create mailbox (password as arg = non-interactive)
```
Then add DNS (DNS-only / grey cloud) for that domain: `MX → mail.cetex.dev` (prio 10), `TXT @: v=spf1 ip4:176.223.132.42 ~all`, `TXT _dmarc: v=DMARC1; p=none; rua=mailto:postmaster@<domain>`, `TXT mail._domainkey: <contents of the rspamd public.dns.txt>`.

**Rspamd DKIM gotchas:**
- Keys: `/opt/my-server/mailserver/config/rspamd/dkim/rsa-2048-mail-<domain>.{private,public.dns}.txt`. The `public.dns.txt` IS the ready DNS TXT value.
- `setup config dkim domain X` generates the key but does NOT reliably add the domain to `rspamd/override.d/dkim_signing.conf` `domain { }` — **each domain must be listed there** or it won't sign. `mail-manage.sh add-domain` now handles this.
- In `dkim_signing.conf`: `sign_local = true` + `check_pubkey = false` (with `check_pubkey = true` Rspamd skips signing when the DNS check fails). Reload: `docker exec <mail> supervisorctl restart rspamd`.
- Rspamd signs only **authenticated (587) or local** mail — apps MUST send via authenticated SMTP submission on 587.

**App SMTP** (Laravel): `MAIL_HOST=mail.cetex.dev MAIL_PORT=587 MAIL_ENCRYPTION=tls MAIL_USERNAME=no-reply@<domain> MAIL_PASSWORD=<pw>`.

**PTR:** set at serveriai.lt self-service for IP 176 → `mail.cetex.dev` (ideally matching HELO). Target mail-tester.com ≥8/10; below → hosted SMTP (Postmark/Mailgun) for OTP/password-reset. IP reputation warms over 3-6 weeks.

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
- `alertmanager.yml` has hardcoded `smtp_from: alertmanager@pickzy.app` — must be manually updated to match actual domain (Docker configs don't support env var substitution)
- **NEVER** deploy manually with `source .env && docker stack deploy` — `source` doesn't export, so compose sees empty `${DOMAIN}` / `${POSTGRES_*}` / `${GRAFANA_DB_PASSWORD}` and the stack comes up mis-wired (this took down `core_postgresql` and broke Grafana DB auth on 2026-07-21). **Always** use `./deploy.sh <stack>` — it does `set -a; source; set +a` correctly.

## Language

The user communicates in Lithuanian. README, comments in scripts, and alert messages are in Lithuanian.
