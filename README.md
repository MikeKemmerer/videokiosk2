# videokiosk2

A kiosk-mode video display system for Raspberry Pi. Plays an HLS/MPEG-TS video stream via VLC in fullscreen, with automatic freeze detection and browser-based failover.

## Features

- VLC fullscreen playback with freeze and CPU-stall detection
- Automatic failover to Midori on Raspberry Pi OS and Falkon on other installs
- Scheduled service restarts via an external API
- Configurable restart delay with schedule-supersede logic
- Systemd service integration

## Installation

Run the installer as root on a Raspberry Pi with a connected display:

```bash
sudo bash videokiosk2-installer.sh
```

On Ubuntu, the installer selects the non-root user that owns the X11 desktop.
You can set it explicitly when needed:

```bash
sudo bash videokiosk2-installer.sh --kiosk-user videokiosk
```

Managed scripts are installed in `/opt/videokiosk2` and generated settings in
`/etc/videokiosk2/local.conf`, rather than in the kiosk user's home directory.
The user's home directory remains the location for optional `tvOn.sh` and
`tvStandby.sh` hooks. Existing `/home/<user>/local.conf` files are read as
defaults during the first upgrade and then migrated to `/etc/videokiosk2`.

The installer will prompt for:
- **Video feed URL** — the HLS/MPEG-TS stream endpoint
- **Failover browser URL** — the page to show when the stream is unavailable
- **Schedule API URL** — endpoint providing restart trigger timing
- **Restart delay** — minutes to wait before acting on a restart trigger

The generated wrapper discovers a usable Xauthority file each time it starts,
so it does not rely on a stale path after a graphical-session restart. On a
newly provisioned Debian kiosk, no active X11 authority exists until LightDM
starts the first graphical session after reboot. Override discovery only when
needed with `--xauthority /path/to/Xauthority`.

### Prerequisites

The installer checks for the executable each feature needs before asking APT to
install a package. Raspberry Pi OS keeps the existing Midori failover path.
Other installs use Debian/Ubuntu's native `falkon` package, which runs from
the kiosk's system service without Snap desktop authorization. The installer
also uses `xdotool` to confirm Falkon is fullscreen after it opens. If a
prerequisite remains unavailable, the installer lists it at the end so it can
be installed manually before retrying.

On Ubuntu, the generated kiosk, scheduler, and optional GPIO services use a
`videokiosk2` AppArmor profile. It starts in complain mode so a display is not
blocked by a host-specific VLC, browser, or X11 dependency. Review
`journalctl -k | grep apparmor` and switch to enforcement after reviewing the
profile: `sudo aa-enforce /etc/apparmor.d/videokiosk2`.

## How It Works

1. `vlc-wrapper.sh` starts VLC in fullscreen and monitors for frozen frames (via screen-capture hashing) and low/zero CPU usage.
2. If the stream appears frozen or VLC stops decoding, VLC is killed and the
	failover browser opens in fullscreen. Raspberry Pi OS uses Midori; other
	installs use Falkon. Falkon uses a private, extension-free session for each
	failover, so it does not restore or accumulate previous tabs.
3. A companion scheduler script polls a REST API for scheduled restarts (e.g., before a live stream begins) and restarts the systemd service on cue.

## Configuration

Configuration can be supplied interactively or with `--feed-url`,
`--browser-url`, `--schedule-url`, `--restart-delay-minutes`, and GPIO flags.
The installer writes the final values into generated scripts. `local.conf` can
also set `FAILOVER_BROWSER` when you need to override the OS-based default.
For a 1080p Falkon kiosk displaying a 720p-oriented page, set
`BROWSER_SCALE="1.5"` in `local.conf` (or pass `--browser-scale 1.5` to the
installer). For a 4K display, use `BROWSER_SCALE="3"` to retain a 1280x720
logical page canvas. The scale is applied through Qt only when Falkon launches;
Midori continues at its native scale.
Use `--audio-output alsa --alsa-audio-device DEVICE` to make VLC use a specific
ALSA device, such as `hdmi:CARD=PCH,DEV=0`; `--audio-output auto` retains VLC's
normal output selection. Before choosing a device, list the host's identifiers:

```bash
aplay -L | grep '^hdmi:'
```

Use one full identifier from that output. The interactive ALSA prompt displays
the same HDMI entries when `alsa-utils` is installed; try `DEV=0`, then the
other listed devices if the connected display has no sound.
Run it again to change settings.

## License

MIT — see [LICENSE](LICENSE).
