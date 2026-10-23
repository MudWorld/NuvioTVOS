## tvOS Beta 3.4.6

> **Install:** [NuvioTV-3.4.6-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.6/NuvioTV-3.4.6-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 300+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Watch Party on tvOS (Beta) & Real-Time Sync

- **Dedicated Sidebar Watch Party Tab & Lobby:** Embedded Watch Party directly into the main sidebar with its own dedicated space (`TVTab.party`) for effortlessly joining rooms via short codes or hosting rooms with instant QR code sharing.
- **Host Directly from Scene Menu & Details:** Launch new Watch Parties instantly from the Siri Remote Scene / Insight panel while enjoying any stream, or right from the Details screen before starting playback.
- **Real-Time Cross-Platform Chat (Incoming):** Stay connected with party members on iOS, iPadOS, Android, and desktop with real-time chat message toasts during playback (read-only for now; Apple TV remote keyboard reply coming soon).
- **Stream Together with Your Chooms:** *Watch the new Cyberpunk: Edgerunners Season 2 with your chooms* — synchronized playback across all devices keeps everyone frame-accurate with automatic drift correction, resilient reconnection, and host seek broadcasts.
- **Guest Shared-Source Playback:** Seamlessly connects guest playback to host-provided streams with explicit privacy consent and fallback protection.

### Independent Multi-Service Scrobble (Trakt, Simkl & More Together)

- **Simultaneous Multi-Service Sync:** Completely overhauled scrobbling engine to sync watch progress and completions independently across Trakt, Simkl, WeTrakr, and MDBList without cross-service interference.
- **Profile-Scoped Credentials:** Scoped all scrobbling tokens, watch history snapshots, and MDBList authentication strictly to individual local profiles.

### AetherEngine 7.46.0 & Playback Core Upgrades

- **AetherEngine 7.46.0 & FFmpegBuild 3.9.0:** Upgraded core AetherEngine playback pipeline with FFmpegBuild 3.9.0, adding native DTS:X height channels via patched `dca` decoder (`x_heights` option).
- **MPVKit with MoltenVK 1.4.2:** Upgraded vendored MPVKit package with MoltenVK 1.4.2 for enhanced Vulkan-on-Metal rendering stability.
- **Live Stream Startup & Recovery:** Fixed live playback startup hangs and gracefully retained recognized live state until coherent finite timelines are established.
- **Forced & Embedded Subtitle Fallback:** Respected forced subtitle preferences while automatically falling back to user's preferred embedded audio and subtitle languages when external subtitles arrive late.

### Scene Menu Frame Capture & UI Enhancements

- **Active Playback Frame Capture:** Added high-resolution video frame snapshotting directly inside the Scene panel.
- **Preferred-Language Trailers:** Intelligently resolves and streams trailers matching your primary interface language.
- **Custom Poster URL Patterns:** Expanded regex patterns and catalog matching for third-party metadata feeds.
- **Jellyfin Grouping by Library:** Grouped home titles and shelf collections cleanly by Jellyfin library source.

### Comprehensive Native Translations & Localization

- Normalized terminology, status copy, and complete native translations across European Portuguese, Traditional Chinese, Simplified Chinese, French, Spanish, German, and Arabic.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
