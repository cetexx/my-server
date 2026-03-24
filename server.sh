#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

show_help() {
    cat <<'EOF'
╔══════════════════════════════════════════╗
║         VPS Server Management            ║
╚══════════════════════════════════════════╝

Naudojimas: ./server.sh <komanda> [argumentai]

SETUP & DEPLOY:
  setup                       Pradinis serverio setup'as
  deploy <stack|all>          Deploy'ink stack'ą (core, monitoring, mail, projects/xxx)

STATUSAS:
  status                      Serverio ir servisų statusas
  logs <servisas>             Servisų logai (pvz: core_traefik)

DUOMBAZĖS:
  db create <name> [limit]    Sukurk naują izoliuotą DB
  db list                     Visos DB, dydžiai, prisijungimai
  db delete <name>            Ištrink DB (su patvirtinimu)
  db backup [name]            Backup'ink DB (visas arba konkrečią)

SSH VARTOTOJAI:
  ssh add <user> [--docker]   Pridėk SSH vartotoją (su key iš stdin)
  ssh list                    Visi SSH vartotojai
  ssh remove <user>           Pašalink SSH vartotoją
  ssh harden                  Užkietink SSH konfigą

BACKUP:
  backup db [name]            Backup'ink duombazes
  backup configs              Backup'ink konfigūracijas
  backup all                  Pilnas backup'as

SAUGUMAS:
  whitelist list              Parodyti admin IP whitelist'ą
  whitelist myip              Pridėti dabartinį IP automatiškai
  whitelist add <ip>          Pridėti IP
  whitelist remove <ip>       Pašalinti IP
  firewall setup              Pradinis firewall'o setup'as
  firewall status             Firewall'o statusas
  cron setup                  Instaliuok cron job'us (cleanup, cert check)
  certs check                 Tikrink SSL sertifikatų galiojimą

EOF
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Reikia root teisių: sudo ./server.sh $*"
        exit 1
    fi
}

case "${1:-}" in
    setup)
        require_root
        "$SCRIPT_DIR/setup.sh"
        ;;
    deploy)
        "$SCRIPT_DIR/deploy.sh" "${@:2}"
        ;;
    status)
        "$SCRIPT_DIR/scripts/status.sh"
        ;;
    logs)
        SERVICE=${2:-}
        if [ -z "$SERVICE" ]; then
            echo "Naudojimas: ./server.sh logs <servisas>"
            echo "Pvz: ./server.sh logs core_traefik"
            echo ""
            echo "Aktyvūs servisai:"
            docker service ls --format "  {{.Name}}"
            exit 1
        fi
        docker service logs -f --tail 100 "$SERVICE"
        ;;
    db)
        case "${2:-}" in
            create) "$SCRIPT_DIR/scripts/db-create.sh" "${@:3}" ;;
            list)   "$SCRIPT_DIR/scripts/db-list.sh" ;;
            delete) "$SCRIPT_DIR/scripts/db-delete.sh" "${@:3}" ;;
            backup) "$SCRIPT_DIR/scripts/backup.sh" db "${@:3}" ;;
            *)
                echo "Naudojimas: ./server.sh db <create|list|delete|backup>"
                exit 1
                ;;
        esac
        ;;
    ssh)
        require_root
        "$SCRIPT_DIR/scripts/ssh-manage.sh" "${@:2}"
        ;;
    backup)
        "$SCRIPT_DIR/scripts/backup.sh" "${@:2}"
        ;;
    whitelist)
        "$SCRIPT_DIR/scripts/whitelist.sh" "${@:2}"
        ;;
    firewall)
        require_root
        "$SCRIPT_DIR/scripts/firewall-setup.sh" "${@:2}"
        ;;
    cron)
        require_root
        "$SCRIPT_DIR/scripts/cron-setup.sh"
        ;;
    certs)
        "$SCRIPT_DIR/scripts/check-certs.sh"
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo "Nežinoma komanda: $1"
        echo "Naudok: ./server.sh help"
        exit 1
        ;;
esac
