# IslandBoard

**Turn the MacBook notch into a command surface.**

Media, system insight, widgets and quick utilities — one hover away.

IslandBoard is a native macOS app that lives in the notch. It stays out of the way
until you need it, then expands into a responsive SwiftUI surface for playback
control, system telemetry, timers, widgets and AI-assisted utilities.

It is a community fork of [**Atoll**](https://github.com/Ebullioscopic/Atoll),
continuing its development under an independent name, bundle identifier and update
feed. All original work remains © the Atoll Contributors — see
[Credits](#credits).

---

## Table of contents

- [Highlights](#highlights)
- [Feature tour](#feature-tour)
- [Requirements](#requirements)
- [Installation](#installation)
- [Building from source](#building-from-source)
  - [Building the Rust core](#building-the-rust-core)
- [First run & permissions](#first-run--permissions)
- [Gestures & controls](#gestures--controls)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

---

## Highlights

| | |
|---|---|
| 🎵 **Media everywhere** | Apple Music, Spotify, Cider, TIDAL, Amazon Music, YouTube Music and NetEase Cloud Music — album art, synced lyrics, Canvas and a live audio visualiser. |
| ⚡ **Live Activities** | Media, Focus, screen recording, privacy indicators, downloads, battery and charging — rendered straight inside the notch. |
| 🔒 **Lock screen widgets** | Music, timers, reminders, charging, Bluetooth, weather and custom extension widgets, in real Liquid Glass panels. |
| 📊 **System insight** | CPU, GPU, memory, network and disk telemetry, plus a full System Monitor window and a Control Center tab. |
| 🧰 **Daily utilities** | Timers, clipboard history, colour picker, calendar previews, downloads, a notes sync bridge and a built-in terminal. |
| 🎛️ **Endlessly tunable** | Layouts, animations, hover behaviour, gesture remapping and per-app volume — all from Settings. |
| 🐾 **Idle companions** | Custom Lottie animations and codex "pets" that stroll along the menu bar when the notch is idle. |

## Feature tour

**Media & playback**

- Unified controllers for seven players, with inline artwork previews and per-app volume.
- Pinned or scrolling lyrics with LRC parsing, metadata cleanup and offset correction.
- Spotify Canvas and animated artwork for the lock screen wallpaper.

**Notch experience**

- Hover to expand, click to enter controls, two-finger swipe to open or dismiss.
- Tabs for Media, Stats, Timer, Shelf, Clipboard, Notes, Terminal, Calendar, LLM Usage, System Monitor and Control Center.
- Standard notch and Dynamic Island layouts, with parallax hover and spring animations.

**Live activities & HUDs**

- Replace the native macOS OSDs for volume, brightness, keyboard backlight and media keys.
- Focus, screen recording, microphone/camera privacy, network and download indicators.
- Charging power readouts with battery telemetry from `AppleSmartBattery`.

**Lock screen**

- Widget panels for media, timers, reminders, weather, battery and Bluetooth devices.
- Glass materials, per-panel appearance and position controls.

**Productivity**

- Shelf with AirDrop, Quick Share and LocalSend, plus thumbnail and Quick Look previews.
- Clipboard history, colour picker, timers with live activities and a downloads manager.
- AI screen assistant for capturing a region and chatting about it.
- Apple Notes two-way sync, LLM usage tracking for Claude Code and Codex, and `caffeinate` toggles.

**Extensions**

- Third-party apps can publish live activities, lock screen widgets and full notch
  experiences through [`AtollExtensionKit`](https://github.com/Ebullioscopic/AtollExtensionKit),
  talking to the app over an authenticated XPC/WebSocket bridge.

## Requirements

| | |
|---|---|
| **macOS** | 14.6 or later (optimised for macOS 15 Sequoia and newer). |
| **Hardware** | A MacBook with a notch — 14″/16″ MacBook Pro (Apple silicon) or MacBook Air (M2 and later). |
| **Xcode** | Xcode 16 or newer, with the macOS SDK. |
| **Rust** | A stable toolchain from [rustup](https://rustup.rs) — the Xcode build phase compiles `atoll-core` for you. |

The app is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`): it needs Accessibility,
Screen Recording, Calendar, Reminders, Automation, microphone and camera access to do
its job.

## Installation

IslandBoard is distributed as source for now.

```bash
git clone https://github.com/RXJames/islandboard.git
cd islandboard
open DynamicIsland.xcodeproj
```

Select the **DynamicIsland** scheme, pick your development team under
*Signing & Capabilities*, and press **⌘R**. The first build compiles the Rust static
library, then links it into `IslandBoard.app`.

Prebuilt releases may appear under
[Releases](https://github.com/RXJames/islandboard/releases); the in-app updater reads
this repository's own appcast feed.

## Building from source

1. **Install the Rust toolchain** (once per machine):

   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
   ```

   Xcode's build environment has a minimal `PATH`; `atoll-core/build.sh` adds
   `~/.cargo/bin` and Homebrew paths automatically.

2. **Build the core** (optional — Xcode does this for you):

   ```bash
   ./atoll-core/build.sh --if-needed
   ```

3. **Build the app** from Xcode, or from the command line:

   ```bash
   xcodebuild -project DynamicIsland.xcodeproj \
              -scheme DynamicIsland \
              -configuration Debug \
              -destination 'platform=macOS' \
              build
   ```

### Building the Rust core

`atoll-core` is a static library that streams Claude Code and Codex session logs for
the LLM usage tab. It is pinned by `Cargo.lock` and `rust-toolchain.toml`, so a clean
checkout always resolves the same graph.

```bash
cd atoll-core
cargo test --locked      # unit suite
./build.sh               # release library for the host architecture
```

The Xcode target links `libatoll_core.a` through a bridging header, so the Swift side
never touches the raw JSONL files directly.

## First run & permissions

On first launch IslandBoard walks through onboarding and asks for the permissions it
actually needs:

| Permission | Used for |
|---|---|
| **Accessibility** | Media keys, window management, third-party brightness/volume controllers. |
| **Screen Recording** | Screenshots and screen-recording indicators. |
| **Camera** | The mirror widget. |
| **Microphone** | Audio visualiser and voice input for the AI assistant. |
| **Calendars & Reminders** | Calendar previews and reminder widgets. |
| **Automation** | Controlling Music, Spotify, Notes and terminal helpers. |
| **Location** | Lock-screen weather. |

After granting Accessibility or Screen Recording, quit and relaunch the app — macOS
only reports the new state on the next launch.

## Gestures & controls

- **Hover** near the notch to expand it; **click** to enter the tab controls.
- **Two-finger swipe down** opens the notch when hover-to-open is disabled; swipe up to close.
- **Horizontal swipes** on the music pane skip tracks or seek ±10 s
  (*Settings → General → Gesture control*).
- **Drag files** onto the notch to park them in the Shelf.
- **Right-click** the lock-screen artwork to show it as the wallpaper.
- Add files to the Shelf from Terminal: `open -a IslandBoard /path/to/file`.

## Project layout

```
islandboard/
├── DynamicIsland/              # The app target (SwiftUI + AppKit)
│   ├── components/             # Notch, settings, live activities, lock screen views
│   ├── managers/               # Feature managers (media, stats, clipboard, LLM usage…)
│   ├── MediaControllers/       # One controller per supported player
│   ├── SystemMonitor/          # Telemetry collectors, models and dashboard
│   ├── services/Extensions/    # AtollExtensionKit host, XPC + WebSocket bridge
│   └── Info.plist, entitlements
├── atoll-core/                 # Rust static library for JSONL usage aggregation
├── DynamicIslandTests/         # Unit tests
├── DynamicIslandUITests/       # UI tests
├── Updates/                    # Sparkle appcast feeds
├── docs/                       # Design notes and fixtures
└── scripts/                    # Project-file and regression helpers
```

> The Xcode target and module keep their historical `DynamicIsland` name; only the
> product, display name and bundle identifier are IslandBoard.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Notch does not expand | Grant Accessibility, then quit and relaunch. |
| Stats are empty | Enable the categories you care about in *Settings → Stats*. |
| Media controls do nothing | Make sure the player is running and its automation permission is granted. |
| Update check fails | The appcast feed is served from this repository; make sure `main` is published. |
| Rust core fails to build | Run `rustup show` and confirm the pinned stable toolchain is installed. |
| Logs are needed | *Menu bar → Tools → Export Logs* writes a zip of app logs and crash reports. |

## Contributing

Issues and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first — it covers the build setup, code style and
the test suites (`cargo test` for the core, ⌘U in Xcode for the app).

Since IslandBoard is a fork, please report bugs here rather than upstream, and keep
the GPL attribution headers intact in new files.

## License

IslandBoard is released under the **GNU General Public License v3.0**. See
[LICENSE](LICENSE) for the full text, [NOTICE](NOTICE) for third-party components and
[COPYRIGHT_ASSETS](COPYRIGHT_ASSETS) for asset licensing.

## Credits

**Fork lineage**

IslandBoard descends from [Atoll](https://github.com/Ebullioscopic/Atoll) by
[Ebullioscopic](https://github.com/Ebullioscopic), which in turn builds on the
excellent [boring.notch](https://github.com/TheBoredTeam/boring.notch) project. All
upstream copyright notices and GPL attribution are preserved; this fork changes the
product name, bundle identifier and update feed only.

**Upstream acknowledgements**

- [**Boring.Notch**](https://github.com/TheBoredTeam/boring.notch) — foundational codebase: media integration, AirDrop shelf and calendar display.
- [**Alcove**](https://tryalcove.com) — inspiration for Minimalistic Mode and the lock-screen widget concept.
- [**Stats**](https://github.com/exelban/stats) — SMC temperature, IOReport frequency and per-core CPU sampling architecture.
- [**Open Meteo**](https://open-meteo.com) — weather data for lock-screen widgets.
- [**SkyLightWindow**](https://github.com/Lakr233/SkyLightWindow) — window rendering for lock-screen widgets.
- [**rtaudio**](https://github.com/ZephyrCodesStuff/rtaudio) — C++ live audio visualiser.
- [**SwiftTerm**](https://github.com/migueldeicaza/SwiftTerm) — terminal tab implementation.
- [**DynamicNotch**](https://github.com/jackson-storm/DynamicNotch) — battery HUDs.
- [**OpenUsage**](https://github.com/robinebers/openusage) — LLM usage tracking, with [OpenRouter](https://openrouter.ai) for model pricing.
- **Wick** — the iOS-style timer design used by the timer and lock-screen widgets.
