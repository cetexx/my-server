#!/bin/bash
set -euo pipefail

# =============================================
# Sukuria naują izoliuotą DB projektui
#
# Naudojimas:
#   ./scripts/db-create.sh my_app
#   ./scripts/db-create.sh my_app 20    # su connection limitu
#
# Rezultatas:
#   - Sukuriamas DB useris: my_app
#   - Sukuriama DB: my_app
#   - Generuojamas random slaptažodis
#   - Useris gali jungtis TIK prie savo DB
#   - Atspausdina connection string projektui
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

DB_NAME=${1:-}
CONN_LIMIT=${2:-15}

if [ -z "$DB_NAME" ]; then
    echo "Naudojimas: ./scripts/db-create.sh <db_name> [connection_limit]"
    echo ""
    echo "Pavyzdys:"
    echo "  ./scripts/db-create.sh my_app"
    echo "  ./scripts/db-create.sh my_app 20"
    exit 1
fi

# Validacija — tik lowercase, skaičiai, underscores
if ! echo "$DB_NAME" | grep -qE '^[a-z][a-z0-9_]*$'; then
    echo "Klaida: DB pavadinimas gali turėti tik mažąsias raides, skaičius ir _ (pvz: my_app)"
    exit 1
fi

# Generuojam random slaptažodį
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

echo "Kuriu duombazę '$DB_NAME'..."

docker exec $(docker ps -qf "name=core_postgresql") psql \
    -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    -c "
        -- Sukuriam userį su connection limitu
        CREATE USER ${DB_NAME} WITH PASSWORD '${DB_PASSWORD}' CONNECTION LIMIT ${CONN_LIMIT};

        -- Sukuriam DB, owneris — naujas useris
        CREATE DATABASE ${DB_NAME} OWNER ${DB_NAME};

        -- Užrakinam — kiti useriai negali jungtis
        REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
    "

# Užrakinam public schema šitoj DB
docker exec $(docker ps -qf "name=core_postgresql") psql \
    -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$DB_NAME" \
    -c "
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        GRANT ALL ON SCHEMA public TO ${DB_NAME};
    "

echo ""
echo "=== DB sukurta sėkmingai ==="
echo ""
echo "Prisijungimo duomenys (išsaugok!):"
echo "  DB:       ${DB_NAME}"
echo "  User:     ${DB_NAME}"
echo "  Password: ${DB_PASSWORD}"
echo "  Host:     core_postgresql"
echo "  Port:     5432"
echo ""
echo "Connection string projektui:"
echo "  DATABASE_URL=postgresql://${DB_NAME}:${DB_PASSWORD}@core_postgresql:5432/${DB_NAME}"
echo ""
echo "Docker compose environment:"
echo "  environment:"
echo "    DATABASE_URL: postgresql://${DB_NAME}:${DB_PASSWORD}@core_postgresql:5432/${DB_NAME}"
