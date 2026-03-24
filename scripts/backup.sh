#!/bin/bash
set -euo pipefail

# =============================================
# Backup sistema
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

BACKUP_DIR="/opt/my-server/backups"
KEEP_DAYS=7
DATE=$(date +%Y-%m-%d_%H-%M)

mkdir -p "$BACKUP_DIR"/{db,configs}

show_help() {
    echo "Naudojimas:"
    echo "  backup db [name]     Backup'ink DB (visas arba konkrečią)"
    echo "  backup configs       Backup'ink konfigūracijas"
    echo "  backup all           Pilnas backup'as"
    echo "  backup list          Parodyti backup'us"
    echo "  backup clean         Ištrinti senesnius nei ${KEEP_DAYS} dienos"
}

get_pg_container() {
    docker ps -qf "name=core_postgresql" | head -1
}

backup_db() {
    local DB_NAME=${1:-all}
    local CONTAINER
    CONTAINER=$(get_pg_container)

    if [ -z "$CONTAINER" ]; then
        echo "Klaida: PostgreSQL konteineris nerastas"
        exit 1
    fi

    if [ "$DB_NAME" = "all" ]; then
        echo "Backup'inu visas duombazes..."

        # Gaunam visų DB sąrašą
        local DBS
        DBS=$(docker exec "$CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A \
            -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'")

        for db in $DBS; do
            local FILE="$BACKUP_DIR/db/${db}_${DATE}.sql.gz"
            echo -n "  $db → "
            docker exec "$CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$db" --no-owner | gzip > "$FILE"
            local SIZE
            SIZE=$(du -h "$FILE" | cut -f1)
            echo "$FILE ($SIZE)"
        done
    else
        local FILE="$BACKUP_DIR/db/${DB_NAME}_${DATE}.sql.gz"
        echo -n "Backup'inu $DB_NAME → "
        docker exec "$CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$DB_NAME" --no-owner | gzip > "$FILE"
        local SIZE
        SIZE=$(du -h "$FILE" | cut -f1)
        echo "$FILE ($SIZE)"
    fi

    echo ""
    echo "DB backup baigtas"
}

backup_configs() {
    local FILE="$BACKUP_DIR/configs/configs_${DATE}.tar.gz"

    echo "Backup'inu konfigūracijas..."
    tar -czf "$FILE" \
        -C / \
        opt/my-server/traefik/acme \
        opt/my-server/mailserver/config \
        2>/dev/null || true

    # Pridedame repo failus
    tar -rzf "$FILE" \
        -C "$SCRIPT_DIR/.." \
        .env \
        core/ \
        monitoring/ \
        mail/ \
        2>/dev/null || true

    local SIZE
    SIZE=$(du -h "$FILE" | cut -f1)
    echo "Config backup → $FILE ($SIZE)"
}

backup_list() {
    echo "=== Backup'ai ==="
    echo ""
    echo "--- DB ---"
    ls -lh "$BACKUP_DIR/db/" 2>/dev/null || echo "(tuščia)"
    echo ""
    echo "--- Configs ---"
    ls -lh "$BACKUP_DIR/configs/" 2>/dev/null || echo "(tuščia)"
    echo ""
    local TOTAL
    TOTAL=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "0")
    echo "Viso: $TOTAL"
}

backup_clean() {
    echo "Trinu backup'us senesnius nei ${KEEP_DAYS} dienų..."
    local COUNT
    COUNT=$(find "$BACKUP_DIR" -type f -mtime "+${KEEP_DAYS}" | wc -l)
    find "$BACKUP_DIR" -type f -mtime "+${KEEP_DAYS}" -delete
    echo "Ištrinta: $COUNT failų"
}

case "${1:-}" in
    db)      backup_db "${@:2}" ;;
    configs) backup_configs ;;
    all)
        backup_db all
        echo ""
        backup_configs
        echo ""
        backup_clean
        ;;
    list)    backup_list ;;
    clean)   backup_clean ;;
    *)       show_help ;;
esac
