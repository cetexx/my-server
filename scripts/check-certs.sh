#!/bin/bash
set -euo pipefail

# =============================================
# SSL sertifikatų galiojimo tikrinimas
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env" 2>/dev/null || true

DOMAIN=${DOMAIN:-example.com}
WARN_DAYS=14
EXIT_CODE=0

echo "=== SSL sertifikatų tikrinimas ==="
echo ""

check_cert() {
    local host=$1
    local expiry
    local days_left

    expiry=$(echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    if [ -z "$expiry" ]; then
        echo "  KLAIDA: $host — nepavyko patikrinti"
        EXIT_CODE=1
        return
    fi

    days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null) - $(date +%s) ) / 86400 ))

    if [ "$days_left" -lt 0 ]; then
        echo "  PASIBAIGĘS: $host — baigėsi prieš ${days_left#-} d."
        EXIT_CODE=1
    elif [ "$days_left" -lt "$WARN_DAYS" ]; then
        echo "  GREITAI: $host — liko $days_left d."
        EXIT_CODE=1
    else
        echo "  OK: $host — liko $days_left d."
    fi
}

# Tikrinam visus subdomenus
for sub in traefik portainer adminer grafana prometheus logs mail; do
    check_cert "${sub}.${DOMAIN}"
done

echo ""
if [ $EXIT_CODE -ne 0 ]; then
    echo "Yra problemų su sertifikatais!"
else
    echo "Visi sertifikatai OK"
fi

exit $EXIT_CODE
