#!/bin/bash
# Pakeisk esamos DB rolės connection limitą (2026-11-21).
#
# Naudojimas:
#   ./scripts/db-limit.sh <role> <limit>
#   ./scripts/db-limit.sh pickzy 38
#
# Saugo CLAUDE.md invariantą: visų ne superuser login rolių limitų suma
# ≤ 195 (max_connections 200 − rezervas). Jei naujoji suma jį viršytų,
# nieko nekeičia. ALTER ROLE galioja naujoms jungtims iškart — stack'o
# perdeploy'inti nereikia, esamos jungtys nenutraukiamos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

ROLE=${1:-}
LIMIT=${2:-}
CEILING=195

if [ -z "$ROLE" ] || [ -z "$LIMIT" ]; then
    echo "Naudojimas: ./scripts/db-limit.sh <role> <limit>"
    exit 1
fi

if ! echo "$ROLE" | grep -qE '^[a-z][a-z0-9_]*$'; then
    echo "Klaida: rolės pavadinimas gali turėti tik mažąsias raides, skaičius ir _"
    exit 1
fi

if ! echo "$LIMIT" | grep -qE '^[1-9][0-9]*$'; then
    echo "Klaida: limitas turi būti teigiamas sveikasis skaičius (-1 = be limito — draudžiama)"
    exit 1
fi

PG="$(docker ps -qf 'name=core_postgresql' | head -1)"
pg() {
    docker exec "$PG" psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc "$1"
}

CURRENT=$(pg "SELECT rolconnlimit FROM pg_roles WHERE rolname = '${ROLE}' AND NOT rolsuper AND rolcanlogin;")
if [ -z "$CURRENT" ]; then
    echo "Klaida: login rolės '${ROLE}' nėra (arba ji superuser)"
    exit 1
fi

OTHERS=$(pg "SELECT COALESCE(sum(rolconnlimit),0) FROM pg_roles WHERE rolconnlimit > 0 AND NOT rolsuper AND rolcanlogin AND rolname <> '${ROLE}';")
NEW_SUM=$((OTHERS + LIMIT))
if [ "$NEW_SUM" -gt "$CEILING" ]; then
    echo "Atsisakau: limitų suma būtų ${NEW_SUM} > ${CEILING} (kitų rolių ${OTHERS} + ${LIMIT})."
    echo "Pirma sumažink kitos rolės limitą arba pasirink mažesnį."
    exit 1
fi

pg "ALTER ROLE ${ROLE} CONNECTION LIMIT ${LIMIT};" >/dev/null
echo "Rolė '${ROLE}': ${CURRENT} → ${LIMIT}. Limitų suma: ${NEW_SUM} / ${CEILING}."
