# AISessionUsageTrack

A native macOS menubar app that tracks your Gemini and Claude usage by scraping
the official usage pages inside an embedded WKWebView with persistent cookies.

The menubar shows compact percentages (e.g. `G:42% C:18%`); clicking the icon
opens a panel with the full text scraped from each page.

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

The app has no dock icon (`LSUIElement=true`); look for the gauge icon in the
menubar.

## First-run setup

1. Click the gauge icon in the menubar.
2. For each service, click **Open Login Window**.
3. Sign in. Cookies persist via `WKWebsiteDataStore` and survive app relaunches.
4. Close the window — the app refreshes automatically.

### Google OAuth caveat

Google blocks OAuth inside embedded WebViews as anti-phishing policy, so
**"Continue with Google" will fail** in this app's login window.

- **Claude**: use the email login instead. If the email contains a 6-digit
  code, type it in the form. If it's only a magic-link button, right-click →
  **Copy Link**, paste into the URL bar at the top of the login window, and
  press Enter.
- **Gemini**: only supports Google login, so no clean workaround inside the
  WebView. Cookie-import from Chrome is a possible future enhancement.

## Settings

Click the menubar icon → **Settings…**

- **Base interval** — how often to refresh (default 180 s)
- **Jitter** — random ±N seconds added to each refresh (default 30 s); avoids
  fixed-interval bot patterns
- **Show percentages in menu bar** — toggle the `G:nn% C:nn%` text label

## How it works

- One `WKWebView` per service, all sharing
  `WKWebsiteDataStore.default()` for persistent cookies.
- A timer fires every `refreshSeconds ± jitterSeconds`, loads each usage URL,
  waits for the SPA to render, and runs a heuristic JS extraction that pulls
  lines containing `%`, `X/Y`, or words like
  `limit / remaining / messages / tokens / reset`.
- The first `\d+%` match becomes the percentage shown in the menubar label.
- If the page redirects off the expected host, status flips to `needs login`.

## Project layout

```
Package.swift                          SwiftPM manifest
Info.plist                             Bundle metadata, LSUIElement=true
build.sh                               Compile + bundle into .app + ad-hoc sign
Sources/AISessionUsageTrack/
  App.swift                            @main, MenuBarExtra, menubar label
  UsageMonitor.swift                   WebScraper + UsageMonitor + Settings
  Views.swift                          Menu, login window, settings views
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
refine `Service.extractionScript` in `UsageMonitor.swift`.
