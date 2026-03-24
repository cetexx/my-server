#!/bin/bash
set -euo pipefail

# =============================================
# Mail accountų valdymas (docker-mailserver)
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env" 2>/dev/null || true

DOMAIN=${DOMAIN:-example.com}

get_mail_container() {
    docker ps -qf "name=mail_mailserver" 2>/dev/null | head -1
}

require_container() {
    local CONTAINER
    CONTAINER=$(get_mail_container)
    if [ -z "$CONTAINER" ]; then
        echo "Klaida: mail_mailserver konteineris nerastas"
        echo "Paleisk: ./server.sh deploy mail"
        exit 1
    fi
    echo "$CONTAINER"
}

show_help() {
    echo "Naudojimas:"
    echo "  mail add <user@domain>          Sukurk email accountą"
    echo "  mail list                        Visi email accountai"
    echo "  mail remove <user@domain>        Pašalink accountą"
    echo "  mail password <user@domain>      Pakeisk slaptažodį"
    echo "  mail alias <from> <to>           Pridėk alias (pvz: info@domain → user@domain)"
    echo "  mail alias list                  Visi aliasai"
    echo "  mail dkim setup                  Sukurk DKIM raktus"
    echo "  mail dkim show                   Parodyti DKIM DNS įrašą"
    echo ""
    echo "Pavyzdžiai:"
    echo "  ./server.sh mail add admin@${DOMAIN}"
    echo "  ./server.sh mail alias info@${DOMAIN} admin@${DOMAIN}"
    echo "  ./server.sh mail dkim setup"
}

mail_add() {
    local EMAIL=${1:-}
    if [ -z "$EMAIL" ]; then
        echo "Naudojimas: ./server.sh mail add <user@domain>"
        echo "Pvz: ./server.sh mail add admin@${DOMAIN}"
        exit 1
    fi

    # Validacija
    if ! echo "$EMAIL" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        echo "Klaida: netinkamas email formatas"
        exit 1
    fi

    local CONTAINER
    CONTAINER=$(require_container)

    echo "Kuriu accountą: $EMAIL"
    echo "Įvesk slaptažodį:"
    docker exec -it "$CONTAINER" setup email add "$EMAIL"

    echo ""
    echo "=== Accountas sukurtas ==="
    echo "Email:  $EMAIL"
    echo "IMAP:   mail.${DOMAIN}:993 (SSL)"
    echo "SMTP:   mail.${DOMAIN}:587 (STARTTLS)"
    echo "Webmail: https://mail.${DOMAIN}"
}

mail_list() {
    local CONTAINER
    CONTAINER=$(require_container)

    echo "=== Email accountai ==="
    echo ""
    docker exec "$CONTAINER" setup email list
}

mail_remove() {
    local EMAIL=${1:-}
    if [ -z "$EMAIL" ]; then
        echo "Naudojimas: ./server.sh mail remove <user@domain>"
        exit 1
    fi

    local CONTAINER
    CONTAINER=$(require_container)

    read -p "Tikrai pašalinti $EMAIL? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Atšaukta"
        exit 0
    fi

    docker exec "$CONTAINER" setup email del "$EMAIL"
    echo "Accountas $EMAIL pašalintas"
}

mail_password() {
    local EMAIL=${1:-}
    if [ -z "$EMAIL" ]; then
        echo "Naudojimas: ./server.sh mail password <user@domain>"
        exit 1
    fi

    local CONTAINER
    CONTAINER=$(require_container)

    echo "Keičiu slaptažodį: $EMAIL"
    docker exec -it "$CONTAINER" setup email update "$EMAIL"
    echo "Slaptažodis pakeistas"
}

mail_alias() {
    local FROM=${1:-}
    local TO=${2:-}

    local CONTAINER
    CONTAINER=$(require_container)

    if [ "$FROM" = "list" ] || [ -z "$FROM" ]; then
        echo "=== Email aliasai ==="
        echo ""
        docker exec "$CONTAINER" setup alias list
        return
    fi

    if [ -z "$TO" ]; then
        echo "Naudojimas: ./server.sh mail alias <from@domain> <to@domain>"
        exit 1
    fi

    docker exec "$CONTAINER" setup alias add "$FROM" "$TO"
    echo "Alias pridėtas: $FROM → $TO"
}

mail_dkim() {
    local ACTION=${1:-}
    local CONTAINER
    CONTAINER=$(require_container)

    case "$ACTION" in
        setup)
            echo "Generuoju DKIM raktus..."
            docker exec "$CONTAINER" setup config dkim
            echo ""
            echo "DKIM raktai sugeneruoti!"
            echo "Parodyti DNS įrašą: ./server.sh mail dkim show"
            ;;
        show)
            echo "=== DKIM DNS įrašas ==="
            echo ""
            echo "Pridėk šį TXT įrašą savo DNS:"
            echo ""
            local DKIM_DIR="/opt/my-server/mailserver/config/opendkim/keys"
            if [ -d "$DKIM_DIR" ]; then
                find "$DKIM_DIR" -name "mail.txt" -exec cat {} \;
            else
                echo "DKIM raktai nesugeneruoti. Paleisk: ./server.sh mail dkim setup"
            fi
            ;;
        *)
            echo "Naudojimas: ./server.sh mail dkim <setup|show>"
            ;;
    esac
}

case "${1:-}" in
    add)      mail_add "${@:2}" ;;
    list)     mail_list ;;
    remove)   mail_remove "${@:2}" ;;
    password) mail_password "${@:2}" ;;
    alias)    mail_alias "${@:2}" ;;
    dkim)     mail_dkim "${@:2}" ;;
    *)        show_help ;;
esac
