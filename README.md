# OpenEar

Transparency mode for wired headphones on your Mac.

AirPods can let the world in. Wired IEMs can't. OpenEar plays your Mac's microphone into your headphones, so you can hear people talking to you without taking your earbuds out. It lives in the menu bar.

## Features

- **Ambient sound** on and off from the menu bar, a timer (15m to 8h, or until a set time) or a weekly schedule
- **Super hearing** makes quiet sounds and voices louder and caps loud ones, so a slammed door won't blast your ears
- **Sound controls**: volume, bass, treble and rumble cut
- **Global shortcuts**: `⌃⌥⌘O` toggles ambient sound, `⌃⌥⌘S` toggles super hearing
- **Feedback guard** pauses automatically if your Mac switches to its speakers, and resumes when your headphones come back
- **Recovers by itself** if macOS interrupts the microphone, for example after sleep
- **URL commands** for Shortcuts, Raycast or scripts: `open "openear://toggle"` (also `on`, `off`, `super`)

## Install

1. Download the latest `OpenEar-x.y.z.dmg` from [Releases](https://github.com/TheBikramLama/OpenEars/releases).
2. Open it and drag **OpenEar** to **Applications**.
3. Open OpenEar. macOS will block it the first time, because the app isn't notarized by Apple. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Allow microphone access when asked.

Needs macOS 14 or later on Apple Silicon.

## Tips

- The MacBook's built-in microphones hear the room best. Headphone cable mics mostly pick up your own voice.
- Expect a small delay on your own voice. Software on a Mac can't react as fast as the dedicated chips in AirPods. A lower **Latency** setting helps, until you hear crackling.
- Turn OpenEar off during video calls, or you'll hear yourself.

## Build from source

```bash
brew install sox dylibbundler
scripts/build.sh      # build/OpenEar.app
scripts/make-dmg.sh   # dist/OpenEar-<version>.dmg
```

No Xcode needed; the Command Line Tools are enough.

The app icon and the installer window background are drawn in code. After editing `scripts/render-art.swift`, run `scripts/render-art.sh` to update `assets/`.

## Releasing

Push a version tag. GitHub Actions builds the DMG and publishes a release with it.

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Licence

OpenEar is MIT licensed. It bundles [SoX](https://sourceforge.net/projects/sox/), which is GPL licensed and runs as a separate program. Its licence is included in the app at `Contents/Resources/SoX-LICENSE.GPL`.
