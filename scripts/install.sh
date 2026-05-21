#!/bin/sh

# Source common functions and variables
. /common.sh

# Configuration variables
ROOTFS_DIR="/home/container"
BASE_URL="https://images.linuxcontainers.org/images"
DISTRO_NAME="debian"
DISTRO_VERSION="trixie"
PRETTY_NAME="Debian 13 (Trixie)"

export PATH="$PATH:~/.local/usr/bin"

error_exit() {
    log "ERROR" "$1" "$RED"
    exit 1
}

ARCH=$(uname -m)

check_network() {
    if ! curl -s --head "$BASE_URL" >/dev/null; then
        error_exit "Unable to connect to $BASE_URL. Please check your internet connection."
    fi
}

cleanup() {
    log "INFO" "Cleaning up temporary files..." "$YELLOW"
    rm -f "$ROOTFS_DIR/rootfs.tar.xz"
    rm -rf /tmp/sbin
}

download_and_extract_rootfs() {
    arch_url="${BASE_URL}/${DISTRO_NAME}/${DISTRO_VERSION}/"
    url="${BASE_URL}/${DISTRO_NAME}/${DISTRO_VERSION}/${ARCH_ALT}/default/"

    if ! curl -s "$arch_url" | grep -q "$ARCH_ALT"; then
        error_exit "$PRETTY_NAME doesn't support $ARCH_ALT."
    fi

    latest_version=$(curl -s "$url" | grep 'href="' | grep -o '[0-9]\{8\}_[0-9]\{2\}:[0-9]\{2\}/' | sort -r | head -n 1) ||
    error_exit "Failed to determine latest rootfs build"

    log "INFO" "Downloading $PRETTY_NAME rootfs..." "$GREEN"
    mkdir -p "$ROOTFS_DIR"

    if ! curl -Ls "${url}${latest_version}rootfs.tar.xz" -o "$ROOTFS_DIR/rootfs.tar.xz"; then
        error_exit "Failed to download rootfs"
    fi

    log "INFO" "Extracting rootfs..." "$GREEN"
    if ! tar -xf "$ROOTFS_DIR/rootfs.tar.xz" -C "$ROOTFS_DIR"; then
        error_exit "Failed to extract rootfs"
    fi

    rm -f "$ROOTFS_DIR/etc/resolv.conf"
    mkdir -p "$ROOTFS_DIR/home/container/"
}

# Generate random username and password
generate_random() {
    length="$1"
    chars="$2"
    head -c 256 /dev/urandom | tr -dc "$chars" | head -c "$length"
}

setup_credentials() {
    log "INFO" "Generating random root credentials..." "$YELLOW"

    RAND_USER="root_$(generate_random 8 'a-z0-9')"
    RAND_PASS="$(generate_random 20 'A-Za-z0-9')"

    cat > "$ROOTFS_DIR/ssh_config.yml" <<EOF
ssh:
  port: "22"
  user: "$RAND_USER"
  password: "$RAND_PASS"

sftp:
  enable: true
EOF

    cat > "$ROOTFS_DIR/root/.vps_credentials" <<EOF
# VPS root credentials (generated $(date -u +"%Y-%m-%dT%H:%M:%SZ"))
USER=$RAND_USER
PASSWORD=$RAND_PASS
SSH_PORT=22
EOF
    chmod 600 "$ROOTFS_DIR/root/.vps_credentials"
}

install_ssh_binary() {
    log "INFO" "Installing SSH server binary..." "$YELLOW"
    ssh_url="https://github.com/ysdragon/ssh/releases/latest/download/ssh-$ARCH_ALT"
    mkdir -p "$ROOTFS_DIR/usr/local/bin"
    if ! curl -Ls "$ssh_url" -o "$ROOTFS_DIR/usr/local/bin/ssh"; then
        log "WARNING" "Failed to download SSH binary. Run 'install-ssh' manually after boot." "$YELLOW"
        return 1
    fi
    chmod +x "$ROOTFS_DIR/usr/local/bin/ssh"
}

print_credentials_banner() {
    INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $NF;exit}')
    printf "\n${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${WHITE}${BOLD}                       VPS ROOT CREDENTIALS (save now!)                       ${CYAN}║${NC}\n"
    printf "${CYAN}╠═══════════════════════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${CYAN}║${NC}  Host:     ${GREEN}%-66s${CYAN}║${NC}\n" "${INTERNAL_IP:-<server-ip>}"
    printf "${CYAN}║${NC}  Port:     ${GREEN}%-66s${CYAN}║${NC}\n" "22"
    printf "${CYAN}║${NC}  User:     ${GREEN}%-66s${CYAN}║${NC}\n" "$RAND_USER"
    printf "${CYAN}║${NC}  Password: ${GREEN}%-66s${CYAN}║${NC}\n" "$RAND_PASS"
    printf "${CYAN}╠═══════════════════════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${CYAN}║${YELLOW}  These credentials are shown ONLY ONCE. They are also saved to:               ${CYAN}║${NC}\n"
    printf "${CYAN}║${YELLOW}  /root/.vps_credentials  and  /ssh_config.yml                                 ${CYAN}║${NC}\n"
    printf "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}\n\n"
}

# Initial setup
ARCH_ALT=$(detect_architecture)
check_network

print_main_banner
log "INFO" "Installing $PRETTY_NAME for $ARCH_ALT..." "$GREEN"

download_and_extract_rootfs
setup_credentials
install_ssh_binary

# Copy run.sh, common.sh, and vnc_install.sh to ROOTFS_DIR and make them executable
cp /common.sh /run.sh "$ROOTFS_DIR"
chmod +x "$ROOTFS_DIR/common.sh" "$ROOTFS_DIR/run.sh"

if [ -f "/vnc_install.sh" ]; then
    cp /vnc_install.sh "$ROOTFS_DIR"
    chmod +x "$ROOTFS_DIR/vnc_install.sh"
fi

print_credentials_banner

# Marker so run.sh can show the one-time notice too
touch "$ROOTFS_DIR/.first_boot"

trap cleanup EXIT
