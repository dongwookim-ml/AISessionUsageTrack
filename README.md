# AISessionUsageTrack

A native macOS menubar app that tracks your **Gemini** and **Claude** usage by
scraping the official usage pages inside embedded WKWebViews with per-service
persistent cookies.

The menubar shows two compact, color-coded badges
(e.g. `✦ 1%  ✱ 16%`) — green / orange / red by severity. Clicking the icon
opens a compact dropdown with a brand icon, progress bar, reset-time line, and
per-service action buttons (refresh / login / logout) for each service.

## Requirements

- macOS 14 (Sonoma) or later
- Swift toolchain: install Xcode, or just the command-line tools via
  `xcode-select --install`
- Accounts at <https://gemini.google.com> and <https://claude.ai>

## Build

```bash
git clone git@github.com:dongwookim-ml/AISessionUsageTrack.git
cd AISessionUsageTrack
./build.sh
```

`build.sh` compiles a release build and wraps the executable into
`AISessionUsageTrack.app` in the project root. The bundle is ad-hoc signed so
WebKit and cookie storage work without Gatekeeper warnings on your own machine.

## Install

Move the built bundle into Applications:

```bash
mv AISessionUsageTrack.app /Applications/
open /Applications/AISessionUsageTrack.app
```

To start it at login: **System Settings → General → Login Items → `+`** and
pick the `.app`.

The app has no dock icon (`LSUIElement=true`); look for the badges in the
menubar.

## First-run setup

1. Click the badges in the menubar to open the dropdown.
2. For each service, click the small **person.crop.circle** icon button
   (rightmost group, next to the reset-time line) to open the login window.
3. Sign in (see the Google OAuth caveat below for Claude / Gemini quirks).
4. Close the login window — the app auto-refreshes.

Cookies persist via a per-service `WKWebsiteDataStore`, identified by a UUID
saved to `UserDefaults` (`WebsiteDataStoreUUID.gemini` /
`WebsiteDataStoreUUID.claude`). Logging into one service does **not**
authenticate the other — you can use different Google accounts for each.

### Google OAuth caveat

Google blocks OAuth inside embedded WebViews as anti-phishing policy, so
**"Continue with Google" will fail** in this app's login window.

- **Claude**: use the email login instead. If the email contains a 6-digit
  code, type it in the form. If it's only a magic-link button, right-click →
  **Copy Link**, paste into the URL bar at the top of the login window, and
  press Enter.
- **Gemini**: only supports Google login, so no clean workaround inside the
  WebView. Cookie-import from Chrome is a possible future enhancement.

## Dropdown layout

Each service section shows, top to bottom:

- Brand-tinted SF Symbol + service name + percent + relative "last updated"
- Inline progress bar tinted by severity (green < 50, orange 50–79, red ≥ 80)
- One-line status. When logged in: a parsed **reset time**, e.g.
  `Resets at 2:02 PM`. Gemini's page renders this directly; for Claude, the
  page's "Resets in X hr Y min" string is converted to an absolute clock time
  at refresh time.
- Three compact icon buttons on the right: **refresh** (`arrow.clockwise`),
  **open login window** (`person.crop.circle`), **logout** (red
  `rectangle.portrait.and.arrow.right`). Hover for tooltips.

Bottom bar:

- `[⟲ Refresh all]` (bordered button)
- `[⚙]` Settings (bordered, tooltip "Settings…")
- `[⏻]` Quit (bordered, red tint)

## Settings

Click the menubar → bottom-right `[⚙]` button.

- **Base interval** — how often to refresh (default 180 s)
- **Jitter** — random ±N seconds added to each refresh (default 30 s); avoids
  fixed-interval bot patterns
- **Show percentages in menu bar** — toggle the per-service badges in the
  menubar label
- **Accounts** — per-service buttons to open login window or log out

## How it works

- One `WKWebView` per service, each backed by its own persistent
  `WKWebsiteDataStore(forIdentifier:)` so cookies / logins are isolated.
- Each webview lives in an invisible `NSPanel` (alpha 0.01, non-focusable,
  ignored by cmd-tab / Mission Control, parked at the screen corner). The
  panel stays in the WindowServer's visible window list so WebKit keeps
  rendering and SPA pages don't flip to `document.hidden = true` and pause
  data fetches.
- A timer fires every `refreshSeconds ± jitterSeconds`. For each service the
  app loads the usage URL, polls until the page renders a literal
  `digit-%` or `digit/digit` (so we don't extract a half-hydrated skeleton),
  and runs a JS extractor that pulls lines containing `%`, `X/Y`, or words
  like `limit / remaining / messages / tokens / reset`.
- The first `\d{1,3}%` becomes the percentage shown in the menubar.
- A separate regex extracts the **reset time** — `Resets at H:MM AM/PM` for
  Gemini, `Resets in X hr Y min` (converted to an absolute clock time using
  the current `Date()`) for Claude.
- If the page redirects off the expected host (e.g. accounts.google.com or
  claude.ai/login), the status flips to `needs login`.
- For debugging, each WKWebView has `isInspectable = true` — open
  **Safari → Develop → \<Mac name\> → AISessionUsageTrack** to inspect the
  hidden background webviews.

## Menubar rendering notes

- macOS's `MenuBarExtra` label silently strips SwiftUI `Image` views (both
  inside `HStack` and inside concatenated `Text(Image(systemName:))`). The
  app renders the brand glyph as a Unicode character (`✦` U+2726 for Gemini,
  `✱` U+2731 for Claude) so the per-service icons survive into the menubar.
- The dropdown panel, which is rendered by a normal SwiftUI view, keeps the
  SF Symbol icons (`sparkles`, `asterisk`) since `Image` works fine there.

## Project layout

```
Package.swift                          SwiftPM manifest (no resources)
Info.plist                             Bundle metadata, LSUIElement=true
build.sh                               Compile + bundle into .app + ad-hoc sign
Sources/AISessionUsageTrack/
  App.swift                            @main, MenuBarExtra, menubar label
  UsageMonitor.swift                   Service, ServiceState, WebScraper,
                                       UsageMonitor, AppSettings,
                                       parseResetText, firstPercent
  Views.swift                          Menu, ServiceSection, SubtleIconButton,
                                       LoginWindowView, SettingsView
```

## Development

Open in Xcode:

```bash
open Package.swift
```

`swift run` works for quick iteration but produces a non-bundled executable
without the `LSUIElement=true` Info.plist, so it shows a dock icon. Use
`./build.sh` for the proper menubar-only experience.

The extraction is intentionally loose — if either usage page changes its DOM,
refine `Service.extractionScript` (the keyword filter) and
`UsageMonitor.parseResetText` (the reset-time regexes) in
`UsageMonitor.swift`.

## License

MIT. See [LICENSE](LICENSE).
