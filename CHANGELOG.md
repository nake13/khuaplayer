# Changelog

All notable public releases will be documented here.

## Unreleased

- Played videos with a rotation tag, such as portrait phone recordings, upright.
  Windows, Quick Look, timeline previews, and screenshots follow the intended
  orientation instead of the stored landscape frame.

## 0.6.1

- Reused existing update checks for installation-level activity and version
  statistics, deduplicated using a random local identifier.
- Kept automatic update checks enabled by default, without additional
  requests, settings, permission dialogs, or playback analytics.
- Updated privacy disclosures and the in-app summary in all 17 languages.

## 0.6.0

- Enabled in-app update checks for the official direct-download channel.
- Verified signed update feeds and packages before installation.

## 0.5.1

- Show the full product name, Khua Player, in About while keeping Khua as the
  short name in the Dock, Finder, application menu, and app bundle.

## 0.5.0

- Added Motion+ frame interpolation on supported Macs running macOS 26 or later,
  including adaptive coverage, playback status, and hold-to-compare preview.
- Added animated Motion+ and Brightness+ indicators, with a stable Motion+
  readout during Turbo playback.
- Improved discovery and seeking of playable content in partially downloaded
  MKV, MP4, and MPEG-TS files, with missing-content timeline indicators.
- Improved recovery when switching to software decoding mid-stream.
- Reviewed interface translations and public source documentation.

## 0.4.0

- Added best-effort playback recovery for damaged or incomplete media, including
  clearer failure reasons, retry actions, and unavailable-content indicators.
- Added playback of supported files while they are downloading or being
  recorded, with waiting notices, automatic continuation, and resume-history
  updates when the same file is renamed.
- Expanded format support, including MXF, DV, raw AV1, VVC, CAVS, DNxHD/DNxHR,
  and Speex audio; improved raw-stream end-of-file and seek handling.
- Refined timeline appearance, default-player setup detection, and Quick Look
  error feedback.
- Reviewed the new interface copy in all 17 supported languages and updated
  English source comments and dependency notices.

## 0.3.1

- Clarified Brightness+ controls, HDR output descriptions, and accessibility labels.
- Refined playback control sizing and truncation for longer translations.
- Improved consistency across the 17 supported interface languages.

## 0.3.0

- Added on-device subtitle generation and translation on supported macOS 26
  systems, with background tasks, bilingual display, SRT output, and save recovery.
- Added EDR brightness enhancement for SDR video on compatible displays.
- Improved color management for SDR, RGB software decoding, wide-gamut media,
  and subtitles.
- Added Particle Star Trail, Liquid, and Classic timeline styles.
- Refined playback controls, automatic cursor hiding, and file-open panels.
- Prevented idle sleep during video playback, including Quick Look previews.
- Completed interface translations and reviewed public English source comments.

## 0.2.0

- Added native multichannel audio output and automatic output-device tracking.
- Added a direct IOSurface-backed AV1 decode path and improved HDR playback.
- Improved Dolby Vision thumbnails, long-GOP MPEG-TS seeking, frame stepping,
  and playback recovery.
- Refined the hold-Space Turbo indicator and window-drag visual feedback.
- Completed all 17 interface translations for the updated audio information.
- Reduced the shipping runtime and build dependencies to the public feature set.

## 0.1.0

- Added hold-Space Turbo playback with configurable speed and translated menu
  controls, plus pitch-preserving audio during playback-rate changes.
- Improved precise seeking and hover thumbnails across Matroska, MPEG-TS,
  MPEG-PS, and other containers, including HDR thumbnail caching.
- Improved playback from slow or disconnected storage with cancellable reads,
  targeted index prefetching, and faster file-opening preparation.
- Improved AV1 decoding resource limits, frame stepping, subtitle cancellation,
  audio-rate transitions, and HDR/SDR color handling.
- Deferred automatic-updater initialization until playback is idle and moved
  screenshot encoding and file writes off the main thread.
- Established the standalone Khua public repository.
- Added reproducible local builds, bundle verification, App Store project
  configuration, privacy metadata, licensing material, and app icon assets.
- Expanded the interface from English and Simplified Chinese to 17 locales,
  with data-driven language selection and explicit English fallback behavior.
- Fixed language-menu state handling and made status chips size themselves to
  translated text instead of truncating longer locales.
- Added configuration-gated Sparkle support for future direct distribution.
  Mac App Store builds compile out the updater and exclude the framework.
- Added an App-menu toggle for automatic update checks in configured direct
  builds; users can turn the default-on behavior off at any time.
- Added a per-format **Set as Default Player** dialog for video and audio files.
- Added a welcome view with continue-watching history, recent-play menus, and
  Dock access to recent media.
- Added independent playback windows with active-window menu routing and
  duplicate-file focusing.
- Added automatic external-subtitle discovery, language-aware ranking, and
  transactional subtitle loading with recovery safeguards.
- Improved responsiveness for remote and sleeping storage through directory
  indexing, bounded panel warming, and foreground-I/O yielding.
- Added a localized **Clear Menu** action for recent plays that preserves saved
  resume positions.
- Added bounded welcome-list volume warming and hover-driven file prefetching
  for direct builds, with foreground playback priority and no cloud downloads.
- Reused file-open panels and added hover preparation to reduce repeated setup.
  Welcome windows present a standalone panel; clearing history discards cached
  panel directories across all windows.
- Added an opt-in volume boost up to 500%, with a two-step interaction boundary,
  smooth software gain, and stereo-linked peak protection.
- Refined the playback controls with localized accessibility labels, responsive
  timeline and button feedback, and Reduce Motion fallbacks.
- Added direct-distribution onboarding for default file associations, including
  setup and restore offers. Sandboxed App Store builds omit these controls.
- Improved slow-storage feedback and preparation with earlier recent-file
  warming, priority-aware prefetching, and a lightweight opening indicator.
- Added Escape-key exit from full-screen playback.
- Improved playback reliability across seeking, end-of-file transitions, audio
  recovery, thumbnails, HDR color metadata, AV1 decoding, and asynchronous
  frame presentation.
