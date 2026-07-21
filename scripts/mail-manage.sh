#!/bin/bash
set -euo pipefail

# =============================================
# Multi-domain mail management (docker-mailserver v15 + Rspamd)
#
# Platform-level tool: vienas mailserver'is (mail.$MAIL_DOMAIN)
# aptarnauja kelis projektų domenus, kiekvienas su savo DKIM/MX/SPF.
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env" 2>/dev/null || true

# Mailserver FQDN = mail.$DOMAIN. Naudojam MAIL_DOMAIN (cetex.dev), NE DOMAIN
# (pickzy.app — jo paštas ant Google). Fallback dėl senų setupų.
DOMAIN=${MAIL_DOMAIN:-${DOMAIN:-example.com}}

# v15/Rspamd DKIM: flat failai rsa-2048-mail-<domain>.{private,public.dns}.txt
RSPAMD_DKIM_DIR="/opt/my-server/mailserver/config/rspamd/dkim"
DKIM_SIGNING_CONF="/opt/my-server/mailserver/config/rspamd/override.d/dkim_signing.conf"

get_mail_container() {
    docker ps -qf "name=mail_mailserver" 2>/dev/null | head -1
}

require_container() {
    local CONTAINER
    CONTAINER=$(get_mail_container)
    if [ -z "$CONTAINER" ]; then
        echo "Klaida: mail_mailserver konteineris nerastas"
        echo "Paleisk: ./deploy.sh mail"
        exit 1
    fi
    echo "$CONTAINER"
}

# Sending IP = host default egress (Docker Swarm overlay). ipify grąžina jį (176).
get_server_ip() {
    curl -s https://api.ipify.org || hostname -I | awk '{print $1}'
}

show_help() {
    cat <<EOF
Naudojimas:

  ACCOUNT MANAGEMENT
    mail add <user@domain> [password]      Sukurti email accountą (be password — prašo interaktyviai)
    mail list                              Visi email accountai
    mail remove <user@domain>              Pašalinti accountą
    mail password <user@domain>            Pakeisti slaptažodį

  ALIASES
    mail alias <from> <to>                 Pridėti alias (info@ → admin@)
    mail alias list                        Visi aliasai

  MULTI-DOMAIN
    mail add-domain <domain>               Naujas domenas: DKIM (Rspamd) + dkim_signing.conf + DNS įrašai
    mail domains                           Visi sukonfigūruoti domenai

  DKIM
    mail dkim setup <domain>               Sugeneruoti DKIM raktus domenui
    mail dkim show <domain>                Parodyti DKIM DNS įrašą
    mail dkim dns <domain>                 Pilnas DNS setup (MX + SPF + DKIM + DMARC)

  TESTING
    mail test <from@domain> <to@email>     Siųsti test email (per autentikuotą 587)

Pavyzdžiai:
  ./server.sh mail add-domain natars.mobi
  ./server.sh mail add info@natars.mobi Slaptazodis123
  ./server.sh mail test no-reply@natars.mobi test@gmail.com
EOF
}

# -----------------------------------------------------------------
# DKIM signing config (Rspamd) — perrašom su VISAIS domenais, kurie turi raktus.
# `setup config dkim` sugeneruoja raktą, bet NE visada įrašo į dkim_signing.conf
# domain{} bloką — todėl regeneruojam patys (idempotent).
# -----------------------------------------------------------------
regen_dkim_signing_conf() {
    {
        cat <<'HDR'
# Valdo mail-manage.sh (v15/Rspamd). Regeneruojama per `mail add-domain`.
# https://rspamd.com/doc/modules/dkim_signing.html
enabled = true;

sign_authenticated = true;   # app'ai siunčia per autentikuotą 587
sign_local = true;           # lokalus sendmail (alertai ir pan.) irgi pasirašomi
try_fallback = false;

use_domain = "header";
use_redis = false;
use_esld = true;
allow_username_mismatch = true;

check_pubkey = false;        # true → praleistų signing kai DNS patikra nepavyksta

domain {
HDR
        for keyfile in "$RSPAMD_DKIM_DIR"/rsa-2048-mail-*.private.txt; do
            [ -f "$keyfile" ] || continue
            local d
            d=$(basename "$keyfile" | sed 's/^rsa-2048-mail-//;s/\.private\.txt$//')
            printf '    %s {\n        path = "/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-%s.private.txt";\n        selector = "mail";\n    }\n' "$d" "$d"
        done
        echo "}"
    } > "$DKIM_SIGNING_CONF"
}

# -----------------------------------------------------------------
# ACCOUNT MANAGEMENT
# -----------------------------------------------------------------

mail_add() {
    local EMAIL=${1:-}
    local PW=${2:-}
    if [ -z "$EMAIL" ]; then
        echo "Naudojimas: ./server.sh mail add <user@domain> [password]"
        exit 1
    fi
    if ! echo "$EMAIL" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        echo "Klaida: netinkamas email formatas"
        exit 1
    fi

    local ACCT_DOMAIN="${EMAIL#*@}"
    local CONTAINER
    CONTAINER=$(require_container)

    # Įspėk jei domenas neturi DKIM (nepasirašys) — bet neblokuok.
    if [ ! -f "$RSPAMD_DKIM_DIR/rsa-2048-mail-$ACCT_DOMAIN.private.txt" ]; then
        echo "⚠ Domenas $ACCT_DOMAIN neturi DKIM. Rekomenduojama pirma: ./server.sh mail add-domain $ACCT_DOMAIN"
    fi

    echo "Kuriu accountą: $EMAIL"
    if [ -n "$PW" ]; then
        docker exec "$CONTAINER" setup email add "$EMAIL" "$PW"
    else
        echo "Įvesk slaptažodį:"
        docker exec -it "$CONTAINER" setup email add "$EMAIL"
    fi

    echo ""
    echo "=== Accountas sukurtas ==="
    echo "Email:    $EMAIL"
    echo "IMAP:     mail.${DOMAIN}:993 (SSL)"
    echo "SMTP:     mail.${DOMAIN}:587 (STARTTLS, AUTH)"
    echo "Webmail:  https://mail.${DOMAIN}"
    echo ""
    echo "Laravel .env (transakciniams laiškams):"
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
        echo "Atšaukta"; exit 0
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
# MULTI-DOMAIN
# -----------------------------------------------------------------

mail_add_domain() {
    local NEW_DOMAIN=${1:-}
    if [ -z "$NEW_DOMAIN" ]; then
        echo "Naudojimas: ./server.sh mail add-domain <domain>"
        exit 1
    fi
    if ! echo "$NEW_DOMAIN" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        echo "Klaida: netinkamas domain formatas"
        exit 1
    fi
    local CONTAINER
    CONTAINER=$(require_container)

    echo "=== Konfigūruoju domeną: $NEW_DOMAIN ==="
    if [ -f "$RSPAMD_DKIM_DIR/rsa-2048-mail-$NEW_DOMAIN.private.txt" ]; then
        echo "✓ DKIM raktai jau yra"
    else
        echo "→ Generuoju DKIM (RSA 2048, selector mail, Rspamd)..."
        docker exec "$CONTAINER" setup config dkim keysize 2048 domain "$NEW_DOMAIN" 2>&1 | grep -iE "success|created|error" | head -1 || true
    fi

    echo "→ Užtikrinu, kad domenas yra dkim_signing.conf..."
    regen_dkim_signing_conf
    docker exec "$CONTAINER" supervisorctl restart rspamd >/dev/null 2>&1 && echo "✓ rspamd perkrautas"
    echo ""
    mail_dkim_dns "$NEW_DOMAIN"
}

mail_domains() {
    echo "=== Sukonfigūruoti domenai (turi DKIM raktą) ==="
    local found=0
    for keyfile in "$RSPAMD_DKIM_DIR"/rsa-2048-mail-*.private.txt; do
        [ -f "$keyfile" ] || continue
        found=1
        basename "$keyfile" | sed 's/^rsa-2048-mail-/  • /;s/\.private\.txt$//'
    done
    [ "$found" = "0" ] && echo "  (nėra) — pridėk: ./server.sh mail add-domain <domain>"
}

# -----------------------------------------------------------------
# DKIM
# -----------------------------------------------------------------

mail_dkim() {
    local ACTION=${1:-}
    local ARG=${2:-}
    case "$ACTION" in
        setup)
            local CONTAINER; CONTAINER=$(require_container)
            [ -z "$ARG" ] && { echo "Naudojimas: mail dkim setup <domain>"; exit 1; }
            docker exec "$CONTAINER" setup config dkim keysize 2048 domain "$ARG" 2>&1 | grep -iE "success|created|error" | head -1 || true
            regen_dkim_signing_conf
            docker exec "$CONTAINER" supervisorctl restart rspamd >/dev/null 2>&1
            echo "✓ DKIM sugeneruotas + įrašytas domenui $ARG"
            ;;
        show)
            local D=${ARG:-$DOMAIN}
            local F="$RSPAMD_DKIM_DIR/rsa-2048-mail-$D.public.dns.txt"
            if [ -f "$F" ]; then
                echo "=== DKIM DNS įrašas: mail._domainkey.$D ==="
                cat "$F"
            else
                echo "DKIM raktas domenui '$D' nerastas. Paleisk: ./server.sh mail add-domain $D"
            fi
            ;;
        dns)
            [ -z "$ARG" ] && { echo "Naudojimas: mail dkim dns <domain>"; exit 1; }
            mail_dkim_dns "$ARG"
            ;;
        *)
            echo "Naudojimas: mail dkim setup|show|dns <domain>"
            ;;
    esac
}

# Pilnas DNS įrašų rinkinys domenui (MX + SPF + DKIM + DMARC)
mail_dkim_dns() {
    local D=${1:-$DOMAIN}
    local DKIM_FILE="$RSPAMD_DKIM_DIR/rsa-2048-mail-$D.public.dns.txt"
    local IP
    IP=$(get_server_ip)

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ DNS RECORDS: $D  (visi DNS-only / pilkas debesėlis)"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "─── MX ───"
    echo "  Type: MX   Name: @   Value: mail.${DOMAIN}   Priority: 10"
    echo ""
    echo "─── SPF ───"
    echo "  Type: TXT  Name: @   Value: \"v=spf1 ip4:${IP} ~all\""
    echo ""
    echo "─── DKIM ───"
    if [ -f "$DKIM_FILE" ]; then
        echo "  Type: TXT  Name: mail._domainkey   Value:"
        echo "  $(cat "$DKIM_FILE")"
    else
        echo "  ⚠ DKIM nesugeneruotas. Paleisk: ./server.sh mail add-domain $D"
    fi
    echo ""
    echo "─── DMARC (warmup: p=none; vėliau griežtink į quarantine) ───"
    echo "  Type: TXT  Name: _dmarc   Value: \"v=DMARC1; p=none; rua=mailto:postmaster@$D\""
    echo ""
    echo "─── PTR (VPS provideris) ───"
    echo "  IP ${IP} → mail.${DOMAIN}  (serveriai.lt savitarna → IP → PTR)"
    echo ""
    echo "Testas (kai propaguos): ./server.sh mail test no-reply@$D test-XXX@mail-tester.com"
    echo "Tikslas: ≥8/10 (https://www.mail-tester.com/)"
}

# -----------------------------------------------------------------
# TESTING
# -----------------------------------------------------------------

mail_test() {
    local FROM=${1:-}
    local TO=${2:-}
    if [ -z "$FROM" ] || [ -z "$TO" ]; then
        echo "Naudojimas: ./server.sh mail test <from@domain> <to@email>"
        echo "  Pvz.: ./server.sh mail test no-reply@natars.mobi test-XXX@mail-tester.com"
        exit 1
    fi
    local CONTAINER
    CONTAINER=$(require_container)
    echo "Siunčiu test email (lokalus injekas): $FROM → $TO"
    docker exec "$CONTAINER" bash -c "printf 'Subject: Test from %s\nFrom: %s\nTo: %s\n\nDeliverability test. %s\n' '${DOMAIN}' '$FROM' '$TO' \"\$(date -u)\" | sendmail -f $FROM $TO"
    echo "✓ Išsiųsta. Patikrink: Gmail → Show original → SPF/DKIM/DMARC = PASS."
    echo "  (App'ai turi siųsti per autentikuotą 587, kad DKIM pasirašytų.)"
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
