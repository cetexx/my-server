#!/bin/bash
set -euo pipefail

# =============================================
# Backup sistema (loginis pg_dump — granuliariam restore).
# DR (visos VM avarija) dengiamas serveriai.lt VM snapshot'ais, tad off-site
# push čia SĄMONINGAI nedaromas.
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

BACKUP_DIR="/opt/my-server/backups"
KEEP_DAYS=7
DATE=$(date +%Y-%m-%d_%H-%M)

mkdir -p "$BACKUP_DIR"/{db,configs}

show_help() {
    echo "Naudojimas:"
    echo "  backup db [name]            Backup'ink DB (visas arba konkrečią)"
    echo "  backup globals              Backup'ink roles + slaptažodžius (pg_dumpall --globals)"
    echo "  backup configs              Backup'ink konfigūracijas (acme, mail, repo)"
    echo "  backup all                  Pilnas: globals + visos DB + configs + clean"
    echo "  backup restore <db> <file>  Atkurk DB iš .sql.gz (owner = <db>, arba 3-as arg)"
    echo "  backup list                 Parodyti backup'us"
    echo "  backup clean                Ištrinti senesnius nei ${KEEP_DAYS} dienos"
}

get_pg_container() {
    docker ps -qf "name=core_postgresql" | head -1
}

# Atominis, integrity-tikrintas dump: .tmp → gzip -t → mv. Grąžina 1 jei nepavyko.
dump_one() {
    local CONTAINER=$1 db=$2
    local FILE="$BACKUP_DIR/db/${db}_${DATE}.sql.gz"
    local TMP="${FILE}.tmp"
    echo -n "  $db → "
    if docker exec "$CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$db" --no-owner 2>/dev/null | gzip > "$TMP" \
        && gzip -t "$TMP" 2>/dev/null; then
        mv "$TMP" "$FILE"
        echo "$(du -h "$FILE" | cut -f1)"
        return 0
    else
        rm -f "$TMP"
        echo "NEPAVYKO ✗"
        return 1
    fi
}

backup_globals() {
    local CONTAINER; CONTAINER=$(get_pg_container)
    local FILE="$BACKUP_DIR/db/globals_${DATE}.sql.gz"
    local TMP="${FILE}.tmp"
    echo -n "  globals (roles+pw) → "
    if docker exec "$CONTAINER" pg_dumpall -U "$POSTGRES_USER" --globals-only 2>/dev/null | gzip > "$TMP" \
        && gzip -t "$TMP" 2>/dev/null; then
        mv "$TMP" "$FILE"; echo "$(du -h "$FILE" | cut -f1)"
    else
        rm -f "$TMP"; echo "NEPAVYKO ✗"; return 1
    fi
}

backup_db() {
    local DB_NAME=${1:-all}
    local CONTAINER; CONTAINER=$(get_pg_container)
    if [ -z "$CONTAINER" ]; then echo "Klaida: PostgreSQL konteineris nerastas"; exit 1; fi

    local failed=0
    if [ "$DB_NAME" = "all" ]; then
        echo "Backup'inu visas duombazes..."
        local DBS
        DBS=$(docker exec "$CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A \
            -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'")
        # Per-DB klaidos NEnutraukia ciklo (kad viena bloga DB nesugriautų viso backup)
        for db in $DBS; do
            dump_one "$CONTAINER" "$db" || failed=$((failed+1))
        done
    else
        dump_one "$CONTAINER" "$DB_NAME" || failed=$((failed+1))
    fi

    echo ""
    if [ "$failed" -gt 0 ]; then echo "DB backup: $failed nepavyko ✗"; return 1; fi
    echo "DB backup baigtas ✓"
}

backup_configs() {
    local FILE="$BACKUP_DIR/configs/configs_${DATE}.tar.gz"
    echo "Backup'inu konfigūracijas..."
    tar -czf "$FILE" -C / \
        opt/my-server/traefik/acme \
        opt/my-server/mailserver/config \
        opt/my-server/mailserver/state \
        2>/dev/null || true
    tar -rzf "$FILE" -C "$SCRIPT_DIR/.." \
        .env core/ monitoring/ mail/ 2>/dev/null || true
    echo "Config backup → $FILE ($(du -h "$FILE" | cut -f1))"
}

# restore <db> <file.sql.gz> [owner]  — owner default = <db> (db-create.sh: role==db).
# Objektai atkuriami owner'io vardu per SET ROLE (POSTGRES_USER = superuser).
restore_db() {
    local DB_NAME=${1:-} FILE=${2:-} OWNER=${3:-${1:-}}
    if [ -z "$DB_NAME" ] || [ -z "$FILE" ]; then
        echo "Naudojimas: backup restore <db> <file.sql.gz> [owner]"; exit 1
    fi
    [ -f "$FILE" ] || { echo "Klaida: failas nerastas: $FILE"; exit 1; }
    echo "⚠  RESTORE perrašys DB '$DB_NAME' turinį iš $FILE (owner=$OWNER)."
    echo "   Rolės/slaptažodžiai NEatkuriami — jei reikia, pirma įkelk globals_*.sql.gz."
    read -r -p "   Rašyk 'yes' tęsti: " ok
    [ "$ok" = "yes" ] || { echo "Atšaukta."; exit 1; }
    local CONTAINER; CONTAINER=$(get_pg_container)
    { echo "SET ROLE \"${OWNER}\";"; gunzip -c "$FILE"; } \
        | docker exec -i "$CONTAINER" psql -U "$POSTGRES_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q
    echo "Restore baigtas ✓: $DB_NAME"
}

backup_list() {
    echo "=== Backup'ai ==="; echo
    echo "--- DB ---"; ls -lh "$BACKUP_DIR/db/" 2>/dev/null || echo "(tuščia)"; echo
    echo "--- Configs ---"; ls -lh "$BACKUP_DIR/configs/" 2>/dev/null || echo "(tuščia)"; echo
    echo "Viso: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo 0)"
}

backup_clean() {
    echo "Trinu backup'us senesnius nei ${KEEP_DAYS} dienų..."
    local COUNT; COUNT=$(find "$BACKUP_DIR" -type f -mtime "+${KEEP_DAYS}" | wc -l)
    find "$BACKUP_DIR" -type f -mtime "+${KEEP_DAYS}" -delete
    echo "Ištrinta: $COUNT failų"
}

case "${1:-}" in
    db)      backup_db "${@:2}" ;;
    globals) backup_globals ;;
    configs) backup_configs ;;
    all)
        rc=0
        backup_globals || rc=1
        backup_db all || rc=1
        echo ""; backup_configs
        echo ""; backup_clean
        exit "$rc"
        ;;
    restore) restore_db "${@:2}" ;;
    list)    backup_list ;;
    clean)   backup_clean ;;
    *)       show_help ;;
esac
