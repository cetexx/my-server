#!/bin/bash
set -euo pipefail

# =============================================
# Parodo visas DB ir jų userius
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

echo "=== Duombazės ==="
echo ""

docker exec "$(docker ps -qf 'name=core_postgresql' | head -1)" psql \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    -c "
        SELECT
            d.datname AS db,
            r.rolname AS owner,
            r.rolconnlimit AS conn_limit,
            pg_size_pretty(pg_database_size(d.datname)) AS size,
            (SELECT count(*) FROM pg_stat_activity WHERE datname = d.datname) AS active_conn
        FROM pg_database d
        JOIN pg_roles r ON d.datdba = r.oid
        WHERE d.datistemplate = false
        ORDER BY d.datname;
    "
