#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env" 2>/dev/null || true
BACKUP_DIR="/opt/my-server/backups"
ACME="/opt/my-server/traefik/acme/acme.json"
PG_CONTAINER=$(docker ps -qf "name=core_postgresql" 2>/dev/null | head -1)

echo "╔══════════════════════════════════════════╗"
echo "║            Serverio statusas             ║"
echo "╚══════════════════════════════════════════╝"

# =============================================
# SVEIKATA — ops signalai vienu žvilgsniu (ko Portainer/Grafana nerodo)
# =============================================
echo ""
echo "=== ⚑ Sveikata (dėmesio ženklai) ==="
echo ""
ISSUES=()

# 1. Servisai: desired vs running (pagauna tyliai nukritusius, pvz. 0/1)
while read -r name rep; do
    [ -z "${rep:-}" ] && continue
    cur=${rep%%/*}; des=${rep##*/}
    if [ "$cur" != "$des" ]; then ISSUES+=("Servisas $name: $rep — ne visi replikai veikia"); fi
done < <(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null)

# 2. Backup šviežumas (kasdien → įspėk jei >26h ar visai nėra)
newest=$(find "$BACKUP_DIR/db" -name '*.sql.gz' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
if [ -n "$newest" ]; then
    age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
    [ "$age_h" -gt 26 ] && ISSUES+=("DB backup pasenęs: prieš ${age_h}h (>26h — patikrink cron)")
    find "$BACKUP_DIR/db" -name 'globals_*.sql.gz' -mtime -2 2>/dev/null | grep -q . || ISSUES+=("Nėra šviežio globals (roles) backup — restore be rolių")
else
    ISSUES+=("NĖRA DB backup'ų — 'backup all' niekada nesisuko?")
fi

# 3. PostgreSQL: -1 (unlimited) rolės + connection budget
if [ -n "$PG_CONTAINER" ]; then
    neg=$(docker exec "$PG_CONTAINER" psql -U "${POSTGRES_USER:-admin}" -d "${POSTGRES_DB:-postgres}" -tA -c \
        "SELECT string_agg(rolname,', ') FROM pg_roles WHERE rolconnlimit=-1 AND NOT rolsuper AND rolcanlogin;" 2>/dev/null)
    [ -n "${neg:-}" ] && ISSUES+=("PG rolės be conn limito (-1): $neg — vienas leak suvalgytų visą klasterį")
    sum=$(docker exec "$PG_CONTAINER" psql -U "${POSTGRES_USER:-admin}" -d "${POSTGRES_DB:-postgres}" -tA -c \
        "SELECT COALESCE(sum(rolconnlimit),0) FROM pg_roles WHERE rolconnlimit>0 AND NOT rolsuper AND rolcanlogin;" 2>/dev/null)
    [ -n "${sum:-}" ] && [ "$sum" -gt 195 ] 2>/dev/null && ISSUES+=("PG conn limitų suma $sum > 195 (max_connections 200)")
else
    ISSUES+=("PostgreSQL konteineris nepasiekiamas")
fi

# 4. Vardų kolizijos: bare cross-stack hostai .env'uose (Swarm alias round-robin bug)
coll=$(grep -rlE '_HOST=(redis|app|db|api|cache|worker|web)$' /opt/*/.env 2>/dev/null | xargs -r -n1 dirname 2>/dev/null | xargs -r -n1 basename 2>/dev/null | tr '\n' ' ')
[ -n "${coll:-}" ] && ISSUES+=("Bare-name hostai (kolizijos rizika): $coll — naudok <stack>_<svc>")

# 5. Cert galiojimas (Traefik acme.json) — best-effort
if command -v jq &>/dev/null && command -v openssl &>/dev/null && [ -r "$ACME" ]; then
    while read -r dom b64; do
        { [ -z "${b64:-}" ] || [ "$b64" = "null" ]; } && continue
        end=$(echo "$b64" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        [ -z "${end:-}" ] && continue
        days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        [ "$days" -lt 14 ] 2>/dev/null && ISSUES+=("Cert $dom galioja dar $days d. (<14)")
    done < <(jq -r 'to_entries[]|.value.Certificates[]?|(.domain.main)+" "+(.certificate)' "$ACME" 2>/dev/null)
fi

if [ "${#ISSUES[@]}" -eq 0 ]; then
    echo "  ✓ Viskas tvarkoje — jokių dėmesio ženklų."
else
    for i in "${ISSUES[@]}"; do echo "  ⚠ $i"; done
    echo ""
    echo "  → ${#ISSUES[@]} dėmesio ženklas(-ai)"
fi

# =============================================
# Sistema
# =============================================
echo ""
echo "=== Sistema ==="
echo ""
CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' || echo "?")
echo "CPU:    ${CPU_USAGE}% naudojama"
command -v free &>/dev/null && echo "RAM:    $(free -h | awk '/Mem:/ {printf "%s / %s (%s laisva)", $3, $2, $4}')"
echo "Disk:   $(df -h / | awk 'NR==2 {printf "%s / %s (%s laisva, %s užimta)", $3, $2, $4, $5}')"
echo "Uptime: $(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1,$2}')"

# =============================================
# Docker
# =============================================
echo ""
echo "=== Docker Stacks ==="
echo ""
docker stack ls 2>/dev/null || echo "Swarm neinicializuotas"
echo ""
echo "=== Servisai ==="
echo ""
docker service ls --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null || echo "(nėra servisų)"

# =============================================
# Duombazės + connection budget
# =============================================
echo ""
echo "=== Duombazės (dydis | conn) ==="
echo ""
if [ -n "$PG_CONTAINER" ]; then
    docker exec "$PG_CONTAINER" psql -U "${POSTGRES_USER:-admin}" -d "${POSTGRES_DB:-postgres}" -c "
        SELECT d.datname AS db, pg_size_pretty(pg_database_size(d.datname)) AS size,
               (SELECT count(*) FROM pg_stat_activity WHERE datname=d.datname) AS conn
        FROM pg_database d WHERE d.datistemplate=false ORDER BY pg_database_size(d.datname) DESC;" 2>/dev/null || echo "PostgreSQL nepasiekiamas"
    echo "Conn budget: ${sum:-?} / 195 rezervuota (max_connections 200)"
else
    echo "PostgreSQL neveikia"
fi

# =============================================
# Backup'ai
# =============================================
echo ""
echo "=== Backup'ai ==="
echo ""
if [ -d "$BACKUP_DIR" ]; then
    last=$(find "$BACKUP_DIR" -type f -name "*.gz" -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1 | awk '{print $2}')
    echo "Paskutinis: ${last:-nėra}"
    echo "Viso:       $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 0)"
else
    echo "Backup direktorija nesukurta"
fi

# =============================================
# Diskas per projektą
# =============================================
echo ""
echo "=== Disko naudojimas ==="
echo ""
[ -d /opt/my-server ] && du -sh /opt/my-server/*/ 2>/dev/null | sort -rh || echo "/opt/my-server nėra"
echo ""
