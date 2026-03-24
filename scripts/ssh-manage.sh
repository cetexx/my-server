#!/bin/bash
set -euo pipefail

# =============================================
# SSH vartotojų valdymas
# =============================================

MANAGED_GROUP="managed-users"

show_help() {
    echo "Naudojimas:"
    echo "  ssh add <user> [--docker]   Pridėk vartotoją (SSH key iš stdin arba interaktyviai)"
    echo "  ssh list                    Visi valdomi vartotojai"
    echo "  ssh remove <user>           Pašalink vartotoją"
    echo "  ssh harden                  Užkietink SSH konfigą"
}

ensure_group() {
    getent group "$MANAGED_GROUP" &>/dev/null || groupadd "$MANAGED_GROUP"
}

ssh_add() {
    local USERNAME=${1:-}
    local ADD_DOCKER=false

    if [ -z "$USERNAME" ]; then
        echo "Naudojimas: ./server.sh ssh add <username> [--docker]"
        exit 1
    fi

    # Tikrink ar nėra --docker flag'o
    for arg in "${@:2}"; do
        if [ "$arg" = "--docker" ]; then
            ADD_DOCKER=true
        fi
    done

    # Validuojam username
    if ! echo "$USERNAME" | grep -qE '^[a-z][a-z0-9_-]*$'; then
        echo "Klaida: username gali turėti tik mažąsias raides, skaičius, - ir _"
        exit 1
    fi

    # Apsauga — neleidžiam keisti root
    if [ "$USERNAME" = "root" ]; then
        echo "Klaida: root vartotojo keisti negalima"
        exit 1
    fi

    ensure_group

    # Sukuriam userį jei neegzistuoja
    if id "$USERNAME" &>/dev/null; then
        echo "Vartotojas '$USERNAME' jau egzistuoja, pridedu SSH key..."
    else
        useradd -m -s /bin/bash -G "$MANAGED_GROUP" "$USERNAME"
        # Uždraudžiam password login
        passwd -l "$USERNAME" &>/dev/null
        echo "Vartotojas '$USERNAME' sukurtas"
    fi

    # Docker grupė
    if [ "$ADD_DOCKER" = true ]; then
        usermod -aG docker "$USERNAME" 2>/dev/null && echo "Pridėtas prie docker grupės" || true
    fi

    # SSH key
    local SSH_DIR="/home/$USERNAME/.ssh"
    mkdir -p "$SSH_DIR"

    echo ""
    echo "Įvesk SSH public key (ssh-rsa AAAA... arba ssh-ed25519 AAAA...):"
    echo "(arba pipe'ink: echo 'ssh-ed25519 ...' | ./server.sh ssh add user)"
    echo ""
    read -r SSH_KEY

    if [ -z "$SSH_KEY" ]; then
        echo "Klaida: SSH key tuščias"
        exit 1
    fi

    # Validuojam key formatą
    if ! echo "$SSH_KEY" | grep -qE '^ssh-(rsa|ed25519|ecdsa)'; then
        echo "Klaida: netinkamas SSH key formatas"
        exit 1
    fi

    # Pridedam key (nekartojam jei jau yra)
    touch "$SSH_DIR/authorized_keys"
    if grep -qF "$SSH_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "Šis SSH key jau pridėtas"
    else
        echo "$SSH_KEY" >> "$SSH_DIR/authorized_keys"
        echo "SSH key pridėtas"
    fi

    # Teisingi permissions
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"

    echo ""
    echo "=== Vartotojas '$USERNAME' paruoštas ==="
    echo "Prisijungimas: ssh $USERNAME@<server-ip>"
    if [ "$ADD_DOCKER" = true ]; then
        echo "Docker prieiga: taip"
    else
        echo "Docker prieiga: ne (pridėk su: ./server.sh ssh add $USERNAME --docker)"
    fi
}

ssh_list() {
    ensure_group

    echo "=== Valdomi SSH vartotojai ==="
    echo ""

    local MEMBERS
    MEMBERS=$(getent group "$MANAGED_GROUP" | cut -d: -f4 | tr ',' '\n')

    if [ -z "$MEMBERS" ]; then
        echo "(nėra vartotojų)"
        return
    fi

    printf "%-15s %-10s %-8s %s\n" "USER" "DOCKER" "KEYS" "LAST LOGIN"
    printf "%-15s %-10s %-8s %s\n" "----" "------" "----" "----------"

    for user in $MEMBERS; do
        local IN_DOCKER="ne"
        local KEY_COUNT=0
        local LAST_LOGIN="niekada"

        if groups "$user" 2>/dev/null | grep -q docker; then
            IN_DOCKER="taip"
        fi

        if [ -f "/home/$user/.ssh/authorized_keys" ]; then
            KEY_COUNT=$(grep -c "^ssh-" "/home/$user/.ssh/authorized_keys" 2>/dev/null || echo 0)
        fi

        LAST_LOGIN=$(lastlog -u "$user" 2>/dev/null | tail -1 | awk '{if ($2 == "**Never") print "niekada"; else print $4" "$5" "$6" "$7}' || echo "?")

        printf "%-15s %-10s %-8s %s\n" "$user" "$IN_DOCKER" "$KEY_COUNT" "$LAST_LOGIN"
    done
}

ssh_remove() {
    local USERNAME=${1:-}

    if [ -z "$USERNAME" ]; then
        echo "Naudojimas: ./server.sh ssh remove <username>"
        exit 1
    fi

    if [ "$USERNAME" = "root" ]; then
        echo "Klaida: root pašalinti negalima"
        exit 1
    fi

    if ! id "$USERNAME" &>/dev/null; then
        echo "Klaida: vartotojas '$USERNAME' neegzistuoja"
        exit 1
    fi

    read -p "Tikrai pašalinti vartotoją '$USERNAME' ir jo home dir? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Atšaukta"
        exit 0
    fi

    # Nutraukiam aktyvias sesijas
    pkill -u "$USERNAME" 2>/dev/null || true

    userdel -r "$USERNAME" 2>/dev/null
    echo "Vartotojas '$USERNAME' pašalintas"
}

ssh_harden() {
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    local HARDENED_CONFIG="/etc/ssh/sshd_config.d/99-hardened.conf"

    echo "=== SSH kietinimas ==="
    echo ""

    # Backup'inam originalą
    if [ ! -f "${SSHD_CONFIG}.backup" ]; then
        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup"
        echo "Original SSHD config backup'intas → ${SSHD_CONFIG}.backup"
    fi

    mkdir -p /etc/ssh/sshd_config.d

    cat > "$HARDENED_CONFIG" <<'SSHEOF'
# === Hardened SSH config ===

# Draudžiam root login per SSH
PermitRootLogin no

# Tik SSH key autentifikacija
PasswordAuthentication no
PubkeyAuthentication yes

# Draudžiam tuščius slaptažodžius
PermitEmptyPasswords no

# Draudžiam X11 forwarding
X11Forwarding no

# Limitai
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

# Alive check
ClientAliveInterval 300
ClientAliveCountMax 2
SSHEOF

    echo "Sukurtas: $HARDENED_CONFIG"
    echo ""

    # Testuojam konfigą
    if sshd -t 2>/dev/null; then
        echo "SSH config validus"
        systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
        echo "SSH reloadintas"
    else
        echo "KLAIDA: SSH config nevalidus! Grąžinam atgal..."
        rm -f "$HARDENED_CONFIG"
        exit 1
    fi

    echo ""
    echo "=== SSH užkietintas ==="
    echo ""
    echo "SVARBU: Prieš atsijungiant, patikrink kad gali prisijungti"
    echo "su SSH key kitame terminale!"
}

case "${1:-}" in
    add)    ssh_add "${@:2}" ;;
    list)   ssh_list ;;
    remove) ssh_remove "${@:2}" ;;
    harden) ssh_harden ;;
    *)      show_help ;;
esac
