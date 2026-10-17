<img src="Design/AppIcon/AppIcon.appiconset/AppIcon-128.png" width="96" height="96" alt="Khua Player app icon">

# Khua Player

Khua Player is a lightweight, native video player built for modern macOS and Apple silicon.

Get smoother motion with frame interpolation, generate and translate subtitles on your Mac,
and keep watching the playable parts of damaged or unfinished files.

Designed from the ground up for fast, responsive, and efficient playback.

[**Download for macOS**](https://khua.app/download) ·
[Website](https://khua.app) ·
[Release history](https://khua.app/releases) ·
[Build from source](#build-from-source)

Apple silicon · macOS 14 or later · Open source

Download the DMG, open it, and drag **Khua** to **Applications**. The official
download is Developer ID signed, notarized, and stapled; no extra codec packs
or Homebrew installation are needed to use it.

## More than playback

- **Smoother motion with Motion+.** Adaptive frame interpolation makes movement
  smoother. Hold **C** to compare the original and enhanced video side by side.
- **Subtitles, made on your Mac.** Generate subtitles from video audio, translate
  generated or existing text subtitles, and save the results as SRT. Processing
  stays on your Mac. Requires macOS 26; macOS may download a language model first.
- **Playback for imperfect files.** Khua attempts to recover playable content
  from damaged or partially downloaded files, marks problem areas on the
  timeline, and leaves the original file unchanged. Recovery is best-effort;
  not every damaged or incomplete file can be played.
- **More from your display.** Watch HDR video, use tone mapping on SDR displays,
  or give everyday SDR video extra brightness with Brightness+ on compatible displays.
- **A timeline drawn from your video.** Particle Star Trail takes its colors
  from the video itself. Liquid and Classic styles are also available.
- **Preview right in Finder.** Select a supported video and press **Space** for
  Quick Look playback, including MKV. Set Khua as the default player by file format.

Motion+ requires macOS 26 and a supported Mac. See [Requirements](#requirements)
for feature availability.

## Everyday essentials

- **Broad format support:** MKV, MP4, MOV, WebM, AVI, MPEG-TS, FLV, WMV, and common
  audio formats, with hardware decoding where supported and a bundled fallback.
- **Subtitles that travel with your video:** embedded and external text subtitles,
  including subtitle files in the same folder. Khua does not search for or download subtitles.
- **Natural-sounding speed control:** hold Space for Turbo playback, then release
  to return to normal speed. Voices keep their pitch.
- **Native multichannel audio:** 5.1 and 7.1 output on supported audio devices.
- **Trackpad gestures:** scroll horizontally to seek, vertically to change volume,
  and pinch to resize the window. Use **Playback > Gestures** to disable scroll
  actions, adjust sensitivity, or switch pinch to full screen.
- **A familiar Mac experience:** playback resume, frame stepping, screenshots,
  multiple playback windows, and an interface available in 17 languages.
- **Private by design:** no account, ads, or playback analytics. Your media and
  playback history stay on your Mac. See the [privacy policy](PRIVACY.md).

## Requirements

| Feature | Requirements |
|---|---|
| Basic playback and Quick Look | Apple silicon Mac running macOS 14 or later |
| Motion+ frame interpolation | macOS 26 and a Mac supporting system frame-rate conversion |
| Subtitle generation and translation | macOS 26; language availability depends on macOS, which may download language models on first use |
| Brightness+ | A compatible display with available extended brightness headroom |

Intel Macs are not supported. iPhone and iPad support is planned, but only the
Mac app is currently available.

## Build from source

Building requires an Apple silicon Mac and Xcode with the macOS 26.4 SDK or later.
You do not need the build tools to use the [official download](https://khua.app/download).

Install the build tools once:

```bash
brew install xcodegen meson ninja cmake pkg-config
```

Build the application:

```bash
./Apps/Mac/Scripts/build.sh          # Debug
./Apps/Mac/Scripts/build.sh Release  # optimized local build
```

Run these commands from the repository root. `Scripts/build.sh` remains a
compatibility entry point with the same arguments and environment settings.
The Mac project definition is [`Apps/Mac/project.yml`](Apps/Mac/project.yml);
the build generates `Apps/Mac/KhuaPlayer.xcodeproj`. Edit the definition, not
the generated Xcode project.

The first build downloads checksum-pinned dependency source archives, builds
them with the macOS SDK toolchain, generates the Xcode project, packages the
runtime libraries, signs the app ad hoc, and verifies its Mach-O dependency
closure. Subsequent builds reuse validated dependency stamps.

Run the app, optionally opening a local media file through the macOS document
open event:

```bash
./Scripts/run.sh
./Scripts/run.sh /path/to/video.mkv
```

The generated app is located at
`.build/Build/Products/<configuration>/Khua.app`. Release builds also deploy
the verified app to `Khua.app` at the repository root; Debug builds leave that
copy unchanged. Both locations are ignored by Git. Local Release builds are
still ad-hoc signed, not distribution-ready artifacts.

## Repository scope

This repository contains the shipping application source and the reproducible
build and packaging recipes. Large media fixtures, benchmark suites, internal
experiments, generated Xcode projects, dependency build trees, and caches are
intentionally excluded.

Editable Icon Composer source and the deterministic static AppIcon export live
in [`Design/AppIcon`](Design/AppIcon).

The directory layout separates the Mac product, reusable-source candidates,
and platform implementations. See [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md)
for ownership and build entry points. iPhone and iPad support is planned;
only the Mac product currently builds, and no mobile app target is included.

## Distribution

Local builds use ad-hoc signing. Developer ID releases and App Store archives
use separate, fail-closed signing configurations; see
[RELEASING.md](RELEASING.md). Release identity, version, bundle identifier, and
Apple Developer Team values must be supplied explicitly by the distributor.
The primary direct download is a signed, notarized, and stapled DMG with an
Applications shortcut. Generated apps, DMGs, ZIPs, archives, and symbols stay
outside Git history and are published through the release host.

Direct-distribution builds contain configuration-gated Sparkle support. Without
both `KHUA_SPARKLE_FEED_URL` and `KHUA_SPARKLE_PUBLIC_ED_KEY`, the updater does
not load, create a menu item, or make a network request. App Store builds omit
Sparkle and its configuration entirely. Configured direct builds check
automatically by default and expose an App-menu toggle to disable that behavior.

## Privacy and licensing

The application does not collect or transmit playback data. See
[PRIVACY.md](PRIVACY.md) for the current behavior.

Khua's own source code is available under the [MIT License](LICENSE).
Third-party components retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[`ThirdParty/Licenses`](ThirdParty/Licenses). Distributors are responsible for
satisfying all third-party license obligations.
