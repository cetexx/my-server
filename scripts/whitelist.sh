#!/bin/bash
set -euo pipefail

# =============================================
# Admin tools IP whitelist valdymas
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

show_help() {
    echo "Naudojimas:"
    echo "  whitelist list          Parodyti dabartinį whitelist'ą"
    echo "  whitelist myip          Pridėti dabartinį IP automatiškai"
    echo "  whitelist add <ip>      Pridėti IP (pvz: 1.2.3.4)"
    echo "  whitelist remove <ip>   Pašalinti IP"
    echo "  whitelist set <ips>     Pakeisti visą sąrašą (kableliu atskirti)"
    echo ""
    echo "Po pakeitimų redeploy'ink: ./server.sh deploy core && ./server.sh deploy monitoring"
}

get_current_ips() {
    grep '^ADMIN_WHITELIST_IPS=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "127.0.0.1/32"
}

save_ips() {
    local NEW_IPS=$1
    if grep -q '^ADMIN_WHITELIST_IPS=' "$ENV_FILE" 2>/dev/null; then
        # Naudojam awk vietoj sed — saugiau su specialiais simboliais
        local TEMP_FILE
        TEMP_FILE=$(mktemp)
        awk -v ips="$NEW_IPS" '/^ADMIN_WHITELIST_IPS=/{print "ADMIN_WHITELIST_IPS=" ips; next} {print}' "$ENV_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$ENV_FILE"
    else
        echo "ADMIN_WHITELIST_IPS=${NEW_IPS}" >> "$ENV_FILE"
    fi
}

detect_my_ip() {
    local IP=""
    # Bandome kelis servisus
    for service in "ifconfig.me" "api.ipify.org" "icanhazip.com"; do
        IP=$(curl -s --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if echo "$IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "$IP"
            return
        fi
    done
    echo ""
}

normalize_ip() {
    local IP=$1
    # Jei be CIDR — pridedam /32
    if ! echo "$IP" | grep -q '/'; then
        echo "${IP}/32"
    else
        echo "$IP"
    fi
}

whitelist_list() {
    local CURRENT
    CURRENT=$(get_current_ips)

    echo "=== Admin tools IP whitelist ==="
    echo ""

    if [ "$CURRENT" = "127.0.0.1/32" ]; then
        echo "Statusas: UŽRAKINTA (tik localhost)"
        echo ""
        echo "Pridėk savo IP: ./server.sh whitelist myip"
    elif echo "$CURRENT" | grep -q "0.0.0.0/0"; then
        echo "Statusas: ATVIRA VISIEMS (nesaugu!)"
    else
        echo "Statusas: Apribota"
    fi

    echo ""
    echo "Leistini IP:"
    echo "$CURRENT" | tr ',' '\n' | while read -r ip; do
        echo "  $ip"
    done
    echo ""

    echo "Apsaugoti servisai:"
    echo "  - traefik.${DOMAIN:-example.com}"
    echo "  - portainer.${DOMAIN:-example.com}"
    echo "  - adminer.${DOMAIN:-example.com}"
    echo "  - grafana.${DOMAIN:-example.com}"
    echo "  - prometheus.${DOMAIN:-example.com}"
    echo "  - logs.${DOMAIN:-example.com}"
}

whitelist_myip() {
    echo -n "Nustatau tavo IP... "
    local MY_IP
    MY_IP=$(detect_my_ip)

    if [ -z "$MY_IP" ]; then
        echo "KLAIDA"
        echo "Nepavyko nustatyti IP. Pridėk rankiniu būdu:"
        echo "  ./server.sh whitelist add <tavo-ip>"
        exit 1
    fi

    echo "$MY_IP"
    whitelist_add "$MY_IP"
}

whitelist_add() {
    local RAW_IP=${1:-}
    if [ -z "$RAW_IP" ]; then
        echo "Naudojimas: ./server.sh whitelist add <ip>"
        exit 1
    fi

    local IP
    IP=$(normalize_ip "$RAW_IP")
    local CURRENT
    CURRENT=$(get_current_ips)

    # Tikrinam ar jau yra
    if echo ",$CURRENT," | grep -q ",$IP,"; then
        echo "IP $IP jau whitelist'e"
        return
    fi

    # Jei dabar tik localhost — pakeičiam
    if [ "$CURRENT" = "127.0.0.1/32" ]; then
        save_ips "$IP"
    else
        save_ips "${CURRENT},${IP}"
    fi

    echo "Pridėta: $IP"
    echo ""
    echo "Dabartinis whitelist:"
    get_current_ips | tr ',' '\n' | sed 's/^/  /'
    echo ""
    echo "Pritaikyk: ./server.sh deploy core && ./server.sh deploy monitoring"
}

whitelist_remove() {
    local RAW_IP=${1:-}
    if [ -z "$RAW_IP" ]; then
        echo "Naudojimas: ./server.sh whitelist remove <ip>"
        exit 1
    fi

    local IP
    IP=$(normalize_ip "$RAW_IP")
    local CURRENT
    CURRENT=$(get_current_ips)

    # Pašalinam IP iš sąrašo
    local NEW_IPS
    NEW_IPS=$(echo "$CURRENT" | tr ',' '\n' | grep -v "^${IP}$" | paste -sd ',' -)

    if [ -z "$NEW_IPS" ]; then
        NEW_IPS="127.0.0.1/32"
        echo "Paskutinis IP pašalintas — grąžinta į localhost only"
    fi

    if [ "$NEW_IPS" = "$CURRENT" ]; then
        echo "IP $IP nerastas whitelist'e"
        return
    fi

    save_ips "$NEW_IPS"
    echo "Pašalinta: $IP"
    echo ""
    echo "Dabartinis whitelist:"
    get_current_ips | tr ',' '\n' | sed 's/^/  /'
    echo ""
    echo "Pritaikyk: ./server.sh deploy core && ./server.sh deploy monitoring"
}

whitelist_set() {
    local IPS=${1:-}
    if [ -z "$IPS" ]; then
        echo "Naudojimas: ./server.sh whitelist set 1.2.3.4/32,5.6.7.8/32"
        exit 1
    fi

    save_ips "$IPS"
    echo "Whitelist pakeistas:"
    echo "$IPS" | tr ',' '\n' | sed 's/^/  /'
    echo ""
    echo "Pritaikyk: ./server.sh deploy core && ./server.sh deploy monitoring"
}

# Load .env for DOMAIN display
source "$ENV_FILE" 2>/dev/null || true

case "${1:-}" in
    list)    whitelist_list ;;
    myip)    whitelist_myip ;;
    add)     whitelist_add "${@:2}" ;;
    remove)  whitelist_remove "${@:2}" ;;
    set)     whitelist_set "${@:2}" ;;
    *)       show_help ;;
esac
