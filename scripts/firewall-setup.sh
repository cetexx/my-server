#!/bin/bash
set -euo pipefail

# =============================================
# Firewall (UFW) setup
# =============================================

show_help() {
    echo "Naudojimas:"
    echo "  firewall setup     Pradinis firewall setup'as"
    echo "  firewall status    Dabartinis statusas"
}

firewall_setup() {
    if ! command -v ufw &>/dev/null; then
        echo "Diegiu UFW..."
        apt-get update -qq && apt-get install -y -qq ufw
    fi

    echo "=== Firewall setup ==="
    echo ""

    # Default policy
    ufw default deny incoming
    ufw default allow outgoing

    # SSH — VISADA pirmas!
    echo "Leidžiu SSH (22)..."
    ufw allow 22/tcp comment "SSH"

    # HTTP/HTTPS (Traefik)
    echo "Leidžiu HTTP/HTTPS (80, 443)..."
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # Mail portai
    echo "Leidžiu Mail portus (25, 587, 993)..."
    ufw allow 25/tcp comment "SMTP"
    ufw allow 587/tcp comment "SMTP Submission"
    ufw allow 993/tcp comment "IMAP SSL"

    # Docker Swarm (jei ateityje bus kelios nodes)
    # ufw allow 2377/tcp comment "Swarm management"
    # ufw allow 7946/tcp comment "Swarm node communication"
    # ufw allow 7946/udp comment "Swarm node communication"
    # ufw allow 4789/udp comment "Swarm overlay network"

    echo ""
    echo "SVARBU: Prieš įjungiant firewall, patikrink kad SSH veikia!"
    echo ""
    read -p "Įjungti firewall? (yes/no): " CONFIRM

    if [ "$CONFIRM" = "yes" ]; then
        ufw --force enable
        echo ""
        echo "=== Firewall įjungtas ==="
        ufw status verbose
    else
        echo "Firewall neįjungtas. Įjunk rankiniu būdu: ufw enable"
    fi
}

firewall_status() {
    if command -v ufw &>/dev/null; then
        ufw status verbose
    else
        echo "UFW neįdiegtas. Paleisk: ./server.sh firewall setup"
    fi
}

case "${1:-}" in
    setup)  firewall_setup ;;
    status) firewall_status ;;
    *)      show_help ;;
esac
