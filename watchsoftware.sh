#!/bin/bash
# =============================================================================
#  watchsoftware.sh
#  Watchdog daemon — keeps softwaretech running at all times.
#
#  Behaviour:
#   • Runs a singleton guard so only ONE copy ever runs.
#   • Every 15 seconds checks if softwaretech is alive.
#   • If not alive → starts it immediately.
#   • Writes its own PID and softwaretech's PID to PID files so the
#     deploy script and the cron layer can inspect running state.
#
#  Started by: deploy_softwaretech.sh, cron @reboot, user systemd, ~/.profile
#  Root NOT required.
# =============================================================================

INSTALL_DIR="$HOME/softwaretechreview"
SOFTWARE_BIN="$INSTALL_DIR/softwaretech"
CONFIG_FILE="$INSTALL_DIR/config.json"
WATCHDOG_PID_FILE="$INSTALL_DIR/watchdog.pid"
SOFTWARE_PID_FILE="$INSTALL_DIR/softwaretech.pid"
WATCHDOG_LOG="$INSTALL_DIR/watchdog.log"
SOFTWARE_LOG="$INSTALL_DIR/softwaretech.log"

CHECK_INTERVAL=15   # seconds between health checks

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    printf '[%s] WATCHDOG: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$WATCHDOG_LOG"
}

# ── Singleton guard ───────────────────────────────────────────────────────────
# Only one watchdog should run. If a live process already holds the PID file,
# this instance exits immediately. Uses kill -0 (never sends a real signal —
# just checks whether the PID exists), which is POSIX-standard and root-free.
is_integer() {
    printf '%s' "$1" | grep -q '^[0-9][0-9]*$'
}

if [ -f "$WATCHDOG_PID_FILE" ]; then
    existing_pid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    if is_integer "$existing_pid" \
       && [ "$existing_pid" != "$$" ] \
       && kill -0 "$existing_pid" 2>/dev/null; then
        # A live watchdog is already running — exit silently
        exit 0
    fi
fi

# Claim the PID file for this instance
mkdir -p "$INSTALL_DIR"
echo $$ > "$WATCHDOG_PID_FILE"

# ── Process check ─────────────────────────────────────────────────────────────
is_software_running() {
    # Method 1: PID file (most precise)
    if [ -f "$SOFTWARE_PID_FILE" ]; then
        local pid
        pid=$(cat "$SOFTWARE_PID_FILE" 2>/dev/null)
        if is_integer "$pid" && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Method 2: scan comm name in process table (reliable for native binaries)
    # 'ps -e -o comm' lists only process names — no shell noise, no grep matches
    ps -e -o comm 2>/dev/null | grep -q '^softwaretech$'
    return $?
}

# ── Start softwaretech ────────────────────────────────────────────────────────
start_software() {
    if [ ! -x "$SOFTWARE_BIN" ]; then
        log "ERROR: $SOFTWARE_BIN is missing or not executable — cannot start."
        return 1
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR: $CONFIG_FILE is missing — cannot start."
        return 1
    fi

    # cd to INSTALL_DIR so relative paths inside the binary resolve correctly
    cd "$INSTALL_DIR" || { log "ERROR: Cannot cd to $INSTALL_DIR"; return 1; }

    # Pure-bash daemonisation — no external tools needed (same pattern as deploy script)
    ./softwaretech --config config.json \
        >> "$SOFTWARE_LOG" 2>&1 </dev/null &
    local sw_pid=$!
    disown "$sw_pid" 2>/dev/null
    echo "$sw_pid" > "$SOFTWARE_PID_FILE"
    log "softwaretech started (PID $sw_pid)."
    return 0
}

# ── Watchdog loop ─────────────────────────────────────────────────────────────
log "=========================================="
log "Watchdog started (PID $$, interval: ${CHECK_INTERVAL}s)"
log "=========================================="

# Trap clean exit signals so the PID file is cleaned up
cleanup() {
    log "Watchdog received termination signal — exiting cleanly."
    rm -f "$WATCHDOG_PID_FILE"
    exit 0
}
trap cleanup TERM INT HUP

# Refresh own PID file on every iteration in case it was removed externally
while true; do
    echo $$ > "$WATCHDOG_PID_FILE"   # keep PID file current

    if ! is_software_running; then
        log "softwaretech is not running — attempting restart..."
        start_software
    fi

    sleep "$CHECK_INTERVAL"
done
