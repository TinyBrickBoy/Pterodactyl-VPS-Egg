#!/bin/sh

# Source common functions and variables
. /common.sh

# Ensure the systemctl shim is present so `systemctl` works inside PRoot.
# This handles both fresh installs and existing rootfs containers that
# pre-date the shim.
if [ ! -x "/usr/local/bin/systemctl" ] && [ -f "/systemctl-shim.sh" ]; then
    mkdir -p /usr/local/bin
    cp /systemctl-shim.sh /usr/local/bin/systemctl
    chmod +x /usr/local/bin/systemctl
fi

# Configuration
HOSTNAME="MyVPS"
HISTORY_FILE="${HOME}/.custom_shell_history"
MAX_HISTORY=1000

# Check if not installed
if [ ! -e "/.installed" ]; then
    # Check if rootfs.tar.xz or rootfs.tar.gz exists and remove them if they do
    if [ -f "/rootfs.tar.xz" ]; then
        rm -f "/rootfs.tar.xz"
    fi
    
    if [ -f "/rootfs.tar.gz" ]; then
        rm -f "/rootfs.tar.gz"
    fi
    
    # Wipe the files we downloaded into /tmp previously
    rm -rf /tmp/sbin

    # Add DNS Resolver nameservers to resolv.conf
    printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf

    # Mark as installed.
    touch "/.installed"
fi

# Read the Pterodactyl-allocated IP/port from /vps.config (populated by
# the panel via the egg's file parser) and apply it to /ssh_config.yml so
# the bundled SSH server listens on the port that is actually exposed.
sync_ssh_port_from_pterodactyl() {
    PTERO_PORT=""
    PTERO_IP=""
    if [ -f "/vps.config" ]; then
        PTERO_PORT=$(grep -E '^[[:space:]]*port[[:space:]]*=' /vps.config | head -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        PTERO_IP=$(grep -E '^[[:space:]]*internalip[[:space:]]*=' /vps.config | head -n1 | cut -d'=' -f2- | tr -d '[:space:]')
    fi

    case "$PTERO_PORT" in
        ''|*[!0-9]*) PTERO_PORT="" ;;
    esac

    if [ -n "$PTERO_PORT" ] && [ -f "/ssh_config.yml" ]; then
        sed -i "s/^\([[:space:]]*port:[[:space:]]*\).*/\1\"$PTERO_PORT\"/" /ssh_config.yml

        if [ -f "/root/.vps_credentials" ]; then
            if grep -q '^SSH_PORT=' /root/.vps_credentials; then
                sed -i "s/^SSH_PORT=.*/SSH_PORT=$PTERO_PORT/" /root/.vps_credentials
            else
                printf "SSH_PORT=%s\n" "$PTERO_PORT" >> /root/.vps_credentials
            fi
        fi
    fi
}

# Show one-time credentials banner on first boot
show_first_boot_credentials() {
    if [ ! -f "/.first_boot" ]; then
        return
    fi

    if [ ! -f "/root/.vps_credentials" ]; then
        rm -f "/.first_boot"
        return
    fi

    . "/root/.vps_credentials" 2>/dev/null
    HOST_DISPLAY="${PTERO_IP:-$(ip route get 1 2>/dev/null | awk '{print $NF;exit}')}"

    printf "\n${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${WHITE}${BOLD}                       VPS ROOT CREDENTIALS (save now!)                       ${CYAN}║${NC}\n"
    printf "${CYAN}╠═══════════════════════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${CYAN}║${NC}  Host:     ${GREEN}%-66s${CYAN}║${NC}\n" "${HOST_DISPLAY:-<server-ip>}"
    printf "${CYAN}║${NC}  Port:     ${GREEN}%-66s${CYAN}║${NC}\n" "${SSH_PORT:-22}"
    printf "${CYAN}║${NC}  User:     ${GREEN}%-66s${CYAN}║${NC}\n" "$USER"
    printf "${CYAN}║${NC}  Password: ${GREEN}%-66s${CYAN}║${NC}\n" "$PASSWORD"
    printf "${CYAN}╠═══════════════════════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${CYAN}║${YELLOW}  Shown ONLY ONCE. Also stored in /root/.vps_credentials                       ${CYAN}║${NC}\n"
    printf "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}\n\n"

    rm -f "/.first_boot"
}

# Ensure SSH login sessions have a prompt that shows the current path.
# Idempotent so existing installs get the prompt without needing reinstall.
ensure_shell_prompt() {
    if [ ! -f "/etc/profile.d/vps-prompt.sh" ]; then
        mkdir -p /etc/profile.d 2>/dev/null
        cat > /etc/profile.d/vps-prompt.sh <<'EOF'
# Default prompt for VPS SSH sessions: show user@host:full-path#
if [ -n "$BASH_VERSION" ]; then
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='$(whoami)@$(hostname):$(pwd)$ '
fi
export PS1
EOF
        chmod 644 /etc/profile.d/vps-prompt.sh 2>/dev/null
    fi

    if [ ! -f "/root/.bashrc" ] || ! grep -q '\\w' /root/.bashrc 2>/dev/null; then
        cat > /root/.bashrc <<'EOF'
# ~/.bashrc for VPS root user
[ -z "$PS1" ] && return

HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend
shopt -s checkwinsize

PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ls='ls --color=auto' 2>/dev/null || true
EOF
        chmod 644 /root/.bashrc 2>/dev/null
    fi

    if [ ! -f "/root/.profile" ]; then
        cat > /root/.profile <<'EOF'
# ~/.profile for VPS root user
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOF
        chmod 644 /root/.profile 2>/dev/null
    fi
}

# Auto-start bundled SSH server if config exists
start_ssh_server() {
    if [ ! -x "/usr/local/bin/ssh" ]; then
        log "ERROR" "SSH binary missing at /usr/local/bin/ssh. Run 'install-ssh'." "$RED"
        return 1
    fi
    if [ ! -f "/ssh_config.yml" ]; then
        log "ERROR" "/ssh_config.yml missing. SSH server will not start." "$RED"
        return 1
    fi
    if pgrep -f "/usr/local/bin/ssh" > /dev/null 2>&1; then
        return 0
    fi

    CONFIGURED_PORT=$(grep -E '^[[:space:]]*port:' /ssh_config.yml | head -n1 | sed 's/.*: *"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]')
    if [ "$CONFIGURED_PORT" = "22" ] && [ ! -f "/vps.config" ]; then
        log "ERROR" "/vps.config not found and ssh_config.yml still on port 22." "$RED"
        log "ERROR" "Pterodactyl did not populate the allocated port; SSH cannot bind 22 as an unprivileged user." "$RED"
        log "INFO"  "Restart the server once the allocation is attached, or edit /ssh_config.yml manually." "$YELLOW"
        return 1
    fi

    mkdir -p /var/log 2>/dev/null
    : > /var/log/ssh.log 2>/dev/null
    # ysdragon/ssh is an interactive binary that exits on stdin EOF ("Type 'q' to exit.").
    # Feed it a stdin that never closes so it stays alive in the background.
    tail -f /dev/null | /usr/local/bin/ssh > /var/log/ssh.log 2>&1 &
    SSH_PID=$!

    # Give the server a moment to bind, then verify it survived.
    i=0
    while [ $i -lt 10 ]; do
        if ! kill -0 "$SSH_PID" 2>/dev/null; then
            break
        fi
        if (netstat -tln 2>/dev/null || ss -tln 2>/dev/null) | grep -q ":${CONFIGURED_PORT} "; then
            log "SUCCESS" "SSH listening on port ${CONFIGURED_PORT}." "$GREEN"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    if kill -0 "$SSH_PID" 2>/dev/null; then
        log "WARNING" "SSH process is running but not detected on port ${CONFIGURED_PORT} yet. See /var/log/ssh.log." "$YELLOW"
        return 0
    fi

    log "ERROR" "SSH server exited immediately. Last log lines:" "$RED"
    tail -n 20 /var/log/ssh.log 2>/dev/null
    return 1
}

sync_ssh_port_from_pterodactyl

# Check if the autorun script exists
if [ ! -e "/autorun.sh" ]; then
    touch /autorun.sh
    chmod +x /autorun.sh
fi

printf "\033c"
printf "${GREEN}Starting..${NC}\n"
sleep 1
printf "\033c"

# Function to handle cleanup on exit
cleanup() {
    log "INFO" "Session ended. Goodbye!" "$GREEN"
    exit 0
}

# Function to get formatted directory
get_formatted_dir() {
    current_dir="$PWD"
    case "$current_dir" in
        "$HOME"*)
            printf "~${current_dir#$HOME}"
        ;;
        *)
            printf "$current_dir"
        ;;
    esac
}

# Function to print prompt
print_prompt() {
    user="$1"
    printf "\n${GREEN}${user}@${HOSTNAME}${NC}:${RED}$(get_formatted_dir)${NC}# "
}

# Function to save command to history
save_to_history() {
    cmd="$1"
    if [ -n "$cmd" ] && [ "$cmd" != "exit" ]; then
        printf "$cmd\n" >> "$HISTORY_FILE"
        # Keep only last MAX_HISTORY lines
        if [ -f "$HISTORY_FILE" ]; then
            tail -n "$MAX_HISTORY" "$HISTORY_FILE" > "$HISTORY_FILE.tmp"
            mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
        fi
    fi
}

# Function reinstall the OS
reinstall() {    
    log "INFO" "Reinstalling the OS..." "$YELLOW"
    
    find / -mindepth 1 -xdev -delete > /dev/null 2>&1
}

install_wget() {
    distro=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    
    case "$distro" in
        "debian"|"ubuntu"|"devuan"|"linuxmint"|"kali")
            apt-get update -qq && apt-get install -y -qq wget > /dev/null 2>&1
        ;;
        "void")
            xbps-install -Syu wget > /dev/null 2>&1
        ;;
        "centos"|"fedora"|"rocky"|"almalinux"|"openEuler"|"amzn"|"ol")
            yum install -y -q wget > /dev/null 2>&1
        ;;
        "opensuse"|"opensuse-tumbleweed"|"opensuse-leap")
            zypper install -y -q wget > /dev/null 2>&1
        ;;
        "alpine"|"chimera")
            apk add -q --no-interactive --no-scripts wget > /dev/null 2>&1
        ;;
        "gentoo")
            emerge --sync -q && emerge -q wget > /dev/null 2>&1
        ;;
        "arch")
            pacman -Syu --noconfirm --quiet wget > /dev/null 2>&1
        ;;
        "slackware")
            yes | slackpkg install wget > /dev/null 2>&1
        ;;
        *)
            log "ERROR" "Unsupported distribution: $distro" "$RED"
            return 1
        ;;
    esac
}

GUI_CONFIG_FILE="/gui_config.yml"
VNC_DIR="$HOME/.vnc"

install_gui() {
    if [ -f "/gui_config.yml" ]; then
        log "WARNING" "GUI is already installed. Run 'reinstall-gui' to reinstall." "$YELLOW"
        return 1
    fi
    
    if [ -f "/vnc_install.sh" ]; then
        sh /vnc_install.sh install
    else
        log "ERROR" "GUI installation script not found." "$RED"
        return 1
    fi
}

reinstall_gui() {
    rm -f "$GUI_CONFIG_FILE"
    rm -rf "$VNC_DIR"
    rm -f "$HOME/.xsession"
    install_gui
}

parse_gui_config() {
    if [ -f "$GUI_CONFIG_FILE" ]; then
        GUI_SERVER_TYPE="vnc"
        GUI_DE_STARTUP=$(grep -E '^\s*startup_command:' "$GUI_CONFIG_FILE" | sed 's/.*: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
        GUI_DE=$(grep -E '^\s*environment:' "$GUI_CONFIG_FILE" | sed 's/.*: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
        VNC_PORT=$(grep -A5 '^vnc:' "$GUI_CONFIG_FILE" | grep -E '^\s*port:' | head -1 | sed 's/.*: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
        VNC_PASSWORD=$(grep -A5 '^vnc:' "$GUI_CONFIG_FILE" | grep -E '^\s*password:' | sed 's/.*: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
        NOVNC_PORT=$(grep -A3 '^novnc:' "$GUI_CONFIG_FILE" | grep -E '^\s*port:' | sed 's/.*: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
        
        VNC_PORT="${VNC_PORT:-5901}"
        NOVNC_PORT="${NOVNC_PORT:-6080}"
        
        if [ -z "$GUI_DE_STARTUP" ]; then
            case "$GUI_DE" in
                "xfce4") GUI_DE_STARTUP="startxfce4" ;;
                "lxde") GUI_DE_STARTUP="startlxde" ;;
                "lxqt") GUI_DE_STARTUP="startlxqt" ;;
                "mate") GUI_DE_STARTUP="mate-session" ;;
                *) GUI_DE_STARTUP="startxfce4" ;;
            esac
        fi
    fi
}

start_vnc() {
    if [ ! -f "$GUI_CONFIG_FILE" ]; then
        log "ERROR" "GUI not installed. Run 'install-gui' first." "$RED"
        return 1
    fi
    
    parse_gui_config
    
    if [ "$GUI_SERVER_TYPE" != "vnc" ] && [ "$GUI_SERVER_TYPE" != "both" ]; then
        log "ERROR" "VNC server not configured. Server type: $GUI_SERVER_TYPE" "$RED"
        return 1
    fi
    
    if pgrep -x "Xvnc" > /dev/null 2>&1 || pgrep -x "Xtightvnc" > /dev/null 2>&1; then
        log "WARNING" "VNC server is already running." "$YELLOW"
        return 0
    fi
    
    log "INFO" "Starting VNC server on port $VNC_PORT..." "$YELLOW"
    
    VNC_DISPLAY_NUM=$((VNC_PORT - 5900))
    if [ "$VNC_DISPLAY_NUM" -lt 1 ]; then
        VNC_DISPLAY_NUM=1
    fi
    
    mkdir -p "$HOME/.vnc" 2>/dev/null
    mkdir -p /tmp/.X11-unix 2>/dev/null || true
    
    pkill -f "Xtigervnc.*:$VNC_DISPLAY_NUM" > /dev/null 2>&1 || true
    pkill -f "Xvnc.*:$VNC_DISPLAY_NUM" > /dev/null 2>&1 || true
    sleep 1
    
    start_desktop_env() {
        export DISPLAY=":$VNC_DISPLAY_NUM"
        export HOME="$HOME"
        export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
        
        case "$GUI_DE" in
            xfce4)
                xfwm4 --compositor=off 2>/dev/null &
                sleep 1
                xfce4-panel 2>/dev/null &
                xfdesktop 2>/dev/null &
                ;;
            lxde)
                openbox 2>/dev/null &
                sleep 1
                lxpanel 2>/dev/null &
                pcmanfm --desktop 2>/dev/null &
                ;;
            lxqt)
                openbox 2>/dev/null &
                sleep 1
                lxqt-panel 2>/dev/null &
                pcmanfm-qt --desktop 2>/dev/null &
                ;;
            mate)
                marco &
                sleep 1
                mate-panel 2>/dev/null &
                caja --no-desktop 2>/dev/null &
                ;;
            *)
                if command -v openbox > /dev/null 2>&1; then
                    openbox &
                elif command -v xfwm4 > /dev/null 2>&1; then
                    xfwm4 &
                fi
                ;;
        esac
        
        log "INFO" "Desktop started: $GUI_DE" "$YELLOW"
        sleep 2
    }
    
    VNC_SECURITY="-SecurityTypes None"
    if [ -n "$VNC_PASSWORD" ] && [ "$VNC_PASSWORD" != "" ]; then
        mkdir -p "$HOME/.vnc" 2>/dev/null
        printf "%s\n%s\nn\n" "$VNC_PASSWORD" "$VNC_PASSWORD" | vncpasswd "$HOME/.vnc/passwd" > /dev/null 2>&1
        if [ -f "$HOME/.vnc/passwd" ]; then
            VNC_SECURITY="-SecurityTypes VncAuth -PasswordFile $HOME/.vnc/passwd"
        fi
    fi
    
    if command -v Xtigervnc > /dev/null 2>&1; then
        Xtigervnc ":$VNC_DISPLAY_NUM" -geometry 1280x720 -depth 24 -rfbport "$VNC_PORT" $VNC_SECURITY -pn -ac &
        sleep 2
        start_desktop_env
        
    elif command -v Xvnc > /dev/null 2>&1; then
        Xvnc ":$VNC_DISPLAY_NUM" -geometry 1280x720 -depth 24 -rfbport "$VNC_PORT" $VNC_SECURITY -pn -ac &
        sleep 2
        start_desktop_env
        
    elif command -v x11vnc > /dev/null 2>&1; then
        pkill -f "Xvfb.*:$VNC_DISPLAY_NUM" > /dev/null 2>&1 || true
        
        Xvfb ":$VNC_DISPLAY_NUM" -screen 0 1280x720x24 -ac &
        sleep 2
        start_desktop_env
        
        if [ -n "$VNC_PASSWORD" ]; then
            x11vnc -display ":$VNC_DISPLAY_NUM" -rfbport "$VNC_PORT" -forever -shared -passwd "$VNC_PASSWORD" -bg
        else
            x11vnc -display ":$VNC_DISPLAY_NUM" -rfbport "$VNC_PORT" -forever -shared -nopw -bg
        fi
        sleep 2
    else
        log "ERROR" "No VNC server found (Xtigervnc, Xvnc, or x11vnc)." "$RED"
        return 1
    fi
    
    if pgrep -f "Xvnc.*:$VNC_DISPLAY_NUM" > /dev/null 2>&1 || pgrep -f "Xtigervnc.*:$VNC_DISPLAY_NUM" > /dev/null 2>&1 || pgrep -f "x11vnc" > /dev/null 2>&1; then
        log "SUCCESS" "VNC server started on port $VNC_PORT (display :$VNC_DISPLAY_NUM)" "$GREEN"
        log "INFO" "Connect using: <server-ip>:$VNC_PORT" "$YELLOW"
    else
        log "ERROR" "VNC server failed to start. Check logs at ~/.vnc/" "$RED"
        return 1
    fi
}

stop_vnc() {
    log "INFO" "Stopping VNC server..." "$YELLOW"
    
    parse_gui_config
    VNC_DISPLAY_NUM=$((VNC_PORT - 5900))
    if [ "$VNC_DISPLAY_NUM" -lt 1 ]; then
        VNC_DISPLAY_NUM=1
    fi
    
    if command -v vncserver > /dev/null 2>&1; then
        vncserver -kill ":$VNC_DISPLAY_NUM" > /dev/null 2>&1
    fi
    
    pkill -f "Xvnc" > /dev/null 2>&1
    pkill -f "Xtigervnc" > /dev/null 2>&1
    pkill -f "x11vnc" > /dev/null 2>&1
    pkill -f "Xvfb" > /dev/null 2>&1
    
    log "SUCCESS" "VNC server stopped." "$GREEN"
}

start_novnc() {
    if [ ! -f "$GUI_CONFIG_FILE" ]; then
        log "ERROR" "GUI not installed. Run 'install-gui' first." "$RED"
        return 1
    fi
    
    parse_gui_config
    
    if pgrep -f "websockify" > /dev/null 2>&1; then
        log "WARNING" "noVNC is already running." "$YELLOW"
        return 0
    fi
    
    start_vnc
    
    log "INFO" "Starting noVNC on port $NOVNC_PORT..." "$YELLOW"
    
    NOVNC_PATH=""
    if [ -d "/usr/share/novnc" ]; then
        NOVNC_PATH="/usr/share/novnc"
    elif [ -d "/usr/share/webapps/novnc" ]; then
        NOVNC_PATH="/usr/share/webapps/novnc"
    fi
    
    if command -v websockify > /dev/null 2>&1; then
        if [ -n "$NOVNC_PATH" ]; then
            websockify --web="$NOVNC_PATH" "$NOVNC_PORT" localhost:"$VNC_PORT" > /dev/null 2>&1 &
        else
            websockify "$NOVNC_PORT" localhost:"$VNC_PORT" > /dev/null 2>&1 &
        fi
        sleep 2
        log "SUCCESS" "noVNC started on port $NOVNC_PORT" "$GREEN"
        log "INFO" "Open in browser: http://<server-ip>:$NOVNC_PORT/vnc.html" "$YELLOW"
    else
        log "ERROR" "websockify not found. noVNC may not be installed." "$RED"
        return 1
    fi
}

stop_novnc() {
    log "INFO" "Stopping noVNC..." "$YELLOW"
    pkill -f "websockify" > /dev/null 2>&1
    log "SUCCESS" "noVNC stopped." "$GREEN"
}

install_cloudflared() {
    if command -v cloudflared > /dev/null 2>&1; then
        return 0
    fi
    
    log "INFO" "Installing cloudflared..." "$YELLOW"
    
    arch=$(uname -m)
    case "$arch" in
        x86_64) cf_arch="amd64" ;;
        aarch64) cf_arch="arm64" ;;
        armv7l) cf_arch="arm" ;;
        *) 
            log "ERROR" "Unsupported architecture: $arch" "$RED"
            return 1
            ;;
    esac
    
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    
    if command -v wget > /dev/null 2>&1; then
        wget -q -O /usr/local/bin/cloudflared "$cf_url"
    elif command -v curl > /dev/null 2>&1; then
        curl -sL -o /usr/local/bin/cloudflared "$cf_url"
    else
        log "ERROR" "wget or curl required to download cloudflared" "$RED"
        return 1
    fi
    
    chmod +x /usr/local/bin/cloudflared
    log "SUCCESS" "cloudflared installed" "$GREEN"
}

start_tunnel() {
    if [ ! -f "$GUI_CONFIG_FILE" ]; then
        log "ERROR" "GUI not installed. Run 'install-gui' first." "$RED"
        return 1
    fi
    
    if pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
        log "WARNING" "Tunnel is already running." "$YELLOW"
        return 0
    fi
    
    install_cloudflared || return 1
    
    parse_gui_config
    
    if ! pgrep -f "websockify" > /dev/null 2>&1; then
        start_novnc
        sleep 3
    fi
    
    retries=0
    while [ $retries -lt 10 ]; do
        if netstat -tln 2>/dev/null | grep -q ":$NOVNC_PORT " || ss -tln 2>/dev/null | grep -q ":$NOVNC_PORT "; then
            break
        fi
        sleep 1
        retries=$((retries + 1))
    done
    
    if [ $retries -eq 10 ]; then
        log "ERROR" "noVNC not listening on port $NOVNC_PORT after 10 seconds" "$RED"
        return 1
    fi
    
    log "INFO" "Starting Cloudflare tunnel for noVNC (port $NOVNC_PORT)..." "$YELLOW"
    
    TUNNEL_LOG="/tmp/cloudflared.log"
    cloudflared tunnel --url "http://localhost:$NOVNC_PORT" > "$TUNNEL_LOG" 2>&1 &
    
    sleep 5
    
    TUNNEL_URL=$(grep -o 'https://[^[:space:]]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -1)
    
    if [ -n "$TUNNEL_URL" ]; then
        log "SUCCESS" "Tunnel started!" "$GREEN"
        printf "\n${CYAN}========================================${NC}\n"
        printf "${GREEN}noVNC URL: ${WHITE}${TUNNEL_URL}/vnc.html${NC}\n"
        printf "${CYAN}========================================${NC}\n\n"
        log "INFO" "Share this URL to access your desktop from anywhere" "$YELLOW"
    else
        log "WARNING" "Tunnel started but URL not yet available" "$YELLOW"
        log "INFO" "Check $TUNNEL_LOG for the URL" "$YELLOW"
    fi
}

stop_tunnel() {
    log "INFO" "Stopping Cloudflare tunnel..." "$YELLOW"
    pkill -f "cloudflared.*tunnel" > /dev/null 2>&1
    log "SUCCESS" "Tunnel stopped." "$GREEN"
}

gui_status() {
    printf "\n${CYAN}GUI Server Status:${NC}\n\n"
    
    if [ ! -f "$GUI_CONFIG_FILE" ]; then
        log "INFO" "GUI not installed. Run 'install-gui' to install." "$YELLOW"
        return
    fi
    
    parse_gui_config
    
    printf "  Desktop: $GUI_DE_STARTUP\n\n"
    
    printf "  ${YELLOW}VNC:${NC}\n"
    if pgrep -f "Xvnc" > /dev/null 2>&1 || pgrep -f "Xtigervnc" > /dev/null 2>&1 || pgrep -f "x11vnc" > /dev/null 2>&1; then
        printf "    Status: ${GREEN}Running${NC}\n"
    else
        printf "    Status: ${RED}Stopped${NC}\n"
    fi
    printf "    Port: $VNC_PORT\n\n"
    
    printf "  ${YELLOW}noVNC:${NC}\n"
    if pgrep -f "websockify" > /dev/null 2>&1; then
        printf "    Status: ${GREEN}Running${NC}\n"
    else
        printf "    Status: ${RED}Stopped${NC}\n"
    fi
    printf "    Port: $NOVNC_PORT\n\n"
    
    printf "  ${YELLOW}Tunnel:${NC}\n"
    if pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
        printf "    Status: ${GREEN}Running${NC}\n"
        TUNNEL_URL=$(grep -o 'https://[^[:space:]]*\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            printf "    URL: ${TUNNEL_URL}/vnc.html\n"
        fi
    else
        printf "    Status: ${RED}Stopped${NC}\n"
    fi
    printf "\n"
}

# Function to install SSH from the repository
install_ssh() {
    # Check if SSH is already installed
    if [ -f "/usr/local/bin/ssh" ]; then
        log "ERROR" "SSH is already installed." "$RED"
        return 1
    fi

    # Install wget if not found
    if ! command -v wget &> /dev/null; then
        log "INFO" "Installing wget." "$YELLOW"
        install_wget
    fi
    
    log "INFO" "Installing SSH." "$YELLOW"
    
    # Determine the architecture
    arch=$(detect_architecture)
    
    # URL to download the SSH binary
    url="https://github.com/ysdragon/ssh/releases/latest/download/ssh-$arch"
    
    # Download the SSH binary
    wget -q -O /usr/local/bin/ssh "$url" || {
        log "ERROR" "Failed to download SSH." "$RED"
        return 1
    }
    
    # Make the binary executable
    chmod +x /usr/local/bin/ssh || {
        log "ERROR" "Failed to make ssh executable." "$RED"
        return 1
    }    

    log "SUCCESS" "SSH installed successfully." "$GREEN"
}

# Function to show system status
show_system_status() {
    log "INFO" "System Status:" "$GREEN"
    uptime
    free -h
    df -h
    ps aux --sort=-%mem | head -n 10
}

# Function to create a backup
create_backup() {
    # Check if tar is installed
    if ! command -v tar > /dev/null 2>&1; then
        log "ERROR" "tar is not installed. Please install tar first." "$RED"
        return 1
    fi

    backup_file="/backup_$(date +%Y%m%d%H%M%S).tar.gz"
    exclude_file="/tmp/exclude-list.txt"

    # Create a file with a list of patterns to exclude. This is more
    # compatible with different versions of tar, including busybox tar.
    # We use relative paths for exclusion as we'll be running tar from /.
    cat > "$exclude_file" <<EOF
./${backup_file#/}
./proc
./tmp
./dev
./sys
./run
./vps.config
${exclude_file#/}
EOF

    log "INFO" "Starting backup process..." "$YELLOW"
    (cd / && tar --numeric-owner -czf "$backup_file" -X "$exclude_file" .) > /dev/null 2>&1
    log "SUCCESS" "Backup created at $backup_file" "$GREEN"

    # Clean up the exclude file
    rm -f "$exclude_file"
}

# Function to restore a backup
restore_backup() {
    backup_file="$1"

    # Check if tar is installed
    if ! command -v tar > /dev/null 2>&1; then
        log "ERROR" "tar is not installed. Please install tar first." "$RED"
        return 1
    fi

    if [ -z "$backup_file" ]; then
        log "INFO" "Usage: restore <backup_file>" "$YELLOW"
        log "INFO" "Example: restore backup_20250620024221.tar.gz" "$YELLOW"
        return 1
    fi

    if [ -f "/$backup_file" ]; then
        log "INFO" "Starting restore process..." "$YELLOW"
        tar --numeric-owner -xzf "/$backup_file" -C / --exclude="$backup_file" > /dev/null 2>&1
        log "SUCCESS" "Backup restored from $backup_file" "$GREEN"
    else
        log "ERROR" "Backup file not found: $backup_file" "$RED"
    fi
}

# Function to handle command execution
execute_command() {
    cmd="$1"
    user="$2"
    
    # Save command to history
    save_to_history "$cmd"
    
    # Handle special commands
    case "$cmd" in
        "clear"|"cls")
            printf "\033c"
            print_prompt "$user"
            return 0
        ;;
        "exit")
            cleanup
        ;;
        "history")
            if [ -f "$HISTORY_FILE" ]; then
                cat "$HISTORY_FILE"
            fi
            print_prompt "$user"
            return 0
        ;;
        "reinstall")
            reinstall
            exit 2
        ;;
        "sudo"*|"su"*)
            log "ERROR" "You are already running as root." "$RED"
            print_prompt "$user"
            return 0
        ;;
        "install-ssh")
            install_ssh
            print_prompt "$user"
            return 0
        ;;
        "install-gui")
            install_gui
            print_prompt "$user"
            return 0
        ;;
        "reinstall-gui")
            reinstall_gui
            print_prompt "$user"
            return 0
        ;;
        "start-vnc")
            start_vnc
            print_prompt "$user"
            return 0
        ;;
        "stop-vnc")
            stop_vnc
            print_prompt "$user"
            return 0
        ;;
        "start-novnc")
            start_novnc
            print_prompt "$user"
            return 0
        ;;
        "stop-novnc")
            stop_novnc
            print_prompt "$user"
            return 0
        ;;
        "start-tunnel")
            start_tunnel
            print_prompt "$user"
            return 0
        ;;
        "stop-tunnel")
            stop_tunnel
            print_prompt "$user"
            return 0
        ;;
        "gui-status")
            gui_status
            print_prompt "$user"
            return 0
        ;;
        "status")
            show_system_status
            print_prompt "$user"
            return 0
        ;;
        "backup")
            create_backup
            print_prompt "$user"
            return 0
        ;;
        "restore")
            log "ERROR" "No backup file specified. Usage: restore <backup_file>" "$RED"
            print_prompt "$user"
            return 0
        ;;
        "restore "*)
            backup_file=$(echo "$cmd" | cut -d' ' -f2-)
            restore_backup "$backup_file"
            print_prompt "$user"
            return 0
        ;;
        *)
            eval "$cmd"
            print_prompt "$user"
            return 0
        ;;
    esac
}

# Function to run command prompt for a specific user
run_prompt() {
    user="$1"
    read -r cmd
    
    execute_command "$cmd" "$user"
    print_prompt "$user"
}

# Create history file if it doesn't exist
touch "$HISTORY_FILE"

# Set up trap for clean exit
trap cleanup INT TERM

ensure_shell_prompt
show_first_boot_credentials
start_ssh_server

# Print initial command
printf "${GREEN}root@${HOSTNAME}${NC}:${RED}$(get_formatted_dir)${NC}#\n"

# Execute autorun.sh
sh "/autorun.sh"

# Main command loop
while true; do
    run_prompt "user"
done