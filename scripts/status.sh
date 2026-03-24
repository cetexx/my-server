#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║            Serverio statusas             ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# =============================================
# Sistema
# =============================================
echo "=== Sistema ==="
echo ""

# CPU
CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' || echo "?")
echo "CPU:    ${CPU_USAGE}% naudojama"

# RAM
if command -v free &>/dev/null; then
    RAM_INFO=$(free -h | awk '/Mem:/ {printf "%s / %s (%s laisva)", $3, $2, $4}')
    echo "RAM:    $RAM_INFO"
fi

# Disk
DISK_INFO=$(df -h / | awk 'NR==2 {printf "%s / %s (%s laisva, %s užimta)", $3, $2, $4, $5}')
echo "Disk:   $DISK_INFO"

# Uptime
echo "Uptime: $(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1,$2}')"

echo ""

# =============================================
# Docker Swarm
# =============================================
echo "=== Docker Stacks ==="
echo ""

if docker stack ls &>/dev/null 2>&1; then
    docker stack ls
else
    echo "Docker Swarm neinicializuotas"
fi

echo ""
echo "=== Servisai ==="
echo ""

if docker service ls &>/dev/null 2>&1; then
    docker service ls --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null || docker service ls
else
    echo "(nėra servisų)"
fi

echo ""

# =============================================
# Duombazės
# =============================================
echo "=== Duombazės ==="
echo ""

PG_CONTAINER=$(docker ps -qf "name=core_postgresql" 2>/dev/null | head -1)

if [ -n "$PG_CONTAINER" ]; then
    source "$SCRIPT_DIR/../.env" 2>/dev/null || true
    docker exec "$PG_CONTAINER" psql -U "${POSTGRES_USER:-admin}" -d "${POSTGRES_DB:-default}" -c "
        SELECT
            d.datname AS db,
            pg_size_pretty(pg_database_size(d.datname)) AS size,
            (SELECT count(*) FROM pg_stat_activity WHERE datname = d.datname) AS conn
        FROM pg_database d
        WHERE d.datistemplate = false
        ORDER BY pg_database_size(d.datname) DESC;
    " 2>/dev/null || echo "PostgreSQL nepasiekiamas"
else
    echo "PostgreSQL neveikia"
fi

echo ""

# =============================================
# Backup'ai
# =============================================
echo "=== Backup'ai ==="
echo ""

BACKUP_DIR="/opt/my-server/backups"
if [ -d "$BACKUP_DIR" ]; then
    LAST_BACKUP=$(find "$BACKUP_DIR" -type f -name "*.gz" -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1)
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "0")
    if [ -n "$LAST_BACKUP" ]; then
        echo "Paskutinis: $(echo "$LAST_BACKUP" | awk '{print $2}')"
        echo "Viso:       $BACKUP_SIZE"
    else
        echo "Backup'ų nėra"
    fi
else
    echo "Backup direktorija nesukurta"
fi

echo ""

# =============================================
# Disk naudojimas per servisą
# =============================================
echo "=== Disko naudojimas ==="
echo ""

if [ -d "/opt/my-server" ]; then
    du -sh /opt/my-server/*/ 2>/dev/null | sort -rh
else
    echo "/opt/my-server neegzistuoja"
fi

echo ""
