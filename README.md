# My Server — Docker Swarm VPS Infrastructure

Docker Swarm paremta infrastruktūra VPS serveriui su daugybe projektų.

## Serveris

- **OS**: Rocky Linux 10 (KVM)
- **CPU**: 4 x 2.30 GHz
- **RAM**: 16 GB
- **Disk**: 160 GB SSD
- **Tinklas**: 1 Gbps (iki 32 TB/mėn.)

## Architektūra

```
Traefik (reverse proxy, SSL, rate limiting)
├── core          PostgreSQL 17, Redis, Portainer, Adminer, Playwright, Shepherd
├── monitoring    Prometheus, Alertmanager, Grafana, Node Exporter, cAdvisor, Dozzle
└── mail          docker-mailserver, Roundcube
```

## Reikalavimai

- VPS su Linux (Rocky Linux / RHEL / Ubuntu / Debian)
- Docker Engine 24+
- Domenas su DNS nukreiptu į VPS IP (`*.example.com → A → VPS_IP`)

## Greitas startas

```bash
# 1. Klonuok
git clone git@github.com:cetexx/my-server.git /opt/my-server
cd /opt/my-server

# 2. Konfigūruok
cp .env.example .env
nano .env                           # pakeisk DOMAIN, slaptažodžius

# 3. Pradinis setup (SELinux, Docker, tinklai, cron)
sudo ./server.sh setup

# 4. Firewall
sudo ./server.sh firewall setup

# 5. Pridėk savo IP į whitelist
./server.sh whitelist myip

# 6. Deploy
./server.sh deploy all

# 7. Sukurk pirmą mail accountą
./server.sh mail add admin@example.com

# 8. SSH kietinimas (po to kai patikrinai key prisijungimą!)
sudo ./server.sh ssh add tavo-vardas --docker
sudo ./server.sh ssh harden
```

## Failų struktūra

```
├── server.sh                          # Pagrindinis valdymo CLI
├── setup.sh                           # Pradinis setup (SELinux, Docker, cron)
├── deploy.sh                          # Stack deployment
├── .env.example                       # Konfigūracijos šablonas
│
├── core/
│   ├── docker-compose.yml             # Traefik, PostgreSQL, Redis, Portainer, Adminer, Playwright, Shepherd
│   ├── init-db/init-databases.sh      # DB inicializacija (Roundcube, Grafana, exporter)
│   ├── postgresql/postgresql.conf     # PG tuning (4GB shared_buffers, optimizuota 16GB RAM)
│   └── docker-daemon.json             # Docker daemon konfig (log rotation)
│
├── monitoring/
│   ├── docker-compose.yml             # Prometheus, Alertmanager, Grafana, Node Exporter, cAdvisor, Dozzle
│   ├── prometheus/
│   │   ├── prometheus.yml             # Scrape konfigas
│   │   └── alert-rules.yml            # Alertai (CPU, RAM, disk, konteineriai, PG, Traefik)
│   ├── alertmanager/
│   │   └── alertmanager.yml           # Email notifikacijos
│   └── grafana/
│       ├── provisioning/
│       │   ├── datasources/datasource.yml
│       │   └── dashboards/dashboards.yml
│       └── dashboards/                # Auto-provision dashboardai
│           ├── node-exporter.json     # Serverio metrikos
│           ├── docker.json            # Konteinerių metrikos
│           ├── postgresql.json        # DB metrikos
│           └── traefik.json           # Proxy metrikos
│
├── mail/
│   └── docker-compose.yml             # docker-mailserver, Roundcube, certs-dumper
│
└── scripts/
    ├── db-create.sh                   # Sukurti izoliuotą DB projektui
    ├── db-delete.sh                   # Ištrinti DB (su apsauga)
    ├── db-list.sh                     # DB sąrašas
    ├── backup.sh                      # DB ir konfigų backup
    ├── mail-manage.sh                 # Email accountų valdymas
    ├── ssh-manage.sh                  # SSH vartotojų valdymas
    ├── whitelist.sh                   # Admin IP whitelist
    ├── firewall-setup.sh              # Firewall (firewalld / ufw)
    ├── status.sh                      # Serverio statusas
    ├── cron-setup.sh                  # Cron job instaliacija
    └── check-certs.sh                 # SSL sertifikatų tikrinimas
```

## Valdymas per `server.sh`

```bash
# Statusas
./server.sh status                     # Pilnas serverio statusas
./server.sh logs core_traefik          # Servisų logai

# Duombazės
./server.sh db create my_app           # Nauja izoliuota DB + useris + random password
./server.sh db list                    # Visos DB, dydžiai, prisijungimai
./server.sh db delete my_app           # Trynimas (su apsauga nuo svarbių DB)

# Mail
./server.sh mail add admin@example.com # Sukurk email accountą
./server.sh mail list                  # Visi accountai
./server.sh mail alias info@ admin@    # Email alias
./server.sh mail dkim setup            # DKIM raktai

# SSH
sudo ./server.sh ssh add jonas         # Pridėk vartotoją (SSH key iš stdin)
sudo ./server.sh ssh add jonas --docker  # + Docker prieiga
sudo ./server.sh ssh list              # Visi vartotojai
sudo ./server.sh ssh harden            # Užkietink (disable password, root login)

# Saugumas
./server.sh whitelist myip             # Auto-detect ir pridėk savo IP
./server.sh whitelist add 1.2.3.4      # Pridėk IP
./server.sh whitelist list             # Dabartinis whitelist
sudo ./server.sh firewall setup        # Firewall su reikiamais portais
./server.sh certs check                # SSL sertifikatų galiojimas

# Backup
./server.sh backup all                 # Pilnas backup (DB + configs)
./server.sh backup db my_app           # Konkrečios DB

# Deploy
./server.sh deploy core                # Vienas stack'as
./server.sh deploy all                 # Viskas
```

## Naujas projektas

Projektai laikomi atskiruose repo ir deploy'inami tiesiogiai ant serverio:

```bash
# 1. Ant serverio: sukurk DB (jei reikia)
./server.sh db create my_app

# 2. Savo projekto repo: sukurk docker-compose.yml su:
#    - image: tavo-user/tavo-app:latest
#    - traefik labels (domenas, SSL)
#    - shepherd.enable=true (auto-update)
#    - tinklai: traefik-public, internal

# 3. Pirmas deploy ant serverio:
docker stack deploy -c docker-compose.yml my-app

# 4. Tolesni atnaujinimai — automatiškai:
#    Push naują image → Shepherd per 15 min atnaujins servisą
```

Srautas: `Traefik → App` (Varnish pridedamas projekto compose faile jei reikia)

## Playwright (headless browser)

Bendras browserless/chromium servisas visiems projektams:

```javascript
// Prisijungimas iš projekto
const browser = await chromium.connectOverCDP(
  `ws://core_playwright:3000?token=${process.env.PLAYWRIGHT_TOKEN}`
);
```

REST API: `https://playwright.example.com` (IP whitelist)

## Tinklai

| Tinklas | Paskirtis |
|---|---|
| `traefik-public` | HTTP routing per Traefik |
| `internal` | Vidinė komunikacija (DB, Redis, metrikos) |

Visi stack'ai jungiasi per šiuos du overlay tinklus.

## Subdomenai

| Servisas | URL | IP Whitelist |
|---|---|---|
| Traefik | `traefik.example.com` | taip |
| Portainer | `portainer.example.com` | taip |
| Adminer | `adminer.example.com` | taip |
| Grafana | `grafana.example.com` | taip |
| Prometheus | `prometheus.example.com` | taip |
| Dozzle | `logs.example.com` | taip |
| Alertmanager | `alerts.example.com` | taip |
| Playwright | `playwright.example.com` | taip |
| Roundcube | `mail.example.com` | ne (rate limit) |
| Projektai | `*.example.com` | ne (rate limit) |

## DNS setup

Sukurk šiuos DNS A įrašus nukreiptus į VPS IP:

```
example.com         → VPS_IP
*.example.com       → VPS_IP    (wildcard subdomenams)
```

Mail serveriui papildomai:

```
MX   example.com    → mail.example.com (priority 10)
TXT  example.com    → "v=spf1 mx -all"
TXT  _dmarc         → "v=DMARC1; p=quarantine"
```

DKIM: `./server.sh mail dkim setup` ir `./server.sh mail dkim show` — sukels DNS TXT įrašą.

## Saugumas

- **SSH**: tik key-based auth, root login uždraustas, max 3 bandymai
- **Firewall**: firewalld (Rocky) / ufw (Ubuntu) su atidarytais tik reikiamais portais (22, 80, 443, 25, 587, 993)
- **SELinux**: setup.sh automatiškai sukonfigūruoja Docker prieigą (Rocky Linux)
- **IP Whitelist**: admin tools pasiekiami tik iš leistinų IP
- **DB izoliacija**: kiekvienas projektas gauna atskirą DB userį su connection limitu
- **SSL**: automatiniai Let's Encrypt sertifikatai per Traefik
- **Rate limiting**: 100 req/s su burst 50 viešiems servisams per Traefik
- **Playwright token**: API prieiga tik su tokenu
- **Auto updates**: unattended OS security patch'ai (dnf-automatic / unattended-upgrades)
- **Health checks**: Docker automatiškai restartina numirusius servisus

## Monitoringas

Prometheus renka metrikas, Grafana vizualizuoja. 4 auto-provision dashboardai:

- **Serveris** — CPU, RAM, disk, network, I/O, uptime
- **Docker konteineriai** — CPU/RAM/network per konteinerį
- **PostgreSQL** — connections, DB dydžiai, cache hit ratio, deadlocks
- **Traefik** — requests/s, response time, HTTP status codes, error rate

Alertai:

| Alertas | Triggeris |
|---|---|
| HighCpuUsage | CPU >85% 5 min |
| HighMemoryUsage | RAM >90% 5 min |
| DiskSpaceLow / Critical | Disk >85% / >95% |
| ContainerDown | Konteineris neatsako 2 min |
| PostgresqlDown | DB nepasiekiama 1 min |
| PostgresqlTooManyConnections | >80% connection limito |
| PostgresqlDeadlocks | Aptiktas deadlock |
| TraefikHighErrorRate | >5% 5xx klaidų |

Alertai automatiškai siunčiami email'u per Alertmanager → docker-mailserver.

## Memory alokacija

```
Core:        1G (traefik) + 2G (pgsql) + 512M (redis) + 2G (playwright) + 128M (shepherd) = 5.6 GB
Monitoring:  1G (prom) + 512M (grafana) + 256M (cadvisor) + 256M (alertmanager) + 256M (pg-exp) + 256M (dozzle) = 2.5 GB
Mail:        2G (mailserver) = 2.0 GB
OS + Docker: ~2 GB
Laisva:      ~4 GB (projektams)
```

## Cron

| Kada | Kas |
|---|---|
| Sekmadieniais 4:00 | Docker cleanup (seni images, volumes) |
| Kasdien 6:00 | SSL sertifikatų galiojimo tikrinimas |
