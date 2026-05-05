# Audio Visualizer for Apple Music

This is an audio visualizer for the macOS Apple Music app, which can be
loaded and used via the [Uebersicht](https://tracesof.net/uebersicht/) app.

This is made possible by replicating the FFT logic used by
[Rainmeter](https://www.rainmeter.net/). The design is inspired by the Nexa
Rainmeter theme's audio visualizer.

## The Result

![Image](AudioVisualizer.png)

The `MusicInfo.jsx` widget complements the visualizer by displaying info about
the current song being played.

## Requirements

- macOS 14.2 (Sonoma) or later - required for `CATapDescription` in
  `visualizer.swift` to capture `Music.app`'s audio.
- [Uebersicht](https://tracesof.net/uebersicht/) app.
- Permissions to record system audio in Privacy & Security settings.

## Architecture

```
Music.app audio
     |
     v
visualizer (Swift daemon)
  - CoreAudio process tap via CATapDescription
  - vDSP FFT at ~43Hz (44100 / 1024 samples/hop)
  - Rainmeter algorithm: Hann window, per-bin smoothing, log2-spaced bands
  - Pushes binary Float32 frames over WebSocket at ~43Hz
  - Heartbeat gate: stops pushing if renderer silent for >2s
     |
     | ws://127.0.0.1:9001  (binary: numBands*2 Float32 values)
     v
Visualizer.jsx (Ubersicht widget)
  - init() opens WebSocket, sends 1s heartbeat pings
  - visibilitychange closes socket when desktop is hidden
  - Float32Array from ArrayBuffer -- no JSON parsing
  - Renders to a single <canvas> at ~43Hz
  - CSS filter: drop-shadow() for glow (GPU-composited)
```

## Build

```sh
swiftc -O visualizer.swift -o visualizer -framework Accelerate -framework CoreAudio -framework AppKit -framework Network
```

## Configuration

All parameters are in the `Config` struct at the top of `visualizer.swift`.
Defaults: 119 bands, FFT size 2048, overlap 1024, 250-16000 Hz, WebSocket port 9001.
Rebuild after changing any values.

## Launch at Login

To run the daemon automatically at login, create a launchd plist at
`~/Library/LaunchAgents/com.visualizer.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.visualizer</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/visualizer</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/visualizer.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/visualizer.log</string>
</dict>
</plist>
```

Replace `/path/to/visualizer` with the absolute path to the compiled binary,
then load it:

```sh
launchctl load ~/Library/LaunchAgents/com.visualizer.plist
```

To unload:

```sh
launchctl unload ~/Library/LaunchAgents/com.visualizer.plist
```
