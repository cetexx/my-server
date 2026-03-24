#!/bin/bash
set -euo pipefail

echo "=== VPS Docker Swarm Setup ==="

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Paleisk kaip root: sudo ./setup.sh"
    exit 1
fi

# Initialize Docker Swarm
if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
    echo "Initializing Docker Swarm..."
    docker swarm init
else
    echo "Docker Swarm jau inicializuotas"
fi

# Create overlay networks
echo "Creating overlay networks..."
docker network create --driver overlay --attachable traefik-public 2>/dev/null || echo "  traefik-public jau egzistuoja"
docker network create --driver overlay --attachable internal 2>/dev/null || echo "  internal jau egzistuoja"

# Create data directories
echo "Creating data directories..."
mkdir -p /opt/my-server/{traefik/acme,postgresql/data,redis/data,grafana/data,prometheus/data,portainer/data}
mkdir -p /opt/my-server/mailserver/{data,state,logs,config}
mkdir -p /opt/my-server/certs

# Set permissions
touch /opt/my-server/traefik/acme/acme.json
chmod 600 /opt/my-server/traefik/acme/acme.json
chown -R 472:472 /opt/my-server/grafana/data
chown -R 65534:65534 /opt/my-server/prometheus/data

# Docker daemon config (log rotation, live-restore)
echo "Configuring Docker daemon..."
if [ ! -f /etc/docker/daemon.json ]; then
    cp core/docker-daemon.json /etc/docker/daemon.json
    systemctl reload docker 2>/dev/null || true
    echo "  Docker daemon sukonfigūruotas"
else
    echo "  /etc/docker/daemon.json jau egzistuoja — praleista"
    echo "  Jei reikia log rotation, pridėk rankiniu būdu iš core/docker-daemon.json"
fi

# Unattended security updates
echo "Configuring automatic security updates..."
if command -v apt-get &>/dev/null; then
    apt-get install -y -qq unattended-upgrades > /dev/null 2>&1
    dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
    echo "  Unattended upgrades įjungti"
elif command -v dnf &>/dev/null; then
    dnf install -y -q dnf-automatic > /dev/null 2>&1
    systemctl enable --now dnf-automatic-install.timer 2>/dev/null || true
    echo "  DNF automatic updates įjungti"
fi

# Cron jobs
echo "Setting up cron jobs..."
"$PWD/scripts/cron-setup.sh" 2>/dev/null || echo "  Cron setup nepavyko — paleisk rankiniu būdu: ./scripts/cron-setup.sh"

# Check .env
if [ ! -f .env ]; then
    echo ""
    echo "DĖMESIO: .env failas nerastas!"
    echo "  cp .env.example .env"
    echo "  Tada redaguok .env su savo reikšmėmis"
    exit 1
fi

echo ""
echo "=== Setup baigtas ==="
echo ""
echo "Tolesni žingsniai:"
echo "  1. Redaguok .env su savo domenu ir slaptažodžiais"
echo "  2. Deploy stack'us:"
echo "     ./deploy.sh core"
echo "     ./deploy.sh monitoring"
echo "     ./deploy.sh mail"
