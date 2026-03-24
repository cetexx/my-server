#!/bin/bash
set -euo pipefail

# =============================================
# Firewall setup (firewalld / ufw)
# Auto-detect: Rocky/RHEL → firewalld, Debian/Ubuntu → ufw
# =============================================

show_help() {
    echo "Naudojimas:"
    echo "  firewall setup     Pradinis firewall setup'as"
    echo "  firewall status    Dabartinis statusas"
}

PORTS_TCP=(22 80 443 25 587 993)
PORTS_DESC=("SSH" "HTTP" "HTTPS" "SMTP" "SMTP Submission" "IMAP SSL")

# =============================================
# firewalld (Rocky Linux, RHEL, CentOS)
# =============================================
firewalld_setup() {
    if ! command -v firewall-cmd &>/dev/null; then
        echo "Diegiu firewalld..."
        dnf install -y -q firewalld
    fi

    systemctl enable --now firewalld 2>/dev/null || true

    echo "=== Firewall setup (firewalld) ==="
    echo ""

    # Default zone — drop (atmetam viską)
    firewall-cmd --set-default-zone=drop --permanent 2>/dev/null || true

    # Leidžiam portus
    for i in "${!PORTS_TCP[@]}"; do
        echo "Leidžiu ${PORTS_DESC[$i]} (${PORTS_TCP[$i]}/tcp)..."
        firewall-cmd --permanent --add-port="${PORTS_TCP[$i]}/tcp" 2>/dev/null || true
    done

    # Docker Swarm (jei ateityje bus kelios nodes)
    # firewall-cmd --permanent --add-port=2377/tcp
    # firewall-cmd --permanent --add-port=7946/tcp
    # firewall-cmd --permanent --add-port=7946/udp
    # firewall-cmd --permanent --add-port=4789/udp

    # Docker interface — leidžiam vidinį traffic
    firewall-cmd --permanent --zone=trusted --add-interface=docker0 2>/dev/null || true
    firewall-cmd --permanent --zone=trusted --add-interface=docker_gwbridge 2>/dev/null || true

    # Masquerade — reikia Docker networking
    firewall-cmd --permanent --add-masquerade 2>/dev/null || true

    firewall-cmd --reload
    echo ""
    echo "=== Firewall įjungtas ==="
    firewall-cmd --list-all
}

firewalld_status() {
    firewall-cmd --list-all
}

# =============================================
# ufw (Debian, Ubuntu)
# =============================================
ufw_setup() {
    if ! command -v ufw &>/dev/null; then
        echo "Diegiu UFW..."
        apt-get update -qq && apt-get install -y -qq ufw
    fi

    echo "=== Firewall setup (ufw) ==="
    echo ""

    ufw default deny incoming
    ufw default allow outgoing

    for i in "${!PORTS_TCP[@]}"; do
        echo "Leidžiu ${PORTS_DESC[$i]} (${PORTS_TCP[$i]}/tcp)..."
        ufw allow "${PORTS_TCP[$i]}/tcp" comment "${PORTS_DESC[$i]}"
    done

    # Docker Swarm (jei ateityje bus kelios nodes)
    # ufw allow 2377/tcp comment "Swarm management"
    # ufw allow 7946/tcp comment "Swarm node communication"
    # ufw allow 7946/udp comment "Swarm node communication"
    # ufw allow 4789/udp comment "Swarm overlay network"

    echo ""
    echo "SVARBU: Prieš įjungiant firewall, patikrink kad SSH veikia!"
    echo ""
    read -t 30 -p "Įjungti firewall? (yes/no): " CONFIRM || CONFIRM="no"

    if [ "$CONFIRM" = "yes" ]; then
        ufw --force enable
        echo ""
        echo "=== Firewall įjungtas ==="
        ufw status verbose
    else
        echo "Firewall neįjungtas. Įjunk rankiniu būdu: ufw enable"
    fi
}

ufw_status() {
    ufw status verbose
}

# =============================================
# Auto-detect ir dispatch
# =============================================
detect_firewall() {
    if command -v firewall-cmd &>/dev/null || [ -f /etc/redhat-release ]; then
        echo "firewalld"
    elif command -v ufw &>/dev/null || command -v apt-get &>/dev/null; then
        echo "ufw"
    else
        echo "unknown"
    fi
}

firewall_setup() {
    local FW
    FW=$(detect_firewall)
    case "$FW" in
        firewalld) firewalld_setup ;;
        ufw)       ufw_setup ;;
        *)
            echo "Klaida: neatpažinta OS. Palaikomi: Rocky/RHEL (firewalld), Debian/Ubuntu (ufw)"
            exit 1
            ;;
    esac
}

firewall_status() {
    local FW
    FW=$(detect_firewall)
    case "$FW" in
        firewalld) firewalld_status ;;
        ufw)       ufw_status ;;
        *)
            echo "Firewall nerastas"
            exit 1
            ;;
    esac
}

case "${1:-}" in
    setup)  firewall_setup ;;
    status) firewall_status ;;
    *)      show_help ;;
esac
