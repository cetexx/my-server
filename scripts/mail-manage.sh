#!/bin/bash
set -euo pipefail

# =============================================
# Multi-domain mail management (docker-mailserver)
#
# Platform-level tool: single my-server hosts mail for
# multiple projects (e.g. serveriai.lt, pickzy.app, ...).
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env" 2>/dev/null || true

DOMAIN=${DOMAIN:-example.com}
DKIM_KEYS_DIR="/opt/my-server/mailserver/config/opendkim/keys"

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

get_server_ip() {
    curl -s https://api.ipify.org || hostname -I | awk '{print $1}'
}

show_help() {
    cat <<EOF
Naudojimas:

  ACCOUNT MANAGEMENT
    mail add <user@domain>                Sukurti email accountą
    mail list                              Visi email accountai
    mail remove <user@domain>              Pašalinti accountą
    mail password <user@domain>            Pakeisti slaptažodį

  ALIASES
    mail alias <from> <to>                 Pridėti alias (info@ → admin@)
    mail alias list                        Visi aliasai

  MULTI-DOMAIN SUPPORT
    mail add-domain <domain>               Sukonfigūruoti naują domain'ą
                                           (generuoja DKIM + išveda DNS records)
    mail domains                           Visi sukonfigūruoti domainai

  DKIM
    mail dkim setup [domain]               Sukurti DKIM raktus (default: visi known)
    mail dkim show [domain]                Parodyti DKIM DNS įrašą
    mail dkim dns <domain>                 Pilnas DNS setup (SPF + DKIM + DMARC)

  TESTING
    mail test <from@domain> <to@gmail>     Siųsti test email + patikrinti DKIM

Pavyzdžiai:
  ./server.sh mail add-domain pickzy.app
  ./server.sh mail add labas@pickzy.app
  ./server.sh mail alias info@pickzy.app labas@pickzy.app
  ./server.sh mail test labas@pickzy.app test@gmail.com
  ./server.sh mail dkim dns pickzy.app
EOF
}

# -----------------------------------------------------------------
# ACCOUNT MANAGEMENT
# -----------------------------------------------------------------

mail_add() {
    local EMAIL=${1:-}
    if [ -z "$EMAIL" ]; then
        echo "Naudojimas: ./server.sh mail add <user@domain>"
        exit 1
    fi

    if ! echo "$EMAIL" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        echo "Klaida: netinkamas email formatas"
        exit 1
    fi

    local MAIL_DOMAIN="${EMAIL#*@}"
    local CONTAINER
    CONTAINER=$(require_container)

    # Auto-setup domain if missing DKIM
    if [ ! -d "$DKIM_KEYS_DIR/$MAIL_DOMAIN" ]; then
        echo "⚠ Domain $MAIL_DOMAIN neturi DKIM raktų — pirma setup'inti."
        echo ""
        read -p "Paleisti 'mail add-domain $MAIL_DOMAIN' dabar? (yes/no): " CONFIRM
        if [ "$CONFIRM" = "yes" ]; then
            mail_add_domain "$MAIL_DOMAIN"
        else
            echo "Be DKIM, siunčiami emails'ai bus markinami kaip spam. Rekomenduojama."
        fi
    fi

    echo "Kuriu accountą: $EMAIL"
    echo "Įvesk slaptažodį:"
    docker exec -it "$CONTAINER" setup email add "$EMAIL"

    echo ""
    echo "=== Accountas sukurtas ==="
    echo "Email:    $EMAIL"
    echo "IMAP:     mail.${DOMAIN}:993 (SSL)"
    echo "SMTP:     mail.${DOMAIN}:587 (STARTTLS)"
    echo "Webmail:  https://mail.${DOMAIN}"
    echo ""
    echo "Laravel .env (jei naudoji šį accountą OTP siuntimui):"
    echo "  MAIL_MAILER=smtp"
    echo "  MAIL_HOST=mail.${DOMAIN}"
    echo "  MAIL_PORT=587"
    echo "  MAIL_ENCRYPTION=tls"
    echo "  MAIL_USERNAME=$EMAIL"
    echo "  MAIL_FROM_ADDRESS=$EMAIL"
}

mail_list() {
    local CONTAINER
    CONTAINER=$(require_container)
    echo "=== Email accountai ==="
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

# -----------------------------------------------------------------
# MULTI-DOMAIN SUPPORT
# -----------------------------------------------------------------

mail_add_domain() {
    local NEW_DOMAIN=${1:-}
    if [ -z "$NEW_DOMAIN" ]; then
        echo "Naudojimas: ./server.sh mail add-domain <domain>"
        echo "Pvz: ./server.sh mail add-domain pickzy.app"
        exit 1
    fi

    if ! echo "$NEW_DOMAIN" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        echo "Klaida: netinkamas domain formatas"
        exit 1
    fi

    local CONTAINER
    CONTAINER=$(require_container)

    echo "=== Konfigūruoju domain: $NEW_DOMAIN ==="
    echo ""

    # Generate DKIM for this domain (selector: mail)
    if [ -d "$DKIM_KEYS_DIR/$NEW_DOMAIN" ]; then
        echo "✓ DKIM raktai jau sugeneruoti domain'ui $NEW_DOMAIN"
    else
        echo "→ Generuoju DKIM raktus (RSA 2048, selector: mail)..."
        docker exec "$CONTAINER" setup config dkim keysize=2048 selector=mail domain="$NEW_DOMAIN"
        echo "✓ DKIM raktai sugeneruoti"
    fi
    echo ""

    mail_dkim_dns "$NEW_DOMAIN"
}

mail_domains() {
    echo "=== Sukonfigūruoti domainai ==="
    echo ""

    if [ ! -d "$DKIM_KEYS_DIR" ]; then
        echo "Nėra sukonfigūruotų domainų."
        echo "Pridėk: ./server.sh mail add-domain <domain>"
        return
    fi

    for dir in "$DKIM_KEYS_DIR"/*/; do
        if [ -d "$dir" ]; then
            local d
            d=$(basename "$dir")
            echo "  • $d"
        fi
    done
}

# -----------------------------------------------------------------
# DKIM
# -----------------------------------------------------------------

mail_dkim() {
    local ACTION=${1:-}
    local ARG=${2:-}

    case "$ACTION" in
        setup)
            local CONTAINER
            CONTAINER=$(require_container)
            if [ -z "$ARG" ]; then
                echo "Generuoju DKIM raktus (visi known domainai)..."
                docker exec "$CONTAINER" setup config dkim keysize=2048 selector=mail
            else
                echo "Generuoju DKIM raktus domain'ui: $ARG"
                docker exec "$CONTAINER" setup config dkim keysize=2048 selector=mail domain="$ARG"
            fi
            echo "✓ DKIM raktai sugeneruoti"
            ;;
        show)
            local DOMAIN_ARG=${ARG:-$DOMAIN}
            local DKIM_FILE="$DKIM_KEYS_DIR/$DOMAIN_ARG/mail.txt"
            if [ -f "$DKIM_FILE" ]; then
                echo "=== DKIM DNS įrašas: $DOMAIN_ARG ==="
                echo ""
                cat "$DKIM_FILE"
            else
                echo "DKIM raktas domain'ui '$DOMAIN_ARG' nerastas."
                echo "Paleisk: ./server.sh mail add-domain $DOMAIN_ARG"
            fi
            ;;
        dns)
            if [ -z "$ARG" ]; then
                echo "Naudojimas: ./server.sh mail dkim dns <domain>"
                exit 1
            fi
            mail_dkim_dns "$ARG"
            ;;
        *)
            echo "Naudojimas:"
            echo "  ./server.sh mail dkim setup [domain]"
            echo "  ./server.sh mail dkim show [domain]"
            echo "  ./server.sh mail dkim dns <domain>"
            ;;
    esac
}

# Full DNS record set for a domain (SPF + DKIM + DMARC + MX)
mail_dkim_dns() {
    local TARGET_DOMAIN=${1:-$DOMAIN}
    local DKIM_FILE="$DKIM_KEYS_DIR/$TARGET_DOMAIN/mail.txt"
    local SERVER_IP
    SERVER_IP=$(get_server_ip)

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ DNS RECORDS $TARGET_DOMAIN"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo ""
    echo "Pridėk šiuos DNS įrašus (Cloudflare / kur hostini $TARGET_DOMAIN):"
    echo ""
    echo "─── 1. MX record (jei dar nėra) ───"
    echo "Type:   MX"
    echo "Name:   @  (arba $TARGET_DOMAIN)"
    echo "Value:  mail.${DOMAIN}"
    echo "Priority: 10"
    echo "Proxy:  DNS only (OFF)"
    echo ""
    echo "─── 2. SPF ───"
    echo "Type:   TXT"
    echo "Name:   @  (arba $TARGET_DOMAIN)"
    echo "Value:  \"v=spf1 mx a:mail.${DOMAIN} -all\""
    echo "Proxy:  DNS only (OFF)"
    echo ""
    echo "─── 3. DKIM ───"
    if [ -f "$DKIM_FILE" ]; then
        echo "Type:   TXT"
        echo "Name:   mail._domainkey.$TARGET_DOMAIN"
        echo "Value:  $(awk -F '"' 'NR>1 {printf "%s", $2}' "$DKIM_FILE" | sed 's/^/"/;s/$/"/')"
        echo "Proxy:  DNS only (OFF)"
    else
        echo "⚠ DKIM raktas nesugeneruotas. Paleisk: ./server.sh mail add-domain $TARGET_DOMAIN"
    fi
    echo ""
    echo "─── 4. DMARC ───"
    echo "Type:   TXT"
    echo "Name:   _dmarc.$TARGET_DOMAIN"
    echo "Value:  \"v=DMARC1; p=quarantine; rua=mailto:dmarc@$TARGET_DOMAIN; pct=100; fo=1\""
    echo "Proxy:  DNS only (OFF)"
    echo ""
    echo "─── 5. (REKOMENDUOJAMA) Reverse DNS / PTR ───"
    echo "Server IP: $SERVER_IP"
    echo "Susisiek su VPS provider'iu ir paprašyk PTR record:"
    echo "  $SERVER_IP → mail.${DOMAIN}"
    echo "Be PTR, Gmail/iCloud dažnai markuos emails kaip spam."
    echo ""
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Kai DNS propaguos (~5-15 min), test'ink:"
    echo "  ./server.sh mail test <user@$TARGET_DOMAIN> test-abc123@mail-tester.com"
    echo "Tikslas: 10/10 score (https://www.mail-tester.com/)"
}

# -----------------------------------------------------------------
# TESTING
# -----------------------------------------------------------------

mail_test() {
    local FROM=${1:-}
    local TO=${2:-}

    if [ -z "$FROM" ] || [ -z "$TO" ]; then
        echo "Naudojimas: ./server.sh mail test <from@domain> <to@email>"
        echo ""
        echo "Pavyzdžiai:"
        echo "  # Gmail test:"
        echo "  ./server.sh mail test labas@pickzy.app tavo-email@gmail.com"
        echo ""
        echo "  # Full deliverability report (rekomenduojama):"
        echo "  # 1) Eik į https://www.mail-tester.com/"
        echo "  # 2) Nukopijuok jų unique email (test-XXX@mail-tester.com)"
        echo "  # 3) Paleisk: ./server.sh mail test labas@pickzy.app test-XXX@mail-tester.com"
        echo "  # 4) Spausk 'Then check your score' tame pačiame puslapyje"
        exit 1
    fi

    local CONTAINER
    CONTAINER=$(require_container)

    echo "Siunčiu test email: $FROM → $TO"
    echo ""

    # Use swaks-style sendmail inside container
    docker exec "$CONTAINER" bash -c "echo -e 'Subject: Test from Pickzy mail server\nFrom: $FROM\nTo: $TO\n\nThis is a deliverability test from ${DOMAIN}. Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ).' | sendmail -f $FROM $TO"

    echo "✓ Email išsiųstas"
    echo ""
    echo "Ką patikrinti:"
    echo "  1. Ar gauni email'ą inbox'e (ne spam folder)?"
    echo "  2. Gmail → Show original → patikrinti:"
    echo "     - SPF: PASS"
    echo "     - DKIM: PASS"
    echo "     - DMARC: PASS"
    echo "  3. Jei mail-tester.com → atsidaryk puslapį, gaus score/10"
    echo ""
    echo "Jei score <8/10 → deliverability problemos, rekomenduojama pataisyti prieš"
    echo "naudojant šį serverį OTP emailams."
}

# -----------------------------------------------------------------
# DISPATCHER
# -----------------------------------------------------------------

case "${1:-}" in
    add)          mail_add "${@:2}" ;;
    list)         mail_list ;;
    remove)       mail_remove "${@:2}" ;;
    password)     mail_password "${@:2}" ;;
    alias)        mail_alias "${@:2}" ;;
    add-domain)   mail_add_domain "${@:2}" ;;
    domains)      mail_domains ;;
    dkim)         mail_dkim "${@:2}" ;;
    test)         mail_test "${@:2}" ;;
    *)            show_help ;;
esac
