# videokiosk2

A kiosk-mode video display system for Raspberry Pi. Plays an HLS/MPEG-TS video stream via VLC in fullscreen, with automatic freeze detection and browser-based failover.

## Features

- VLC fullscreen playback with freeze and CPU-stall detection
- Automatic failover to Midori browser when stream is down
- Scheduled service restarts via an external API
- Configurable restart delay with schedule-supersede logic
- Systemd service integration

## Installation

Run the installer as root on a Raspberry Pi with a connected display:

```bash
sudo bash videokiosk2-installer.sh
```

The installer will prompt for:
- **Video feed URL** — the HLS/MPEG-TS stream endpoint
- **Failover browser URL** — the page to show when the stream is unavailable
- **Schedule API URL** — endpoint providing restart trigger timing
- **Restart delay** — minutes to wait before acting on a restart trigger

## How It Works

1. `vlc-wrapper.sh` starts VLC in fullscreen and monitors for frozen frames (via screen-capture hashing) and low/zero CPU usage.
2. If the stream appears frozen or VLC stops decoding, VLC is killed and Midori opens as a failover.
3. A companion scheduler script polls a REST API for scheduled restarts (e.g., before a live stream begins) and restarts the systemd service on cue.

## Configuration

All configuration is set at install time via interactive prompts. The installer writes the final values into the generated scripts. Run the installer again to change settings.

## License

MIT — see [LICENSE](LICENSE).
