#!/bin/bash

STREAM_URL="http://your-stream-server:8086/0.ts"
BROWSER_URL="http://your-calendar-server:8000"

# Source generated configuration, retaining the legacy adjacent config fallback
# for manually run copies of this wrapper.
CONFIG_PATH="${VIDEOKIOSK2_CONFIG:-/etc/videokiosk2/local.conf}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$CONFIG_PATH" ]]; then
    # shellcheck source=/etc/videokiosk2/local.conf
    source "$CONFIG_PATH"
elif [[ -f "$SCRIPT_DIR/local.conf" ]]; then
    # shellcheck source=local.conf
    source "$SCRIPT_DIR/local.conf"
fi

THRESHOLD=5
STARTUP_GRACE=20
CHECK_INTERVAL=5
VLC_LOG="/tmp/videokiosk2-vlc.log"
MIDORI_LOG="/tmp/videokiosk2-midori.log"

CPU_IDLE_THRESHOLD=2
PREV_CPU=20

FREEZE_COUNT=0
CPU_LOW_COUNT=0
CPU_ZERO_COUNT=0

LAST_FRAME_HASH=""

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

resolve_x11_session() {
    local candidate runtime_dir
    local -a candidates=()

    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR="$runtime_dir"
    [[ -n "${XAUTHORITY:-}" ]] && candidates+=("$XAUTHORITY")
    candidates+=("$HOME/.Xauthority")

    while IFS= read -r -d '' candidate; do
        candidates+=("$candidate")
    done < <(
        find "$runtime_dir" "$HOME" -maxdepth 3 -type f \
            \( -name '.Xauthority' -o -name 'Xauthority' -o -name '.mutter-Xwaylandauth.*' \) \
            -print0 2>/dev/null
    )

    for candidate in "${candidates[@]}"; do
        if [[ -r "$candidate" ]] && DISPLAY="$DISPLAY" XAUTHORITY="$candidate" xset q >/dev/null 2>&1; then
            export XAUTHORITY="$candidate"
            log "INFO" "Using Xauthority file: $XAUTHORITY"
            return
        fi
    done

    log "ERROR" "Cannot authorize X11 display $DISPLAY; no usable Xauthority file was found"
    return 1
}

midori_command() {
    if command -v midori >/dev/null 2>&1; then
        command -v midori
    elif [[ -x /snap/bin/midori ]]; then
        printf '%s\n' /snap/bin/midori
    else
        return 1
    fi
}

launch_midori() {
    local midori_path midori_status
    if ! pgrep -x midori >/dev/null; then
        if ! midori_path=$(midori_command); then
            log "ERROR" "Midori failover is unavailable: install Midori and restart videokiosk2"
            return 1
        fi
        log "INFO" "Launching Midori failover browser with X11 backend"
        : >"$MIDORI_LOG"
        env -u WAYLAND_DISPLAY GDK_BACKEND=x11 "$midori_path" \
            -e SingleWindow -e Fullscreen "$BROWSER_URL" >>"$MIDORI_LOG" 2>&1
        midori_status=$?
        if (( midori_status != 0 )); then
            if [[ "$midori_path" == /snap/bin/* ]] && command -v snap >/dev/null 2>&1; then
                snap logs midori -n=50 >>"$MIDORI_LOG" 2>&1 || true
            fi
            log "ERROR" "Midori exited with status $midori_status; see $MIDORI_LOG"
            return 1
        fi
    else
        log "INFO" "Midori already running"
    fi
}

start_vlc() {
    log "INFO" "Starting VLC with URL: $STREAM_URL"

    env QT_QPA_PLATFORM=xcb vlc -f "$STREAM_URL" \
        --no-video-title-show \
        --no-interact \
        --no-qt-error-dialogs \
        --no-qt-privacy-ask \
        --no-qt-updates-notif \
        --no-qt-system-tray \
        --qt-notification=0 \
        --quiet \
        >>"$VLC_LOG" 2>&1 &

    VLC_PID=$!

    log "INFO" "VLC started with PID $VLC_PID (log: $VLC_LOG)"
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

resolve_x11_session || exit 1
sleep 20
start_vlc
sleep 5

if ! vlc_running; then
    log "ERROR" "VLC failed to start; see $VLC_LOG"
    launch_midori
    exit 0
fi

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
        exit 0
    fi

    if (( CPU_ZERO_COUNT >= THRESHOLD )); then
        log "ERROR" "CPU stuck at zero. VLC likely not decoding. Triggering failover."
        kill "$VLC_PID" 2>/dev/null
        launch_midori
        exit 0
    fi

    sleep "$CHECK_INTERVAL"
done

log "WARN" "VLC exited unexpectedly. Launching Midori."
launch_midori
exit 0
