#!/bin/bash

STREAM_URL="http://your-stream-server:8086/0.ts"
BROWSER_URL="http://your-calendar-server:8000"
FAILOVER_BROWSER="${FAILOVER_BROWSER:-}"
BROWSER_SCALE="${BROWSER_SCALE:-1}"
AUDIO_OUTPUT="${AUDIO_OUTPUT:-auto}"
ALSA_AUDIO_DEVICE="${ALSA_AUDIO_DEVICE:-}"
STANDBY_AFTER_MINUTES="${STANDBY_AFTER_MINUTES:-60}"

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
PROCESS_STOP_TIMEOUT=5
VLC_LOG="/tmp/videokiosk2-vlc.log"
FAILOVER_LOG="/tmp/videokiosk2-failover.log"

CPU_IDLE_THRESHOLD=2
PREV_CPU=20

FREEZE_COUNT=0
CPU_LOW_COUNT=0
CPU_ZERO_COUNT=0

LAST_FRAME_HASH=""
STANDBY_TIMER_PID=""

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
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "$runtime_dir/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"
    fi
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

disable_screen_blanking() {
    xset s off || log "WARN" "Unable to disable the X11 screen saver"
    xset -dpms || log "WARN" "Unable to disable DPMS"
    xset s noblank || log "WARN" "Unable to disable X11 screen blanking"
}

validate_standby_duration() {
    if [[ ! "$STANDBY_AFTER_MINUTES" =~ ^[0-9]+$ ]]; then
        log "WARN" "Invalid STANDBY_AFTER_MINUTES '$STANDBY_AFTER_MINUTES'; using 60"
        STANDBY_AFTER_MINUTES=60
    fi
}

run_standby_actions() {
    if [[ -x "$HOME/tvStandby.sh" ]]; then
        log "INFO" "Running tvStandby.sh"
        "$HOME/tvStandby.sh" || log "WARN" "tvStandby.sh exited with code $?"
    fi
}

schedule_standby_actions() {
    validate_standby_duration
    (( STANDBY_AFTER_MINUTES > 0 )) || return

    (
        sleep "$((STANDBY_AFTER_MINUTES * 60))"
        log "INFO" "Failover browser active for ${STANDBY_AFTER_MINUTES} minutes; running standby actions"
        run_standby_actions
    ) &
    STANDBY_TIMER_PID=$!
}

cancel_standby_actions() {
    if [[ -n "$STANDBY_TIMER_PID" ]]; then
        kill "$STANDBY_TIMER_PID" 2>/dev/null || true
        STANDBY_TIMER_PID=""
    fi
}

detect_failover_browser() {
    local os_name pretty_name id_like

    if [[ -n "${FAILOVER_BROWSER:-}" ]]; then
        case "$FAILOVER_BROWSER" in
            midori|falkon) return ;;
            *)
                log "WARN" "Unknown FAILOVER_BROWSER '$FAILOVER_BROWSER'; falling back to OS detection"
                FAILOVER_BROWSER=""
                ;;
        esac
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        [[ "${ID:-}" == "raspbian" ]] && FAILOVER_BROWSER="midori"
        id_like="${ID_LIKE:-}"
        os_name="${NAME:-}"
        pretty_name="${PRETTY_NAME:-}"
        if [[ -z "${FAILOVER_BROWSER:-}" ]] && [[ "$id_like" == *raspbian* || "$os_name" == *"Raspberry Pi OS"* || "$pretty_name" == *"Raspberry Pi OS"* ]]; then
            FAILOVER_BROWSER="midori"
        fi
    fi

    FAILOVER_BROWSER="${FAILOVER_BROWSER:-falkon}"
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

falkon_command() {
    command -v falkon
}

validate_falkon_scale() {
    case "$BROWSER_SCALE" in
        1|1.25|1.5|1.75|2|2.5|3|4) ;;
        *)
            log "WARN" "Invalid BROWSER_SCALE '$BROWSER_SCALE'; using 1"
            BROWSER_SCALE=1
            ;;
    esac
}

ensure_falkon_fullscreen() {
    local attempt window_id window_state

    if ! command -v xprop >/dev/null 2>&1; then
        log "WARN" "Cannot verify Falkon fullscreen because xprop is unavailable"
        return
    fi

    for attempt in {1..10}; do
        window_id=$(xdotool search --onlyvisible --class falkon 2>/dev/null | tail -n 1)
        if [[ -n "$window_id" ]]; then
            xdotool windowactivate "$window_id" 2>/dev/null || xdotool windowraise "$window_id" 2>/dev/null || true
            window_state=$(xprop -id "$window_id" _NET_WM_STATE 2>/dev/null || true)
            if [[ "$window_state" != *"_NET_WM_STATE_FULLSCREEN"* ]]; then
                xdotool key --window "$window_id" F11
            fi
            xdotool windowraise "$window_id" 2>/dev/null || true
            return
        fi
        sleep 1
    done

    log "WARN" "Could not find a Falkon window to enter fullscreen"
}

configure_falkon_kiosk() {
    local settings_file settings_dir temporary_file

    settings_dir="${XDG_CONFIG_HOME:-$HOME/.config}/falkon/profiles/default"
    settings_file="$settings_dir/settings.ini"
    install -d -m 700 "$settings_dir"
    [[ -f "$settings_file" ]] || : >"$settings_file"
    temporary_file=$(mktemp "$settings_dir/settings.ini.XXXXXX")

    awk '
        BEGIN { in_section = 0; section_found = 0; setting_written = 0 }
        /^\[Browser-View-Settings\]$/ {
            in_section = 1
            section_found = 1
            print
            next
        }
        /^\[/ {
            if (in_section && !setting_written) {
                print "showNavigationToolbar=false"
                setting_written = 1
            }
            in_section = 0
        }
        in_section && /^showNavigationToolbar=/ { next }
        { print }
        END {
            if (in_section && !setting_written) {
                print "showNavigationToolbar=false"
            } else if (!section_found) {
                print "[Browser-View-Settings]"
                print "showNavigationToolbar=false"
            }
        }
    ' "$settings_file" 2>/dev/null >"$temporary_file"
    mv "$temporary_file" "$settings_file"
}

stop_process() {
    local pid="$1"
    local name="$2"
    local deadline state

    [[ -n "$pid" ]] || return
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        return
    fi

    log "INFO" "Stopping $name"
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + PROCESS_STOP_TIMEOUT))
    while kill -0 "$pid" 2>/dev/null; do
        state=$(ps -o stat= -p "$pid" 2>/dev/null)
        [[ "$state" == Z* ]] && break
        if (( SECONDS >= deadline )); then
            log "WARN" "$name did not exit within ${PROCESS_STOP_TIMEOUT}s; sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.2
    done
    wait "$pid" 2>/dev/null || true
}

falkon_profile_ready() {
    local profile_database="$1"

    [[ -s "$profile_database" ]] || return 1
    PROFILE_DATABASE="$profile_database" python3 - <<'PY'
import os
import sqlite3

required_tables = {
    "autofill",
    "autofill_encrypted",
    "autofill_exceptions",
    "history",
    "icons",
    "search_engines",
    "site_settings",
}

try:
    connection = sqlite3.connect(os.environ["PROFILE_DATABASE"], timeout=1)
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = ?", ("table",)
        )
    }
    integrity = connection.execute("PRAGMA integrity_check").fetchone()
except sqlite3.Error:
    raise SystemExit(1)
finally:
    if "connection" in locals():
        connection.close()

if not required_tables.issubset(tables) or integrity != ("ok",):
    raise SystemExit(1)
PY
}

preserve_incomplete_falkon_database() {
    local profile_database="$1"
    local timestamp suffix path

    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    for suffix in "" "-journal" "-wal" "-shm"; do
        path="${profile_database}${suffix}"
        [[ -e "$path" ]] || continue
        mv "$path" "${profile_database}.incomplete-${timestamp}${suffix}"
    done
    log "WARN" "Preserved incomplete Falkon profile database with timestamp $timestamp"
}

initialize_falkon_profile() {
    local falkon_path="$1"
    local profile_database profile_dir bootstrap_pid attempt stable_checks

    profile_dir="${XDG_CONFIG_HOME:-$HOME/.config}/falkon/profiles/default"
    profile_database="$profile_dir/browsedata.db"
    falkon_profile_ready "$profile_database" && return

    if [[ -e "$profile_database" || -e "${profile_database}-journal" || -e "${profile_database}-wal" || -e "${profile_database}-shm" ]]; then
        preserve_incomplete_falkon_database "$profile_database"
    fi

    log "INFO" "Initializing Falkon profile database"
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen "$falkon_path" \
        --no-extensions \
        about:blank >>"$FAILOVER_LOG" 2>&1 &
    bootstrap_pid=$!
    stable_checks=0

    for attempt in {1..40}; do
        if falkon_profile_ready "$profile_database"; then
            stable_checks=$((stable_checks + 1))
            (( stable_checks >= 2 )) && break
        else
            stable_checks=0
        fi
        kill -0 "$bootstrap_pid" 2>/dev/null || break
        sleep 0.25
    done

    stop_process "$bootstrap_pid" "Falkon profile bootstrap"
    if ! falkon_profile_ready "$profile_database"; then
        log "ERROR" "Falkon profile database did not initialize cleanly; see $FAILOVER_LOG"
        return 1
    fi
    log "INFO" "Falkon profile database initialized"
}

launch_midori() {
    local midori_path midori_status
    if ! pgrep -x midori >/dev/null; then
        if ! midori_path=$(midori_command); then
            log "ERROR" "Failover browser is unavailable: install midori and restart videokiosk2"
            return 1
        fi
        log "INFO" "Launching Midori failover browser with X11 backend"
        : >"$FAILOVER_LOG"
        env -u WAYLAND_DISPLAY GDK_BACKEND=x11 "$midori_path" \
            -e SingleWindow -e Fullscreen "$BROWSER_URL" >>"$FAILOVER_LOG" 2>&1
        midori_status=$?
        if (( midori_status != 0 )); then
            if [[ "$midori_path" == /snap/bin/* ]] && command -v snap >/dev/null 2>&1; then
                snap logs midori -n=50 >>"$FAILOVER_LOG" 2>&1 || true
            fi
            log "ERROR" "Midori exited with status $midori_status; see $FAILOVER_LOG"
            return 1
        fi
    else
        log "INFO" "Midori already running"
    fi
}

launch_failover_browser() {
    detect_failover_browser

    if [[ "$FAILOVER_BROWSER" == "midori" ]]; then
        schedule_standby_actions
        launch_midori
        cancel_standby_actions
        return
    fi

    local falkon_path falkon_pid falkon_status
    if ! pgrep -x falkon >/dev/null; then
        if ! falkon_path=$(falkon_command); then
            log "ERROR" "Failover browser is unavailable: install falkon and restart videokiosk2"
            return 1
        fi
        validate_falkon_scale
        : >"$FAILOVER_LOG"
        initialize_falkon_profile "$falkon_path" || return 1
        configure_falkon_kiosk
        log "INFO" "Launching Falkon failover browser with X11 backend at scale $BROWSER_SCALE"
        schedule_standby_actions
        env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=xcb QT_SCALE_FACTOR="$BROWSER_SCALE" "$falkon_path" \
            --private-browsing \
            --no-extensions \
            --fullscreen "$BROWSER_URL" >>"$FAILOVER_LOG" 2>&1 &
        falkon_pid=$!
        ensure_falkon_fullscreen
        wait "$falkon_pid"
        falkon_status=$?
        if (( falkon_status != 0 )); then
            log "ERROR" "Falkon exited with status $falkon_status; see $FAILOVER_LOG"
            cancel_standby_actions
            return 1
        fi
    else
        log "INFO" "Falkon failover browser already running"
    fi
    cancel_standby_actions
}

start_vlc() {
    local -a audio_arguments=()

    if [[ "$AUDIO_OUTPUT" == "alsa" ]]; then
        if [[ -z "$ALSA_AUDIO_DEVICE" ]]; then
            log "WARN" "ALSA audio output selected without a device; using VLC default"
        else
            audio_arguments=(--aout=alsa --alsa-audio-device="$ALSA_AUDIO_DEVICE")
            log "INFO" "Using VLC ALSA audio device: $ALSA_AUDIO_DEVICE"
        fi
    fi
    log "INFO" "Starting VLC with URL: $STREAM_URL"

    env QT_QPA_PLATFORM=xcb vlc -f "$STREAM_URL" "${audio_arguments[@]}" \
        --no-video-title-show \
        --no-interact \
        --no-qt-error-dialogs \
        --no-qt-privacy-ask \
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
disable_screen_blanking
sleep 20
start_vlc
sleep 5

if ! vlc_running; then
    log "ERROR" "VLC failed to start; see $VLC_LOG"
    launch_failover_browser
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
        if (( FREEZE_COUNT < THRESHOLD )); then
            ((FREEZE_COUNT++))
            (( FREEZE_COUNT == THRESHOLD )) && log "WARN" "Frozen frame threshold reached"
        fi
    else
        (( FREEZE_COUNT > 0 )) && log "INFO" "Freeze counter reset"
        FREEZE_COUNT=0
    fi

    LAST_FRAME_HASH="$FRAME_HASH"

    CURR_CPU=$(get_cpu_usage "$VLC_PID")
    AVG_CPU=$(( (CURR_CPU + PREV_CPU) / 2 ))
    PREV_CPU=$CURR_CPU

    if (( AVG_CPU < CPU_IDLE_THRESHOLD )); then
        if (( CPU_LOW_COUNT < THRESHOLD )); then
            ((CPU_LOW_COUNT++))
            (( CPU_LOW_COUNT == THRESHOLD )) && log "WARN" "Low CPU threshold reached"
        fi
    else
        (( CPU_LOW_COUNT > 0 )) && log "INFO" "Low CPU counter reset"
        CPU_LOW_COUNT=0
    fi

    if (( CURR_CPU == 0 )); then
        if (( CPU_ZERO_COUNT < THRESHOLD )); then
            ((CPU_ZERO_COUNT++))
            (( CPU_ZERO_COUNT == THRESHOLD )) && log "WARN" "Zero CPU threshold reached"
        fi
    else
        (( CPU_ZERO_COUNT > 0 )) && log "INFO" "Zero CPU counter reset"
        CPU_ZERO_COUNT=0
    fi

    if (( FREEZE_COUNT >= THRESHOLD && CPU_LOW_COUNT >= THRESHOLD )); then
        log "ERROR" "Freeze + low CPU detected. Triggering failover."
        stop_process "$VLC_PID" "VLC before failover"
        launch_failover_browser
        exit 0
    fi

    if (( CPU_ZERO_COUNT >= THRESHOLD )); then
        log "ERROR" "CPU stuck at zero. VLC likely not decoding. Triggering failover."
        stop_process "$VLC_PID" "VLC before failover"
        launch_failover_browser
        exit 0
    fi

    sleep "$CHECK_INTERVAL"
done

log "WARN" "VLC exited unexpectedly. Launching failover browser."
launch_failover_browser
exit 0
