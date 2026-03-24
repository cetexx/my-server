#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_PATH=${1:-}

if [ -z "$STACK_PATH" ]; then
    echo "Usage: ./deploy.sh <stack|all>"
    echo ""
    echo "Stacks:"
    echo "  core          - Traefik, PostgreSQL, Redis, Portainer, Adminer"
    echo "  monitoring    - Prometheus, Grafana, Node Exporter, cAdvisor, Dozzle"
    echo "  mail          - docker-mailserver, Roundcube"
    echo "  projects/xxx  - projekto stack'as"
    echo "  all           - visi pagrindiniai stack'ai"
    exit 1
fi

deploy_stack() {
    local path=$1
    local name=${2:-$(basename "$path")}
    local compose="$SCRIPT_DIR/$path/docker-compose.yml"

    if [ ! -f "$compose" ]; then
        echo "Klaida: $compose nerastas"
        return 1
    fi

    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        echo "Klaida: .env failas nerastas. Paleisk: cp .env.example .env"
        return 1
    fi

    echo "Deploying stack '$name' iš $path..."
    (
        cd "$SCRIPT_DIR/$path"
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
        docker stack deploy -c docker-compose.yml "$name"
    )
    echo "Stack '$name' deployed! Tikrink: docker stack services $name"
    echo ""
}

if [ "$STACK_PATH" = "all" ]; then
    deploy_stack core
    echo "Laukiam kol core startuos..."
    sleep 15
    deploy_stack monitoring
    deploy_stack mail
else
    deploy_stack "$STACK_PATH"
fi
