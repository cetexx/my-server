#!/bin/bash
set -euo pipefail

# =============================================
# Ištrina projekto DB ir userį
#
# Naudojimas:
#   ./scripts/db-delete.sh my_app
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

DB_NAME=${1:-}

if [ -z "$DB_NAME" ]; then
    echo "Naudojimas: ./scripts/db-delete.sh <db_name>"
    exit 1
fi

# Apsauga nuo svarbių DB trynimo
PROTECTED="default postgres roundcube grafana"
for p in $PROTECTED; do
    if [ "$DB_NAME" = "$p" ]; then
        echo "Klaida: '$DB_NAME' yra apsaugota DB, trinti negalima"
        exit 1
    fi
done

read -t 30 -p "Tikrai ištrinti DB '$DB_NAME' ir userį? (yes/no): " CONFIRM || CONFIRM="no"
if [ "$CONFIRM" != "yes" ]; then
    echo "Atšaukta"
    exit 0
fi

echo "Trinu '$DB_NAME'..."

docker exec "$(docker ps -qf 'name=core_postgresql' | head -1)" psql \
    -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    -c "
        -- Numetam visus prisijungimus
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();

        -- Trinam DB ir userį
        DROP DATABASE IF EXISTS ${DB_NAME};
        DROP USER IF EXISTS ${DB_NAME};
    "

echo "DB '$DB_NAME' ir useris ištrinti"
