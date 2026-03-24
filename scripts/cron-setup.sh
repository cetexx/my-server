#!/bin/bash
set -euo pipefail

# =============================================
# Cron job'ų setup'as
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Cron setup ==="
echo ""

# Docker cleanup — kiekvieną savaitę (sekmadienis 4:00)
CRON_CLEANUP="0 4 * * 0 docker system prune -af --volumes --filter 'until=168h' >> /var/log/docker-cleanup.log 2>&1"

# Cert expiry check — kasdien 6:00
CRON_CERT="0 6 * * * ${REPO_DIR}/scripts/check-certs.sh >> /var/log/cert-check.log 2>&1"

# Instaliuojam cron job'us
(
    # Paliekam egzistuojančius cron'us (be mūsų komentarų)
    crontab -l 2>/dev/null | grep -v '# my-server:' || true
    echo "# my-server: Docker cleanup (sekmadieniais 4:00)"
    echo "$CRON_CLEANUP"
    echo "# my-server: Cert expiry check (kasdien 6:00)"
    echo "$CRON_CERT"
) | crontab -

echo "Cron job'ai instaliuoti:"
echo ""
crontab -l | grep -A1 '# my-server:'
echo ""
echo "Tikrink: crontab -l"
