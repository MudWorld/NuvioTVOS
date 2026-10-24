## tvOS Beta 3.4.7

> **Install:** [NuvioTV-3.4.7-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.7/NuvioTV-3.4.7-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 300+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### In-App Update Notices & Remote Announcements

- **Automated Release Update Notices:** Integrated `ReleaseUpdateService` to detect new official releases directly within the app, displaying non-intrusive update banners with instant QR code download links, version comparison, and skip options.
- **Broadcast Announcements:** Added `AnnouncementService` with support for remote broadcast notices and release highlights (`announcements.json`) with focus-safe dismissals and persistent acknowledgement tracking.
- **Update Settings & Privacy:** Added customizable release update toggles in Settings allowing users to configure or disable update checking at any time.

### AetherEngine 7.47.0 & Live HLS Stream Recovery

- **AetherEngine 7.47.0 Integration:** Upgraded core playback engine to version 7.47.0 with native live HLS starvation recovery policies (`NativeLiveHLSStarvationPolicy`) and live join keyframe alignment.
- **Origin HOLD-BACK & Loop Elimination:** Restored origin HOLD-BACK for live HLS playback, eliminating buffer exhaustion and screen refresh loops on unstable streams.
- **Stereo Video Signal Support:** Added `StereoVideoSignal` structures and pipeline interfaces for enhanced 3D/spatial video readiness.
- **Audio Host Rebuffering & Spatial Audio:** Hardened `AudioAVPlayerHost` rebuffering resilience and object audio renderer tracking for immersive Atmos and DTS:X streams.

### Release Performance Optimization & Diagnostic Silence

- **Zero-Allocation View Tracing:** Converted `TVHomeDebugTrace` to use `@autoclosure () -> String`, completely eliminating hidden heap string allocations and interpolation overhead in `HomeView.body` during view re-renders and focus transitions.
- **Silenced Startup Benchmark Overhead:** Wrapped `PlaybackStartupBenchmark` in `#if DEBUG`, eliminating 5 synchronous console logs and multi-line ASCII breakdown table formatting on `@MainActor` during stream startup in Release builds.
- **Hot-Path Logging Cleanup:** Stripped synchronous console logging from high-frequency runtime loops, including Siri Remote scrub/seek watchdogs, live reconnect loops, audio tap buffer broadcasts (`PlaybackAudioTapBroker`), and per-frame face detection (`ActorRecognitionService`).
- **Heartbeat Save Cleanliness:** Gated periodic 5-second `ContinueWatchingStore` and player progress heartbeat prints under `#if DEBUG` for zero console I/O churn during movie playback.

### Watch Party on tvOS & Multi-Service Scrobble

- **Watch Party Sign-In Flow:** Streamlined account and profile switching directly from the Watch Party tab for unauthenticated or session-expired users.
- **Cross-Platform Chat & Party Lobby:** Polished party lobby UX and in-player message toast layouts for incoming messages from iOS, iPadOS, Android, and Desktop users.
- **Independent Multi-Service Scrobble:** Hardened simultaneous scrobbling across Trakt, Simkl, and WeTrakr with profile-isolated token management.

### Localization & Catalog Polish

- **Expanded Language Catalog:** Refined translations and terminology across European Portuguese, Traditional Chinese, Simplified Chinese, French, Spanish, German, and Arabic.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
