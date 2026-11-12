# IslandBoard Test Checklist

Use this checklist before shipping a build, and at minimum the focused subset
after changing the notch surface, Home layout, tabs, media, weather, System
Monitor, or Terminal.

## Automated

- [ ] Clean build succeeds:
  `xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- [ ] Full unit suite succeeds:
  `xcodebuild test -project DynamicIsland.xcodeproj -scheme DynamicIsland -destination 'platform=macOS' -only-testing:DynamicIslandTests CODE_SIGNING_ALLOWED=NO`
- [ ] UI suite succeeds on an unlocked GUI session:
  `xcodebuild test -project DynamicIsland.xcodeproj -scheme DynamicIsland -destination 'platform=macOS' -only-testing:DynamicIslandUITests`
- [ ] Signed Release/Debug build succeeds with `DEVELOPMENT_TEAM` set.
- [ ] `git diff --check` reports no whitespace errors.
- [ ] No temporary debug markers (`TEMP DEBUG`, `/tmp/atoll`, debug-only labels) are left in source.

## Notch and window

- [ ] Closed notch aligns with the physical notch / fake notch / Dynamic Island pill.
- [ ] Settings → Appearance → Notch Size: changing Expanded notch height resizes an open notch immediately.
- [ ] Home content and album artwork stay inside the selected height, including at 180pt and 360pt.
- [ ] Bottom rounded corners match the top at every expanded height.
- [ ] Hover opens; pointer exit closes, except while a popover, drag, or sticky terminal is active.
- [ ] Click outside closes the open notch.
- [ ] Top and bottom open corners match visually on Home and every other tab.
- [ ] Closing and reopening does not leave a clipped surface, stuck gesture, or stale shadow.
- [ ] Multi-display: only the selected screen opens; Show on All Displays still mirrors correctly.

## Home

- [ ] Music artwork is inset from the left edge and does not touch the rounded corner.
- [ ] Calendar/weather column reaches the right edge with equal visual clearance.
- [ ] Music and right column have a clear centre gutter.
- [ ] Artwork is 150pt and keeps its square aspect ratio.
- [ ] Calendar all-day and timed events render without clipping.
- [ ] Weather shows current conditions, five-hour strip, and five-day forecast.
- [ ] Daily temperatures show **low/high** (for example `11/19`).
- [ ] Missing location/weather shows the unavailable state rather than a blank panel.
- [ ] Play/pause, previous/next, shuffle, repeat, and app icon overlay still work.

## Tabs and transitions

- [ ] Forward tab changes slide in from the right; backward changes slide from the left.
- [ ] No cross-fade or old page remaining visible after the slide.
- [ ] Sliding content is clipped to the notch; no page bleeds outside the shape.
- [ ] Tab switching still works when the notch grows or shrinks (Home ↔ Monitor ↔ Terminal).
- [ ] Keyboard shortcuts and horizontal tab paging still select the expected tab.

## Stats and System Monitor

- [ ] Stats tab respects the configured graph count and one/two-row height.
- [ ] System Monitor opens at the two-row height and shows CPU/GPU plus memory/disk without clipping.
- [ ] Monitor scrolling works; closing gesture is suppressed until the content reaches the bottom.
- [ ] Open Dashboard launches the separate dashboard window.
- [ ] Sparklines, core strip, compact row, and 2-second refresh continue updating.
- [ ] Switching away from Monitor releases its surface state and close gesture suppression.

## Terminal

- [ ] Open Terminal from the tab bar and from the keyboard shortcut.
- [ ] Type immediately after opening without clicking inside first.
- [ ] Focus survives the page transition, window resize, settings/popover dismissal, and app reactivation.
- [ ] Return executes commands; arrow keys, Ctrl-C, Ctrl-D, and paste work.
- [ ] Restart shell clears/restarts the session and input works again.
- [ ] Close and reopen the notch; scrollback and input remain usable.
- [ ] Terminal sticky mode prevents unwanted auto-close.

## AI Assistant

- [ ] Settings tab and shortcut are labelled **AI Assistant**.
- [ ] Enable/disable AI Assistant persists.
- [ ] Add Provider lists Gemini, OpenAI, Claude, DeepSeek, Groq, and Local; an added provider cannot be added twice.
- [ ] Configure opens the correct key/endpoint field and saves; DeepSeek shows Base URL + API Key; the row changes to Configured.
- [ ] Use switches the active provider and selects a compatible model.
- [ ] Remove drops the provider from the list and selects a remaining provider.
- [ ] Existing provider keys migrate into the provider list on first launch after upgrade.
- [ ] Default Cmd+Shift+A opens the assistant; provider/model selection only lists added providers.
- [ ] Send a message and receive a response; missing key shows the API Key Required alert.
- [ ] Attach an image/screenshot (Gemini) and confirm it is sent as multimodal content.

## Media and lyrics

- [ ] Playback metadata and artwork update for the selected provider.
- [ ] Horizontal media gestures can be enabled/disabled independently of tab swipe gestures.
- [ ] Reverse-swipe setting is honored.
- [ ] Lyrics display, scroll, and pinned lyrics do not overlap Home content.
- [ ] Media unavailable/offline states do not crash or freeze the notch.

## Weather and location

- [ ] Live location and manually selected city both resolve.
- [ ] °C/°F and AQI setting changes refresh immediately.
- [ ] Open-Meteo and fallback provider paths both produce a snapshot.
- [ ] Weather settings page is reachable, titled "Weather", and saves changes.
- [ ] Home weather and lock-screen weather remain independent.

## Control Center, Focus, and other tabs

- [ ] Wi-Fi, Focus, Night Shift, Dark Mode, volume, brightness, and keyboard light tiles respond.
- [ ] Tile drag reorder, resize, hide/show, and edit mode persist after relaunch.
- [ ] Focus mode switch/off works with Accessibility permission; failure shows a toast.
- [ ] Notes, Clipboard, Timer, Shelf, Color Picker, and LLM Usage open without layout breakage.
- [ ] Idle pet selected animation plays; walking mode can be toggled and dragged back into the notch.

## Displays and accessibility

- [ ] Built-in Retina display renders crisp text and corners.
- [ ] 1x external display: text is readable; expected lower PPI softness is not mistaken for a layout bug.
- [ ] Notchless Mac / external display: Dynamic Island and Standard Notch styles both position correctly.
- [ ] Non-notch height, Hide until hover, and Show on all displays settings apply.
- [ ] VoiceOver labels and accessibility identifiers remain present on the notch surface.
- [ ] Reduce Motion: page transitions do not break layout.

## Settings, permissions, and persistence

- [ ] Settings opens from the notch and menu bar.
- [ ] First-launch onboarding completes; permissions requested are explained.
- [ ] Calendar, weather location, Accessibility, Bluetooth, and Automation permissions degrade gracefully when denied.
- [ ] Settings survive relaunch and no stale values resurrect old layouts.
- [ ] No repeated error logs or console spam during normal use.

## Release smoke

- [ ] Install the signed build to `/Applications/IslandBoard.app`.
- [ ] Launch with the previous app closed; only one notch surface is visible.
- [ ] Menu bar icon, Settings, System Monitor, and Quit still work.
- [ ] Run the full checklist once on a fresh preferences domain.

## Last run

**2026-11-11**

- Debug build: passed.
- Unit suite: **364 tests / 0 failures** (includes the DeepSeek provider filtering tests).
- Full scheme: all 364 unit tests passed; the `DynamicIslandUITests` runner was killed by the system before it established a connection, so the UI runner result is inconclusive rather than an assertion failure.
- Signed build and install: passed (`/Applications/IslandBoard.app`).
- Final post-cleanup rerun (after unlocking): passed with a clean derived-data path.
- UI smoke: the first IslandBoard launch also triggered Accessibility / file / location permission prompts. Complete those once, then run the manual checklist above.
