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
3. Open OpenEar. The first time, macOS blocks it because the app isn't notarized by Apple. Follow [First launch](#first-launch) below. You only do this once.
4. Allow microphone access when asked.

Needs macOS 14 or later on Apple Silicon.

### First launch

<p align="center"><img src="assets/install-guide.gif" alt="Walkthrough of opening OpenEar the first time" width="640"></p>

1. When **“OpenEar” Not Opened** appears, click **Done**. Not Move to Trash.
2. Open **System Settings → Privacy & Security**, scroll down to **Security** and click **Open Anyway** next to “OpenEar” was blocked. The button only shows for about an hour after step 1. If it's gone, open OpenEar again and repeat.
3. Click **Open Anyway** again in the dialog that appears.
4. Confirm with Touch ID or your password.
5. Done! OpenEar is in your menu bar.

Comfortable with Terminal? This does the same in one go:

```bash
xattr -dr com.apple.quarantine /Applications/OpenEar.app && open /Applications/OpenEar.app
```

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
