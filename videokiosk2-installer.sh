#!/bin/bash
set -e

SERVICE_NAME="videokiosk2.service"
WRAPPER_PATH="/home/pi/vlc-wrapper.sh"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

SCHEDULER_SERVICE_NAME="videokiosk2-scheduler.service"
SCHEDULER_SERVICE_PATH="/etc/systemd/system/$SCHEDULER_SERVICE_NAME"
SCHEDULER_SCRIPT_PATH="/home/pi/videokiosk2-restart-scheduler.sh"

GPIO_SERVICE_NAME="videokiosk2-gpio-restart.service"
GPIO_SERVICE_PATH="/etc/systemd/system/$GPIO_SERVICE_NAME"
GPIO_SCRIPT_PATH="/home/pi/videokiosk2-gpio-restart.sh"
GPIO_SUDOERS_PATH="/etc/sudoers.d/videokiosk2-gpio-restart"
DEFAULT_GPIO_PIN=17
INSTALL_GPIO=0
GPIO_PIN=$DEFAULT_GPIO_PIN

DEFAULT_URL="http://your-stream-server:8086/2.ts"
DEFAULT_BROWSER_URL="http://your-calendar-server:8000"
DEFAULT_SCHEDULE_URL="http://your-calendar-server:8000/api/service-restart-schedule"
DEFAULT_RESTART_DELAY_MINUTES=0

load_existing_config() {
    local conf_dir
    conf_dir="$(dirname "$WRAPPER_PATH")"
    local conf_path="$conf_dir/local.conf"

    if [[ -f "$conf_path" ]]; then
        echo "Found existing config at $conf_path -- loading as defaults."
        source "$conf_path"
        # Strip trailing \r in case the file has Windows line endings
        STREAM_URL="${STREAM_URL%$'\r'}"
        BROWSER_URL="${BROWSER_URL%$'\r'}"
        [[ -n "${STREAM_URL:-}" ]] && DEFAULT_URL="$STREAM_URL"
        [[ -n "${BROWSER_URL:-}" ]] && DEFAULT_BROWSER_URL="$BROWSER_URL"
        [[ -n "${BROWSER_URL:-}" ]] && DEFAULT_SCHEDULE_URL="${BROWSER_URL}/api/service-restart-schedule"
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This installer must be run as root (use sudo)." >&2
        exit 1
    fi
}

install_packages() {
    local required=(vlc midori x11-apps curl python3 cec-utils)
    if (( INSTALL_GPIO == 1 )); then
        required+=(gpiod)
    fi
    local missing=()
    local pkg

    for pkg in "${required[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All prerequisites already installed; skipping apt update/install."
        return
    fi

    echo "Missing packages detected: ${missing[*]}"
    echo "Updating package lists and installing missing prerequisites..."
    apt update -y
    apt install -y "${missing[@]}"
}

prompt_url() {
    echo
    read -r -p "Enter the video feed URL [default: $DEFAULT_URL]: " FEED_URL
    FEED_URL="${FEED_URL:-$DEFAULT_URL}"

    if [[ ! "$FEED_URL" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "Invalid URL format: $FEED_URL" >&2
        exit 1
    fi

    echo "Using video feed URL: $FEED_URL"
}

prompt_schedule_url() {
    echo
    read -r -p "Enter restart schedule API URL [default: $DEFAULT_SCHEDULE_URL]: " SCHEDULE_URL
    SCHEDULE_URL="${SCHEDULE_URL:-$DEFAULT_SCHEDULE_URL}"

    if [[ ! "$SCHEDULE_URL" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "Invalid URL format: $SCHEDULE_URL" >&2
        exit 1
    fi

    echo "Using restart schedule API URL: $SCHEDULE_URL"
}

prompt_browser_url() {
    echo
    read -r -p "Enter failover browser URL [default: $DEFAULT_BROWSER_URL]: " BROWSER_URL
    BROWSER_URL="${BROWSER_URL:-$DEFAULT_BROWSER_URL}"

    if [[ ! "$BROWSER_URL" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "Invalid URL format: $BROWSER_URL" >&2
        exit 1
    fi

    echo "Using failover browser URL: $BROWSER_URL"
}

prompt_gpio_button() {
    echo
    read -r -p "Install GPIO button restart monitor? (y/N): " gpio_ans
    if [[ "$gpio_ans" == "y" || "$gpio_ans" == "Y" ]]; then
        INSTALL_GPIO=1
        read -r -p "GPIO pin number [default: $DEFAULT_GPIO_PIN]: " gpio_pin_input
        GPIO_PIN="${gpio_pin_input:-$DEFAULT_GPIO_PIN}"
        if [[ ! "$GPIO_PIN" =~ ^[0-9]+$ ]] || (( GPIO_PIN < 2 || GPIO_PIN > 27 )); then
            echo "Invalid GPIO pin: $GPIO_PIN (must be 2-27)" >&2
            exit 1
        fi
        echo "GPIO restart button will use pin $GPIO_PIN"
    else
        echo "Skipping GPIO button monitor."
    fi
}

prompt_restart_delay_minutes() {
    echo
    read -r -p "Enter restart delay in minutes [default: ${DEFAULT_RESTART_DELAY_MINUTES}] (press Enter or 0 for no delay): " RESTART_DELAY_MINUTES
    RESTART_DELAY_MINUTES="${RESTART_DELAY_MINUTES:-$DEFAULT_RESTART_DELAY_MINUTES}"

    if [[ ! "$RESTART_DELAY_MINUTES" =~ ^[0-9]+$ ]]; then
        echo "Restart delay must be a non-negative whole number of minutes." >&2
        exit 1
    fi

    if (( RESTART_DELAY_MINUTES == 0 )); then
        echo "Restart delay disabled (no delay)."
    else
        echo "Using restart delay: ${RESTART_DELAY_MINUTES} minute(s)."
    fi
}

stop_service_if_running() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "Stopping existing $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
    fi

    if systemctl is-active --quiet "$SCHEDULER_SERVICE_NAME"; then
        echo "Stopping existing $SCHEDULER_SERVICE_NAME..."
        systemctl stop "$SCHEDULER_SERVICE_NAME"
    fi

    if systemctl is-active --quiet "$GPIO_SERVICE_NAME"; then
        echo "Stopping existing $GPIO_SERVICE_NAME..."
        systemctl stop "$GPIO_SERVICE_NAME"
    fi
}

write_wrapper() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<'EOF'
#!/bin/bash

STREAM_URL="http://your-stream-server:8086/2.ts"
BROWSER_URL="http://your-calendar-server:8000"

# Source local overrides if present (created by installer or manually)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/local.conf" ]]; then
    # shellcheck source=local.conf
    source "$SCRIPT_DIR/local.conf"
fi

THRESHOLD=5
STARTUP_GRACE=20
CHECK_INTERVAL=5

CPU_IDLE_THRESHOLD=2
PREV_CPU=20

FREEZE_COUNT=0
CPU_LOW_COUNT=0
CPU_ZERO_COUNT=0

LAST_FRAME_HASH=""

STANDBY_MARKER="/tmp/videokiosk2-midori-start"

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local line="$ts videokiosk2.vlc-wrapper $level $msg"
    echo "$line"
    logger -t vlc-wrapper "$line"
}

launch_midori() {
    if ! pgrep -x midori >/dev/null; then
        log "INFO" "Launching Midori failover browser"
        midori -e SingleWindow -e Fullscreen "$BROWSER_URL" >/dev/null 2>&1
    else
        log "INFO" "Midori already running"
    fi
}

check_standby_timer() {
    if [[ -f "$STANDBY_MARKER" ]]; then
        local marker_epoch
        marker_epoch=$(cat "$STANDBY_MARKER" 2>/dev/null)
        if [[ "$marker_epoch" =~ ^[0-9]+$ ]]; then
            local now_epoch elapsed
            now_epoch=$(date +%s)
            elapsed=$(( now_epoch - marker_epoch ))
            if (( elapsed >= 3600 )); then
                log "INFO" "Midori failover active for ${elapsed}s (>= 1 hour)"
                rm -f "$STANDBY_MARKER"
                if [[ -x "/home/pi/tvStandby.sh" ]]; then
                    log "INFO" "Running tvStandby.sh"
                    /home/pi/tvStandby.sh || log "WARN" "tvStandby.sh exited with code $?"
                fi
            fi
        fi
    fi
}

mark_midori_start() {
    if [[ ! -f "$STANDBY_MARKER" ]]; then
        date +%s > "$STANDBY_MARKER"
        log "INFO" "Standby timer started (1 hour)"
    fi
}

clear_standby_timer() {
    if [[ -f "$STANDBY_MARKER" ]]; then
        rm -f "$STANDBY_MARKER"
        log "INFO" "Standby timer cleared (VLC active)"
    fi
}

start_vlc() {
    log "INFO" "Starting VLC with URL: $STREAM_URL"

    vlc -f "$STREAM_URL" \
        --no-video-title-show \
        --quiet \
        >/dev/null 2>&1 &

    VLC_PID=$!

    log "INFO" "VLC started with PID $VLC_PID"
}

vlc_running() {
    kill -0 "$VLC_PID" 2>/dev/null
}

get_cpu_usage() {
    local pid=$1
    local cpu
    cpu=$(top -b -n 1 -p "$pid" | awk -v pid="$pid" '$1 == pid {print int($9)}')
    [[ -z "$cpu" ]] && echo 0 || echo "$cpu"
}

sleep 20
check_standby_timer
start_vlc
sleep 5

if ! vlc_running; then
    log "ERROR" "VLC failed to start"
    launch_midori
    mark_midori_start
    exit 0
fi

clear_standby_timer
log "INFO" "VLC appears to be running. Entering monitoring loop."

START_TIME=$(date +%s)

while vlc_running; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))

    if (( ELAPSED <= STARTUP_GRACE )); then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    FRAME_HASH=$(xwd -silent -root 2>/dev/null | md5sum | awk '{print $1}')

    if [[ "$FRAME_HASH" == "$LAST_FRAME_HASH" ]]; then
        ((FREEZE_COUNT++))
        log "WARN" "Freeze incremented: $FREEZE_COUNT of $THRESHOLD"
    else
        (( FREEZE_COUNT > 0 )) && log "INFO" "Freeze counter reset"
        FREEZE_COUNT=0
    fi

    LAST_FRAME_HASH="$FRAME_HASH"

    CURR_CPU=$(get_cpu_usage "$VLC_PID")
    AVG_CPU=$(( (CURR_CPU + PREV_CPU) / 2 ))
    PREV_CPU=$CURR_CPU

    if (( AVG_CPU < CPU_IDLE_THRESHOLD )); then
        ((CPU_LOW_COUNT++))
        log "WARN" "Low CPU incremented: $CPU_LOW_COUNT of $THRESHOLD"
    else
        (( CPU_LOW_COUNT > 0 )) && log "INFO" "Low CPU counter reset"
        CPU_LOW_COUNT=0
    fi

    if (( CURR_CPU == 0 )); then
        ((CPU_ZERO_COUNT++))
        log "WARN" "Zero CPU incremented: $CPU_ZERO_COUNT of $THRESHOLD"
    else
        (( CPU_ZERO_COUNT > 0 )) && log "INFO" "Zero CPU counter reset"
        CPU_ZERO_COUNT=0
    fi

    if (( FREEZE_COUNT >= THRESHOLD && CPU_LOW_COUNT >= THRESHOLD )); then
        log "ERROR" "Freeze + low CPU detected. Triggering failover."
        kill "$VLC_PID" 2>/dev/null
        launch_midori
        mark_midori_start
        exit 0
    fi

    if (( CPU_ZERO_COUNT >= THRESHOLD )); then
        log "ERROR" "CPU stuck at zero. VLC likely not decoding. Triggering failover."
        kill "$VLC_PID" 2>/dev/null
        launch_midori
        mark_midori_start
        exit 0
    fi

    sleep "$CHECK_INTERVAL"
done

log "WARN" "VLC exited unexpectedly. Launching Midori."
launch_midori
mark_midori_start
exit 0
EOF

    if [[ -f "$WRAPPER_PATH" ]]; then
        if diff -u "$WRAPPER_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$WRAPPER_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $WRAPPER_PATH found. Showing diff:"
        diff -u "$WRAPPER_PATH" "$tmpfile" || true
        read -r -p "Overwrite $WRAPPER_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing wrapper."
            rm -f "$tmpfile"
            return
        fi
        cp "$WRAPPER_PATH" "$WRAPPER_PATH.bak"
    fi

    mv "$tmpfile" "$WRAPPER_PATH"
    chown pi:pi "$WRAPPER_PATH"
    chmod 755 "$WRAPPER_PATH"
    echo "Installed wrapper at $WRAPPER_PATH"
}

write_local_conf() {
    local conf_dir
    conf_dir="$(dirname "$WRAPPER_PATH")"
    local conf_path="$conf_dir/local.conf"
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<LOCALEOF
# videokiosk2 local configuration — generated by installer
STREAM_URL="$FEED_URL"
BROWSER_URL="$BROWSER_URL"
LOCALEOF

    if [[ -f "$conf_path" ]]; then
        if diff -u "$conf_path" "$tmpfile" >/dev/null 2>&1; then
            echo "$conf_path is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $conf_path found. Showing diff:"
        diff -u "$conf_path" "$tmpfile" || true
        read -r -p "Overwrite $conf_path? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing local.conf."
            rm -f "$tmpfile"
            return
        fi
        cp "$conf_path" "$conf_path.bak"
    fi

    mv "$tmpfile" "$conf_path"
    chown pi:pi "$conf_path"
    chmod 644 "$conf_path"
    echo "Installed local config at $conf_path"
}

write_scheduler_script() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<'EOF'
#!/bin/bash
set -euo pipefail

SCHEDULE_URL="__SCHEDULE_URL__"
SERVICE_NAME="videokiosk2.service"
STATE_FILE="/var/lib/videokiosk2/restart-trigger.id"
RESTART_DELAY_MINUTES=__RESTART_DELAY_MINUTES__
POLL_INTERVAL=30
HEARTBEAT_INTERVAL=600

mkdir -p /var/lib/videokiosk2

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local line="$ts videokiosk2.scheduler $level $msg"
    echo "$line"
    logger -t videokiosk2-scheduler "$line"
}

last_trigger_id=""
if [[ -f "$STATE_FILE" ]]; then
    last_trigger_id=$(cat "$STATE_FILE" 2>/dev/null || true)
fi

last_announced_trigger=""
startup_announcement_done=0
last_heartbeat_epoch=0
last_parse_error_epoch=0
log "INFO" "Scheduler started; polling ${SCHEDULE_URL} every ${POLL_INTERVAL}s"

while true; do
    payload=""
    if payload=$(curl -fsS --connect-timeout 20 --max-time 20 "$SCHEDULE_URL" 2>/dev/null); then
        :
    else
        curl_exit_code=$?
        if [[ "$curl_exit_code" -eq 28 ]]; then
            log "WARN" "Timed out fetching restart schedule; retrying in ${POLL_INTERVAL}s"
        elif [[ "$curl_exit_code" -eq 22 ]]; then
            log "WARN" "Restart schedule API returned non-2xx HTTP status; retrying in ${POLL_INTERVAL}s"
        else
            log "WARN" "Unable to fetch restart schedule (curl exit ${curl_exit_code}); retrying in ${POLL_INTERVAL}s"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    parsed=$(SCHEDULE_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone

raw = os.environ.get("SCHEDULE_PAYLOAD", "").strip()
if not raw:
    print("")
    print("")
    print("")
    raise SystemExit(0)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("")
    print("")
    print("")
    raise SystemExit(0)

restart = data.get("next_restart") or {}
trigger_id = restart.get("trigger_id", "")
restart_at = restart.get("restart_at", "")
if not trigger_id or not restart_at:
    print("")
    print("")
    print("")
    raise SystemExit(0)

try:
    dt = datetime.fromisoformat(restart_at)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    epoch = int(dt.timestamp())
except ValueError:
    print("")
    print("")
    print("")
    raise SystemExit(0)

print(trigger_id)
print(epoch)
print(restart.get('source_event_summary', ''))
PY
)

        mapfile -t parsed_lines <<< "$parsed"
        trigger_id="${parsed_lines[0]:-}"
        restart_epoch="${parsed_lines[1]:-}"
        source_summary="${parsed_lines[2]:-}"

        if [[ -z "$trigger_id" || -z "$restart_epoch" || ! "$restart_epoch" =~ ^[0-9]+$ ]]; then
        now_epoch=$(date +%s)
        if (( startup_announcement_done == 0 )); then
            log "INFO" "No upcoming restart currently scheduled"
            startup_announcement_done=1
            last_announced_trigger="__none__"
        elif (( now_epoch - last_parse_error_epoch >= 300 )); then
            log "WARN" "Schedule payload did not contain a valid restart trigger"
            last_parse_error_epoch=$now_epoch
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    now_epoch=$(date +%s)
    if (( startup_announcement_done == 0 )); then
        log "INFO" "Next scheduled restart trigger=${trigger_id} restart_epoch=${restart_epoch} source=${source_summary:-unknown}"
        startup_announcement_done=1
        last_announced_trigger="$trigger_id"
    elif [[ "$trigger_id" != "$last_announced_trigger" ]]; then
        log "INFO" "Restart schedule changed trigger=${trigger_id} restart_epoch=${restart_epoch} source=${source_summary:-unknown}"
        last_announced_trigger="$trigger_id"
    elif (( now_epoch - last_heartbeat_epoch >= HEARTBEAT_INTERVAL )); then
        log "INFO" "Scheduler heartbeat next_trigger=${trigger_id} restart_epoch=${restart_epoch}"
        last_heartbeat_epoch=$now_epoch
    fi

    if (( now_epoch >= restart_epoch )); then
        if [[ "$trigger_id" == "$last_trigger_id" ]]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        log "INFO" "Triggering restart for Services event: ${source_summary:-unknown}"
        if (( RESTART_DELAY_MINUTES > 0 )); then
            delay_seconds=$((RESTART_DELAY_MINUTES * 60))
            log "INFO" "Delaying restart by ${RESTART_DELAY_MINUTES} minute(s) (${delay_seconds}s)"
            delay_remaining=$delay_seconds
            delay_superseded=0
            while (( delay_remaining > 0 )); do
                sleep_chunk=$(( delay_remaining < POLL_INTERVAL ? delay_remaining : POLL_INTERVAL ))
                sleep "$sleep_chunk"
                delay_remaining=$((delay_remaining - sleep_chunk))

                check_payload=""
                if check_payload=$(curl -fsS --connect-timeout 10 --max-time 10 "$SCHEDULE_URL" 2>/dev/null); then
                    check_id=$(SCHEDULE_PAYLOAD="$check_payload" python3 -c '
import json, os, sys
raw = os.environ.get("SCHEDULE_PAYLOAD", "").strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
restart = data.get("next_restart") or {}
tid = restart.get("trigger_id", "")
if tid:
    print(tid)
' 2>/dev/null) || true
                    if [[ -n "$check_id" && "$check_id" != "$trigger_id" ]]; then
                        log "INFO" "Delay superseded: new trigger=${check_id} (was ${trigger_id}); aborting current delay"
                        delay_superseded=1
                        break
                    fi
                fi
            done
            if (( delay_superseded == 1 )); then
                continue
            fi
        fi
        if systemctl restart "$SERVICE_NAME"; then
            echo "$trigger_id" > "$STATE_FILE"
            last_trigger_id="$trigger_id"
            log "INFO" "Restart completed for trigger $trigger_id"
            if [[ -x "/home/pi/tvOn.sh" ]]; then
                log "INFO" "Running tvOn.sh"
                /home/pi/tvOn.sh || log "WARN" "tvOn.sh exited with code $?"
            fi
        else
            log "ERROR" "Restart command failed for trigger $trigger_id"
        fi
    fi

    sleep "$POLL_INTERVAL"
done
EOF

    sed -i "s|__SCHEDULE_URL__|$SCHEDULE_URL|g" "$tmpfile"
    sed -i "s|__RESTART_DELAY_MINUTES__|$RESTART_DELAY_MINUTES|g" "$tmpfile"

    if [[ -f "$SCHEDULER_SCRIPT_PATH" ]]; then
        if diff -u "$SCHEDULER_SCRIPT_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$SCHEDULER_SCRIPT_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $SCHEDULER_SCRIPT_PATH found. Showing diff:"
        diff -u "$SCHEDULER_SCRIPT_PATH" "$tmpfile" || true
        read -r -p "Overwrite $SCHEDULER_SCRIPT_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing scheduler script."
            rm -f "$tmpfile"
            return
        fi
        cp "$SCHEDULER_SCRIPT_PATH" "$SCHEDULER_SCRIPT_PATH.bak"
    fi

    mv "$tmpfile" "$SCHEDULER_SCRIPT_PATH"
    chown root:root "$SCHEDULER_SCRIPT_PATH"
    chmod 755 "$SCHEDULER_SCRIPT_PATH"
    echo "Installed scheduler script at $SCHEDULER_SCRIPT_PATH"
}

write_service() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<EOF
[Unit]
Description=VLC Kiosk Wrapper (videokiosk2)
After=display-manager.service

[Service]
Type=simple
ExecStart=$WRAPPER_PATH
Restart=always
RestartSec=3

KillMode=mixed
KillSignal=SIGTERM
SendSIGKILL=yes
TimeoutStopSec=5

ExecStop=/usr/bin/pkill -TERM -f vlc-wrapper.sh
ExecStopPost=/usr/bin/pkill -TERM vlc
ExecStopPost=/usr/bin/pkill -TERM midori

User=pi
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority

[Install]
WantedBy=multi-user.target
EOF

    if [[ -f "$SERVICE_PATH" ]]; then
        if diff -u "$SERVICE_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$SERVICE_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $SERVICE_PATH found. Showing diff:"
        diff -u "$SERVICE_PATH" "$tmpfile" || true
        read -r -p "Overwrite $SERVICE_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing service file."
            rm -f "$tmpfile"
            return
        fi
        cp "$SERVICE_PATH" "$SERVICE_PATH.bak"
    fi

    mv "$tmpfile" "$SERVICE_PATH"
    chmod 644 "$SERVICE_PATH"
    echo "Installed service at $SERVICE_PATH"

    systemctl daemon-reload
}

write_scheduler_service() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<EOF
[Unit]
Description=videokiosk2 Service Restart Scheduler
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCHEDULER_SCRIPT_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    if [[ -f "$SCHEDULER_SERVICE_PATH" ]]; then
        if diff -u "$SCHEDULER_SERVICE_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$SCHEDULER_SERVICE_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $SCHEDULER_SERVICE_PATH found. Showing diff:"
        diff -u "$SCHEDULER_SERVICE_PATH" "$tmpfile" || true
        read -r -p "Overwrite $SCHEDULER_SERVICE_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing scheduler service file."
            rm -f "$tmpfile"
            return
        fi
        cp "$SCHEDULER_SERVICE_PATH" "$SCHEDULER_SERVICE_PATH.bak"
    fi

    mv "$tmpfile" "$SCHEDULER_SERVICE_PATH"
    chmod 644 "$SCHEDULER_SERVICE_PATH"
    echo "Installed scheduler service at $SCHEDULER_SERVICE_PATH"

    systemctl daemon-reload
}

write_gpio_script() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<'GPIOEOF'
#!/bin/bash
set -euo pipefail

GPIO_CHIP=gpiochip0
GPIO_PIN=__GPIO_PIN__
DEBOUNCE_SECONDS=30
SERVICE_NAME="videokiosk2.service"

log() {
    local level="$1"
    shift
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$ts videokiosk2.gpio-restart $level $*"
    logger -t videokiosk2-gpio "$level $*"
}

log "INFO" "Monitoring GPIO pin ${GPIO_PIN} on ${GPIO_CHIP} for button press (debounce=${DEBOUNCE_SECONDS}s)"

last_restart_epoch=0

while read -r _line; do
    now_epoch=$(date +%s)
    elapsed=$(( now_epoch - last_restart_epoch ))

    if (( elapsed < DEBOUNCE_SECONDS )); then
        log "INFO" "Button press ignored (${elapsed}s since last restart, debounce=${DEBOUNCE_SECONDS}s)"
        continue
    fi

    log "INFO" "Button press detected on GPIO ${GPIO_PIN} — restarting ${SERVICE_NAME}"
    if sudo systemctl restart "$SERVICE_NAME"; then
        last_restart_epoch=$(date +%s)
        log "INFO" "Restart completed successfully"
        log "INFO" "Sending CEC power-on and active-source commands"
        timeout 5 bash -c 'echo "on 0" | cec-client -s -d 1' 2>/dev/null || log "WARN" "CEC power-on timed out or failed"
        sleep 2
        timeout 5 bash -c 'echo "as" | cec-client -s -d 1' 2>/dev/null || log "WARN" "CEC active-source timed out or failed"
    else
        log "ERROR" "Restart command failed"
    fi
done < <(gpiomon --chip "$GPIO_CHIP" --falling-edge --bias=pull-up "$GPIO_PIN")
GPIOEOF

    sed -i "s|__GPIO_PIN__|$GPIO_PIN|g" "$tmpfile"

    if [[ -f "$GPIO_SCRIPT_PATH" ]]; then
        if diff -u "$GPIO_SCRIPT_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$GPIO_SCRIPT_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $GPIO_SCRIPT_PATH found. Showing diff:"
        diff -u "$GPIO_SCRIPT_PATH" "$tmpfile" || true
        read -r -p "Overwrite $GPIO_SCRIPT_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing GPIO restart script."
            rm -f "$tmpfile"
            return
        fi
        cp "$GPIO_SCRIPT_PATH" "$GPIO_SCRIPT_PATH.bak"
    fi

    mv "$tmpfile" "$GPIO_SCRIPT_PATH"
    chown pi:pi "$GPIO_SCRIPT_PATH"
    chmod 755 "$GPIO_SCRIPT_PATH"
    echo "Installed GPIO restart script at $GPIO_SCRIPT_PATH"
}

write_gpio_service() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<EOF
[Unit]
Description=videokiosk2 GPIO Button Restart Monitor
After=multi-user.target

[Service]
Type=simple
ExecStart=$GPIO_SCRIPT_PATH
Restart=always
RestartSec=5
User=pi

[Install]
WantedBy=multi-user.target
EOF

    if [[ -f "$GPIO_SERVICE_PATH" ]]; then
        if diff -u "$GPIO_SERVICE_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$GPIO_SERVICE_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $GPIO_SERVICE_PATH found. Showing diff:"
        diff -u "$GPIO_SERVICE_PATH" "$tmpfile" || true
        read -r -p "Overwrite $GPIO_SERVICE_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing GPIO service file."
            rm -f "$tmpfile"
            return
        fi
        cp "$GPIO_SERVICE_PATH" "$GPIO_SERVICE_PATH.bak"
    fi

    mv "$tmpfile" "$GPIO_SERVICE_PATH"
    chmod 644 "$GPIO_SERVICE_PATH"
    echo "Installed GPIO service at $GPIO_SERVICE_PATH"

    systemctl daemon-reload
}

write_gpio_polkit_rule() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" <<'SUDOERSEOF'
pi ALL=(root) NOPASSWD: /usr/bin/systemctl restart videokiosk2.service
SUDOERSEOF

    if [[ -f "$GPIO_SUDOERS_PATH" ]]; then
        if diff -u "$GPIO_SUDOERS_PATH" "$tmpfile" >/dev/null 2>&1; then
            echo "$GPIO_SUDOERS_PATH is already up to date."
            rm -f "$tmpfile"
            return
        fi
        echo
        echo "Existing $GPIO_SUDOERS_PATH found. Showing diff:"
        diff -u "$GPIO_SUDOERS_PATH" "$tmpfile" || true
        read -r -p "Overwrite $GPIO_SUDOERS_PATH? (y/N): " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            echo "Keeping existing sudoers rule."
            rm -f "$tmpfile"
            return
        fi
    fi

    if ! visudo -cf "$tmpfile" >/dev/null 2>&1; then
        echo "ERROR: sudoers syntax check failed. Skipping." >&2
        rm -f "$tmpfile"
        return
    fi

    mv "$tmpfile" "$GPIO_SUDOERS_PATH"
    chmod 440 "$GPIO_SUDOERS_PATH"
    echo "Installed sudoers rule at $GPIO_SUDOERS_PATH"
}

enable_and_start_service() {
    systemctl enable "$SERVICE_NAME"
    systemctl enable "$SCHEDULER_SERVICE_NAME"

    if pgrep Xorg >/dev/null 2>&1; then
        systemctl start "$SERVICE_NAME"
    fi

    systemctl start "$SCHEDULER_SERVICE_NAME"

    if (( INSTALL_GPIO == 1 )); then
        systemctl enable "$GPIO_SERVICE_NAME"
        systemctl start "$GPIO_SERVICE_NAME"
    fi
}

main() {
    require_root
    load_existing_config
    prompt_url
    prompt_browser_url
    prompt_schedule_url
    prompt_restart_delay_minutes
    prompt_gpio_button
    install_packages
    stop_service_if_running
    write_wrapper
    write_local_conf
    write_scheduler_script
    write_service
    write_scheduler_service
    if (( INSTALL_GPIO == 1 )); then
        write_gpio_script
        write_gpio_service
        write_gpio_polkit_rule
    fi
    enable_and_start_service
    echo "Installer completed."
}

main "$@"
