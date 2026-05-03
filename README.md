# An Audio Visualizer for the Apple Music App

This is an audio visualizer for the macOS Apple Music app, which can be
loaded and used via the [Uebersicht](https://tracesof.net/uebersicht/) app.

This is made possible by replicating the FFT logic used by
[Rainmeter](https://www.rainmeter.net/).

## Demo

![Image](AudioVisualizer.png)

## Requirements

- macOS 14.2 (Sonoma) or later - required for `CATapDescription` in
  `visualizer.swift` to capture `Music.app`'s audio.
- [Uebersicht](https://tracesof.net/uebersicht/)
- Permissions to record system audio (to capture the Music app's audio) in
  privacy and security.

## Build

```sh
swiftc visualizer.swift -o visualizer.out -framework Accelerate -framework CoreAudio -framework AppKit
```

## Usage

```bash
./visualizer.out [--app <bundleID>] [--bands N] [--fft-size N] \
  [--fft-overlap N] [--fmin Hz] [--fmax Hz]  \
  [--sens-fast dB] [--sens-slow dB] [--gain x] \
  [--decay-fast ms] [--decay-slow ms] [--output path]
```

Defaults: `com.apple.Music`, 119 bands, FFT size 2048, overlap 1024,
250-16000 Hz.

## Launch at Login

Create `~/Library/LaunchAgents/com.visualizer.plist`:

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
    <string>/path/to/visualizer.out</string>
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

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.visualizer.plist
```
