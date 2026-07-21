#!/bin/bash
set -euo pipefail

# =============================================
# Cron job'ų setup'as (idempotentiškas)
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Cron setup ==="
echo ""

# Kiekviena valdoma eilutė pažymėta '# my-server' — kad re-run pašalintų SENAS
# (anksčiau likdavo → dublikatai) ir įrašytų tik dabartines.
#
# SVARBU: docker prune BE --volumes — named volume'ai laikomi duomenimis
# (redis AOF, prometheus TSDB ir pan.), '--volumes' su 'until' filtru juos
# vis tiek gali ištrinti. Image/container/network prune saugu.
CRON_LINES=(
    "0 3 * * 0 docker image prune -af --filter 'until=168h' >> /var/log/docker-prune.log 2>&1  # my-server: image cleanup"
    "0 4 * * 0 docker system prune -af --filter 'until=168h' >> /var/log/docker-cleanup.log 2>&1  # my-server: system cleanup (be volumes)"
    "0 6 * * * ${REPO_DIR}/scripts/check-certs.sh >> /var/log/cert-check.log 2>&1  # my-server: cert check"
    "0 3 * * * ${REPO_DIR}/scripts/backup.sh all >> /var/log/backup.log 2>&1  # my-server: DB+config backup (BŪTINA 'all' argumentas)"
)

# Instaliuojam: pašalinam visas ankstesnes '# my-server' eilutes, pridedam dabartines
(
    crontab -l 2>/dev/null | grep -v '# my-server' || true
    printf '%s\n' "${CRON_LINES[@]}"
) | crontab -

echo "Cron job'ai instaliuoti:"
echo ""
crontab -l | grep '# my-server'
echo ""
echo "Tikrink: crontab -l"
