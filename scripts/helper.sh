#!/bin/sh

ensure_run_script_exists() {
    if [ ! -f "$HOME/common.sh" ]; then
        cp /common.sh "$HOME/common.sh"
        chmod +x "$HOME/common.sh"
    fi

    if [ ! -f "$HOME/run.sh" ]; then
        cp /run.sh "$HOME/run.sh"
        chmod +x "$HOME/run.sh"
    fi
}

exec_proot() {
    /usr/local/bin/proot \
    --rootfs="${HOME}" \
    -0 -w "${HOME}" \
    -b /dev -b /sys -b /proc \
    --kill-on-exit \
    /bin/sh "/run.sh"
}

ensure_run_script_exists
exec_proot
