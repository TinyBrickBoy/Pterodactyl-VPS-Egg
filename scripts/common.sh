#!/bin/sh

# Common color definitions
PURPLE='\033[0;35m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Common logger function
log() {
    level=$1
    message=$2
    color=$3
    
    if [ -z "$color" ]; then
        color="$NC"
    fi
    
    printf "${color}[$level]${NC} $message\n"
}

# Function to detect architecture
detect_architecture() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            echo "amd64"
        ;;
        aarch64)
            echo "arm64"
        ;;
        riscv64)
            echo "riscv64"
        ;;
        *)
            log "ERROR" "Unsupported CPU architecture: $ARCH" "$RED" >&2
            return 1
        ;;
    esac
}

# Function to print the main banner
print_main_banner() {
    printf "\033c"
    printf "${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║                                                                               ║${NC}\n"
    printf "${CYAN}║            ${PURPLE}${BOLD}██╗   ██╗██████╗ ███████╗    ███████╗ ██████╗  ██████╗${CYAN}             ║${NC}\n"
    printf "${CYAN}║            ${PURPLE}${BOLD}██║   ██║██╔══██╗██╔════╝    ██╔════╝██╔════╝ ██╔════╝${CYAN}             ║${NC}\n"
    printf "${CYAN}║            ${PURPLE}${BOLD}██║   ██║██████╔╝███████╗    █████╗  ██║  ███╗██║  ███╗${CYAN}            ║${NC}\n"
    printf "${CYAN}║            ${PURPLE}${BOLD}╚██╗ ██╔╝██╔═══╝ ╚════██║    ██╔══╝  ██║   ██║██║   ██║${CYAN}            ║${NC}\n"
    printf "${CYAN}║             ${PURPLE}${BOLD}╚████╔╝ ██║     ███████║    ███████╗╚██████╔╝╚██████╔╝${CYAN}            ║${NC}\n"
    printf "${CYAN}║              ${PURPLE}${BOLD}╚═══╝  ╚═╝     ╚══════╝    ╚══════╝ ╚═════╝  ╚═════╝${CYAN}             ║${NC}\n"
    printf "${CYAN}║                                                                               ║${NC}\n"
    printf "${CYAN}║                      ${GREEN}✨  Lightweight • Fast • Reliable ✨${CYAN}                       ║${NC}\n"
    printf "${CYAN}║                                                                               ║${NC}\n"
    printf "${CYAN}║                           ${DIM}© 2021 - $(date +%Y) ${PURPLE}@ysdragon${CYAN}                             ║${NC}\n"
    printf "${CYAN}║                                                                               ║${NC}\n"
    printf "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
}

