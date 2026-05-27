#!/bin/sh
# systemctl compatibility shim for PRoot/container environments.
# Translates systemctl commands to SysV init.d or direct process management,
# since systemd requires being PID 1 and cannot operate inside PRoot.

# If a real systemd bus is reachable, delegate to the real binary.
if [ -d /run/systemd/system ] && [ -S /run/systemd/private/io.systemd.Manager ]; then
    exec /bin/systemctl.real "$@"
fi

# Strip .service (and other unit suffixes) from a name.
svc_name() {
    echo "$1" | sed 's/\.\(service\|socket\|target\|timer\|mount\|path\)$//'
}

# Locate an executable init.d script for a service.
find_initd() {
    local svc
    svc=$(svc_name "$1")
    for p in "/etc/init.d/$svc" "/etc/rc.d/init.d/$svc"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Check whether a named process is currently running.
is_running() {
    local svc
    svc=$(svc_name "$1")
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x "$svc" >/dev/null 2>&1
        return $?
    fi
    for pid_dir in /proc/[0-9]*; do
        [ "$(cat "$pid_dir/comm" 2>/dev/null)" = "$svc" ] && return 0
    done
    return 1
}

# Run a service action via init.d or the 'service' helper.
run_svc() {
    local action svc initd
    action="$1"
    svc="$2"
    initd=$(find_initd "$svc") && { "$initd" "$action"; return $?; }
    if command -v service >/dev/null 2>&1; then
        service "$(svc_name "$svc")" "$action"
        return $?
    fi
    echo "systemctl: cannot $action '$(svc_name "$svc")': no init script found" >&2
    return 5
}

CMD="$1"
[ $# -ge 1 ] && shift

case "$CMD" in
    start|stop)
        rc=0
        for svc in "$@"; do
            run_svc "$CMD" "$svc" || rc=$?
        done
        exit $rc
        ;;

    restart|reload|force-reload)
        rc=0
        for svc in "$@"; do
            initd=$(find_initd "$svc")
            if [ -n "$initd" ]; then
                "$initd" "$CMD" 2>/dev/null || "$initd" restart
            elif command -v service >/dev/null 2>&1; then
                service "$(svc_name "$svc")" "$CMD" 2>/dev/null \
                    || service "$(svc_name "$svc")" restart
            else
                echo "systemctl: cannot $CMD '$(svc_name "$svc")': no init script found" >&2
                rc=5
            fi
        done
        exit $rc
        ;;

    status)
        rc=0
        for svc in "$@"; do
            name=$(svc_name "$svc")
            initd=$(find_initd "$svc")
            if [ -n "$initd" ]; then
                "$initd" status; rc=$?
            elif command -v service >/dev/null 2>&1; then
                service "$name" status; rc=$?
            elif is_running "$svc"; then
                printf "● %s.service\n   Active: active (running)\n" "$name"
            else
                printf "● %s.service\n   Active: inactive (dead)\n" "$name"
                rc=3
            fi
        done
        exit $rc
        ;;

    enable)
        for svc in "$@"; do
            name=$(svc_name "$svc")
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$name" defaults
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig "$name" on
            else
                echo "systemctl: enable not supported (no update-rc.d/chkconfig)" >&2
            fi
        done
        ;;

    disable)
        for svc in "$@"; do
            name=$(svc_name "$svc")
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$name" disable
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig "$name" off
            else
                echo "systemctl: disable not supported (no update-rc.d/chkconfig)" >&2
            fi
        done
        ;;

    is-active)
        rc=0
        for svc in "$@"; do
            if is_running "$svc"; then
                echo "active"
            else
                echo "inactive"
                rc=1
            fi
        done
        exit $rc
        ;;

    is-enabled)
        rc=0
        for svc in "$@"; do
            name=$(svc_name "$svc")
            if ls /etc/rc2.d/S*"$name" >/dev/null 2>&1 \
                || ls /etc/rc3.d/S*"$name" >/dev/null 2>&1; then
                echo "enabled"
            else
                echo "disabled"
                rc=1
            fi
        done
        exit $rc
        ;;

    daemon-reload|daemon-reexec)
        # No-op in a non-systemd environment — tools call this routinely.
        ;;

    list-units|list-unit-files)
        printf "%-36s %-6s %-8s %-8s %s\n" "UNIT" "LOAD" "ACTIVE" "SUB" "DESCRIPTION"
        for f in /etc/init.d/*; do
            [ -x "$f" ] || continue
            name=$(basename "$f")
            if is_running "$name"; then
                printf "%-36s %-6s %-8s %-8s %s\n" \
                    "$name.service" "loaded" "active" "running" "$name"
            else
                printf "%-36s %-6s %-8s %-8s %s\n" \
                    "$name.service" "loaded" "inactive" "dead" "$name"
            fi
        done
        ;;

    ""|--help|-h)
        echo "Usage: systemctl COMMAND [SERVICE...]"
        echo ""
        echo "Supported commands:"
        echo "  start, stop, restart, reload, force-reload"
        echo "  status, enable, disable"
        echo "  is-active, is-enabled"
        echo "  daemon-reload, list-units, list-unit-files"
        echo ""
        echo "Note: running inside PRoot — systemd is not available."
        ;;

    *)
        echo "systemctl: command '$CMD' is not supported in this PRoot environment" >&2
        exit 1
        ;;
esac
