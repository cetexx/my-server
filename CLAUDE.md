# CLAUDE.md — Project Context

## What is this

Docker Swarm infrastructure for a VPS server hosting multiple projects. Single-node swarm (4 vCPU, 16GB RAM, 160GB SSD).

## Architecture

Three Docker Swarm stacks sharing two overlay networks (`traefik-public`, `internal`):

- **core** — Traefik v3 (reverse proxy, SSL), PostgreSQL 17, Redis 7, Portainer, Adminer
- **monitoring** — Prometheus, Alertmanager, Grafana, Node Exporter, cAdvisor, postgres-exporter, Dozzle
- **mail** — docker-mailserver, Roundcube, traefik-certs-dumper

Projects live in `projects/<name>/` — each is an independent Swarm stack with optional Varnish cache sidecar.

## Key design decisions

- **Single PostgreSQL instance** shared by all projects. Each project gets an isolated DB user with `REVOKE ALL FROM PUBLIC` + `CONNECTION LIMIT`. Create via `./scripts/db-create.sh`.
- **Varnish per-project** (not centralized) — each project controls its own cache rules via VCL. File-based storage on SSD instead of S3.
- **Two overlay networks only**: `traefik-public` for HTTP routing, `internal` for everything else (DB, Redis, metrics, inter-service).
- **IP whitelist** on admin tools (Traefik dashboard, Portainer, Adminer, Grafana, Prometheus, Alertmanager, Dozzle) via Traefik `ipAllowList` middleware defined on the Traefik service in core stack.
- **Rate limiting** (100 req/s, burst 50) on public services (Roundcube, projects) via Traefik `rateLimit` middleware, also defined on Traefik.
- **Alertmanager** sends alerts via email through the internal docker-mailserver (port 25, no auth, `PERMIT_DOCKER=network`). Recipients: sarunas.pm@gmail.com, cetex.pm@gmail.com.
- **`DOMAIN` env var** is the single source for all web-facing hostnames. `MAIL_DOMAIN` was removed to avoid mismatches — everything uses `DOMAIN`.

## Cross-stack service naming

In Docker Swarm, services from different stacks communicate via external overlay networks using `<stack>_<service>` naming:
- `core_postgresql` — PostgreSQL from any stack
- `core_redis` — Redis from any stack
- `core_traefik` — Traefik (for Prometheus metrics scraping on port 8082)

Within the same stack, use just `<service>` (e.g., `prometheus` can reach `node-exporter` directly).

## Environment variables

All in `.env` (copied from `.env.example`). Key vars:
- `DOMAIN` — base domain, used for all Traefik routing and SSL
- `ADMIN_WHITELIST_IPS` — comma-separated CIDR list for admin tool access
- `POSTGRES_USER/PASSWORD` — admin DB credentials
- Service-specific DB passwords: `ROUNDCUBE_DB_PASSWORD`, `GRAFANA_DB_PASSWORD`, `POSTGRES_EXPORTER_PASSWORD`

## Deploy mechanism

`./deploy.sh <stack>` does: `cd <stack>/ && source ../.env && docker stack deploy -c docker-compose.yml <stack>`. Relative config file paths in compose files are resolved relative to the stack directory.

## Scripts

All in `scripts/`. Main entry point is `./server.sh` which routes subcommands to individual scripts. Scripts that modify system state (ssh, firewall) require root.

## PostgreSQL tuning

Custom `postgresql.conf` mounted via Swarm config. Tuned for 16GB RAM: `shared_buffers=4GB`, `effective_cache_size=12GB`, `work_mem=64MB`. Loaded via `postgres -c config_file=/etc/postgresql/postgresql.conf`.

## Gotchas

- Docker Swarm does not support `cap_add` in deploy mode — fail2ban is disabled in docker-mailserver
- Traefik v3 uses `providers.swarm` (not `providers.docker` with swarmMode)
- Swarm config files are immutable — changing a config requires redeploying the stack (Docker creates a new config version)
- Health checks use container-level commands (not Swarm-level) — they trigger container restarts, not service rescheduling

## Language

The user communicates in Lithuanian. README, comments in scripts, and alert messages are in Lithuanian.
