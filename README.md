# Icecast Control

Run your own internet radio stream from a Mac, from the menu bar. No Terminal, no config files.

Icecast Control bundles the [Icecast](https://icecast.org) streaming server and an MP3 encoder,
and walks you through setup the first time you open it.

- **Built-in server**: Icecast is included. A welcome guide creates it with secure passwords,
  or connects to an Icecast server you already have.
- **Stream any audio**: everything your Mac plays (no extra audio drivers needed), any audio
  interface or microphone, or **OBS** (with the separate OBS plugin).
- **Status at a glance**: the menu bar icon is green when you're on air, orange when the server is
  ready and waiting for audio, and red when something needs attention.
- **Stays on air**: reconnects by itself after drops and server restarts. Optional notifications
  when the stream goes on or off air.
- **Broadcast-ready audio**: sent at its original level with a −1 dBFS safety limiter, at
  128 kbps MP3 by default (adjustable).
- **Settings without XML**: edit the address, port, stream path, passwords and limits in the app.

Requires macOS 14.2 or later on Apple silicon.

## Install

1. Download **Icecast-Control.dmg** from the [latest release](https://github.com/BigDumbRobot/icecast-control/releases/latest).
2. Open it and drag **Icecast Control** into **Applications**.
3. Open the app. Because it isn't from the App Store, macOS asks you to confirm the first time:
   go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to
   Icecast Control, and confirm.
4. Follow the welcome guide. Then look for the antenna icon in the menu bar.

> Can't see the icon? A full menu bar hides icons behind the camera notch. Hold **⌘** and drag
> other icons out of the menu bar to make room.

### OBS plugin (optional, separate install)

Stream OBS's audio to Icecast, so radio listeners hear exactly what your video stream sends.

1. Download **Icecast-Control-OBS-Plugin.zip** from the same release and unzip it.
2. Double-click **Install OBS Plugin.command**. (If macOS blocks it: System Settings → Privacy &
   Security → Open Anyway.) It closes OBS for a moment, adds the plugin, and reopens OBS.
3. In Icecast Control, set the Broadcast input to **OBS**.

Now the OBS input plays OBS's audio whenever OBS is open, streaming or not; press Go Live to
put it on air. Choose the audio track in OBS → Tools → Scripts → `icecast-control-obs.lua`.

## Letting listeners reach you

Listeners on the internet connect to your Mac through your router. The welcome guide shows the
exact settings, and **Test** checks that it works:

- **Port forwarding**: in your router's settings, forward the server's TCP port (e.g. 8000) to
  your Mac's local IP address.
- **A stable address** (recommended): home IP addresses change. A free dynamic DNS name from
  [DuckDNS](https://www.duckdns.org) or [No-IP](https://www.noip.com) keeps your link working.

## Using an existing Icecast setup

On first launch the app looks for Icecast servers already on your Mac (running, or installed
with Homebrew/MacPorts). If it finds one, it asks whether to use it or make a new one. Choosing
"use it" leaves your existing settings file in place; the app edits it directly (keeping a
`.bak` backup) and starts/stops that server.

## Where things are

| What | Where |
| --- | --- |
| Server settings (new setups) | `~/Library/Application Support/Icecast Control/icecast.xml` |
| Server logs | `~/Library/Logs/Icecast Control/` |
| OBS plugin | `~/Library/Application Support/obs-studio/scripts/icecast-control-obs.lua` |

To uninstall, quit the app and delete it from Applications (and the folders above if you like).
Remove the OBS plugin with **Uninstall OBS Plugin.command**.

## Build from source

Needs the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh             # build/Icecast Control.app
./build.sh --install   # build, copy to /Applications and open
./build.sh --release   # also make dist/Icecast-Control.dmg and the OBS plugin zip
```

The first build downloads and compiles Icecast, LAME, libogg/libvorbis and a minimal ffmpeg
for macOS 14.2+ (`scripts/build-deps.sh`, a few minutes). The bundled programs only use macOS's
own libraries.

### How it works

- **Server**: the bundled `icecast` runs in the background with the settings file; status is read
  from Icecast's `status-json.xsl` every few seconds.
- **Audio capture**: system audio uses a Core Audio process tap (macOS 14.2+); devices use Core
  Audio directly; OBS audio arrives from the OBS plugin as WAV over a local-only connection
  (`127.0.0.1:8046`).
- **Encoding**: the bundled `ffmpeg` encodes MP3 with LAME and sends it to Icecast.

## License

Icecast Control is released under the MIT License (see [LICENSE](LICENSE)). The bundled Icecast,
ffmpeg and LAME have their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
