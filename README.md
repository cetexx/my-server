# My Server — Docker Swarm VPS Infrastructure

Docker Swarm paremta infrastruktūra VPS serveriui su daugybe projektų.

## Architektūra

```
Traefik (reverse proxy, SSL)
├── core          PostgreSQL 17, Redis, Portainer, Adminer
├── monitoring    Prometheus, Grafana, Node Exporter, cAdvisor, Dozzle
├── mail          docker-mailserver, Roundcube
└── projects/     Atskiri projektai su Varnish cache
```

## Reikalavimai

- VPS su Linux (Ubuntu/Debian)
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

# 3. Pradinis setup
sudo ./server.sh setup

# 4. Pridėk savo IP į whitelist
./server.sh whitelist myip

# 5. Deploy
./server.sh deploy all
```

## Failų struktūra

```
├── server.sh                          # Pagrindinis valdymo CLI
├── setup.sh                           # Pradinis setup
├── deploy.sh                          # Stack deployment
├── .env.example                       # Konfigūracijos šablonas
│
├── core/
│   ├── docker-compose.yml             # Traefik, PostgreSQL, Redis, Portainer, Adminer
│   ├── init-db/init-databases.sh      # DB inicializacija (Roundcube, Grafana, exporter)
│   ├── postgresql/postgresql.conf     # PG tuning (4GB shared_buffers, optimizuota 16GB RAM)
│   └── docker-daemon.json             # Docker daemon konfig (log rotation)
│
├── monitoring/
│   ├── docker-compose.yml             # Prometheus, Grafana, Node Exporter, cAdvisor, Dozzle
│   ├── prometheus/
│   │   ├── prometheus.yml             # Scrape konfigas
│   │   └── alert-rules.yml            # Alertai (CPU, RAM, disk, konteineriai, PG, Traefik)
│   └── grafana/
│       └── provisioning/datasources/datasource.yml
│
├── mail/
│   └── docker-compose.yml             # docker-mailserver, Roundcube, certs-dumper
│
├── projects/
│   └── example/
│       ├── docker-compose.yml         # Šablonas su Varnish cache sidecar
│       └── varnish.vcl                # Cache taisyklės (statika 30d, HTML 5m)
│
└── scripts/
    ├── db-create.sh                   # Sukurti izoliuotą DB projektui
    ├── db-delete.sh                   # Ištrinti DB (su apsauga)
    ├── db-list.sh                     # DB sąrašas
    ├── backup.sh                      # DB ir konfigų backup
    ├── ssh-manage.sh                  # SSH vartotojų valdymas
    ├── whitelist.sh                   # Admin IP whitelist
    ├── firewall-setup.sh              # UFW firewall
    ├── status.sh                      # Serverio statusas
    ├── cron-setup.sh                  # Cron job instaliation
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

# SSH
sudo ./server.sh ssh add jonas         # Pridėk vartotoją (SSH key iš stdin)
sudo ./server.sh ssh add jonas --docker  # + Docker prieiga
sudo ./server.sh ssh list              # Visi vartotojai
sudo ./server.sh ssh harden            # Užkietink (disable password, root login)

# Saugumas
./server.sh whitelist myip             # Auto-detect ir pridėk savo IP
./server.sh whitelist add 1.2.3.4      # Pridėk IP
./server.sh whitelist list             # Dabartinis whitelist
sudo ./server.sh firewall setup        # UFW su reikiamais portais
./server.sh certs check                # SSL sertifikatų galiojimas

# Backup
./server.sh backup all                 # Pilnas backup (DB + configs)
./server.sh backup db my_app           # Konkrečios DB

# Deploy
./server.sh deploy core                # Vienas stack'as
./server.sh deploy projects/my-app     # Projektas
./server.sh deploy all                 # Viskas
```

## Naujas projektas

```bash
# 1. Kopijuok šabloną
cp -r projects/example projects/my-app

# 2. Sukurk DB
./server.sh db create my_app
# Atspausdins: DATABASE_URL=postgresql://my_app:xK7mN2pQ9@core_postgresql:5432/my_app

# 3. Redaguok compose (image, domenas, env)
nano projects/my-app/docker-compose.yml

# 4. Pritaikyk Varnish cache taisykles
nano projects/my-app/varnish.vcl

# 5. Deploy
./server.sh deploy projects/my-app
```

Srautas: `Traefik → Varnish (SSD cache) → App`

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
| Roundcube | `mail.example.com` | ne (vieša) |
| Projektai | `*.example.com` | ne (vieša) |

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

DKIM sukonfigūruojamas po docker-mailserver deploy.

## Saugumas

- **SSH**: tik key-based auth, root login uždraustas, max 3 bandymai
- **Firewall**: UFW su atidarytais tik reikiamais portais (22, 80, 443, 25, 587, 993)
- **IP Whitelist**: admin tools pasiekiami tik iš leistinų IP
- **DB izoliacija**: kiekvienas projektas gauna atskirą DB userį su connection limitu, kiti projektai negali pasiekti svetimų DB
- **SSL**: automatiniai Let's Encrypt sertifikatai per Traefik
- **Auto updates**: unattended OS security patch'ai
- **Health checks**: Docker automatiškai restartina numirusius servisus

## Monitoringas

Prometheus renka metrikas, Grafana vizualizuoja. Sukonfigūruoti alertai:

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

Alertus galima siųsti į Telegram/email per Grafana notification channels.

## Cron

| Kada | Kas |
|---|---|
| Sekmadieniais 4:00 | Docker cleanup (seni images, volumes) |
| Kasdien 6:00 | SSL sertifikatų galiojimo tikrinimas |
