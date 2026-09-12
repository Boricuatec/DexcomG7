<h1 align="center">Dexcom G7 for Omarchy</h1>

<p align="center">
  Live glucose readings, trend arrow, and a recent-history tooltip in the Omarchy bar,
  pulled straight from the Dexcom Share API.
</p>

<p align="center">
  <a href="https://paypal.me/Boricuatec"><img alt="Donate via PayPal" src="https://img.shields.io/badge/donate-PayPal-00457C?logo=paypal&logoColor=white"></a>
</p>

## Why I built this

My 12-year-old son was diagnosed with Type 1 Diabetes in 2025. We're in San
Diego, California, and I wanted a way to keep an eye on his glucose from my
own computer while I'm working, without having to pick up my phone every few
minutes. This plugin is that — built for him, first and foremost.

If it's useful to you too and you'd like to contribute, every bit donated
through the PayPal link above goes straight into his college fund. No
pressure at all — just glad to share something that helps our family in case
it helps yours.

## Disclaimer

This is an independent, unofficial project. It is **not affiliated with,
endorsed by, or supported by Dexcom or Insulet**. It talks to a
reverse-engineered API that Dexcom has not published and can change or
break at any time without notice. It is not a medical device and must not
be used as your primary means of monitoring glucose or making treatment
decisions — always follow the official Dexcom app and your care team's
guidance. Use entirely at your own risk.

## What it shows

- Current glucose value and trend arrow in the bar, polled adaptively around
  Dexcom's ~5 minute reporting cadence rather than a fixed interval.
- Color-coded by range: theme color = normal, orange = low/high, red = urgent
  low/high, gray = stale (no recent reading) or errored.
- Hover for a tooltip with the reading age and a rolling history summary
  (low–high range and overall direction).
- **Click the bar text to open a popup** with the current reading and a graph
  of recent history, shaded to show the low/high threshold bands, plus
  3h/6h/12h/24h range buttons (matching the Dexcom app) to re-fetch a wider
  or narrower window on demand without disturbing the bar's own poll
  schedule. Your last-picked range is saved as the new default (via
  `omarchy bar set`), so it's still selected after a shell restart or
  reboot. Also summonable over IPC (e.g. for a hotkey binding):
  `omarchy-shell io.github.boricuatec.dexcomg7 toggle` (also `open`/`close`).

## Requirements

- The Dexcom account used **must be the sensor wearer's own account** — the
  one logged into the Dexcom G7 app on the phone actually paired to the
  transmitter, with Share turned on in that app's Settings. A separate
  Follow-app / follower account, or a Caregiver account watching a
  Dependent's data, **will not work** — the Share API only ever returns data
  for the authenticated account's own sensor. This isn't a bug you can work
  around; it's how the endpoint is scoped.
- Phone-number usernames (e.g. `+15551234567`) work fine as of a 2024 Dexcom
  server update — no need for a separate alphanumeric username.

## Setup

1. Create the credentials file from the bundled example (default location
   shown; override via the widget's `credentialsPath` setting if you'd
   rather keep it elsewhere). [`credentials.env.example`](credentials.env.example)
   also carries inline notes on the login gotchas below:

   ```bash
   mkdir -p ~/.config/omarchy-dexcom
   cp credentials.env.example ~/.config/omarchy-dexcom/credentials.env
   $EDITOR ~/.config/omarchy-dexcom/credentials.env   # fill in real values
   chmod 600 ~/.config/omarchy-dexcom/credentials.env
   ```

   This file is never read by anything but the script, is not part of this
   git repo, and should never be committed anywhere. It's deliberately kept
   **outside** this plugin's own directory so a future `omarchy plugin
   update` (a `git merge`) can never touch it.

2. Install the plugin:

   ```bash
   omarchy plugin add https://github.com/Boricuatec/DexcomG7 --enable
   ```

3. Set your region if you're outside the US, and tune thresholds, in the
   widget's settings (gear icon in the bar customization view, or
   `omarchy bar set io.github.boricuatec.dexcomg7 <key> <value>`):

   | Setting | Default | Notes |
   |---|---|---|
   | `server` | `share2` | `share2` = US, `shareous1` = outside US, `share` = Japan |
   | `pollIntervalSeconds` | `60` | Fallback/retry cadence only — normal polling is adaptive (see below) |
   | `lowThreshold` / `highThreshold` | `70` / `180` | mg/dL, orange warning band |
   | `urgentLow` / `urgentHigh` | `55` / `250` | mg/dL, red urgent band |
   | `staleAfterMinutes` | `20` | Flags a possible sensor/Bluetooth disconnect |
   | `units` | `mgdl` | `mgdl` or `mmol`. Thresholds above are always entered in mg/dL regardless |
   | `showHistoryInTooltip` | `true` | Toggles the "Last N min: lo-hi (direction)" tooltip line |
   | `historyWindowMinutes` | `60` | How far back that history line looks (15-180) |
   | `showTrendWord` | `false` | Spells out "rising" etc. instead of the raw Dexcom trend code |
   | `graphWindowMinutes` | `180` | How far back the popup graph looks (60-1440); fetched in the same call, no extra API load |

## Troubleshooting

- **"Dexcom login rejected" / `AccountPasswordInvalid` even with the right
  password**: this almost always means the application ID doesn't match the
  server region, or an older single-step login endpoint is being hit. This
  plugin uses the two-step `AuthenticatePublisherAccount` →
  `LoginPublisherAccountById` flow with the region-correct application ID
  (matching the actively-maintained
  [`pydexcom`](https://github.com/gagebenne/pydexcom) client) — if you forked
  this and it regresses, that's the first thing to check.
- **Empty `[]` result with a successful login**: you're authenticated as a
  follower/caregiver account rather than the sensor wearer's own account —
  see Requirements above.
- **Repeated failures**: Dexcom's servers apply rate-limiting/lockout
  protection after several failed logins in a row. Don't hammer retries;
  verify the password by logging into the Dexcom app or
  [myaccount.dexcom.com](https://myaccount.dexcom.com) directly first.
- **Icon/glyph shows as a box**: this widget intentionally uses plain text
  (`BG 112 →`) rather than a Nerd Font icon codepoint. Testing on a stock
  Omarchy install found that fontconfig can report a codepoint as covered by
  the theme font (JetBrainsMono Nerd Font) while the font still fails to
  actually draw it, falling back to a tofu box. Plain Unicode arrows (`→ ↑ ↓`)
  render fine; private-use icon-font codepoints are not trustworthy without
  testing them in the live bar first.
- **No hover cursor / no tooltip after editing `Dexcom.qml`**: the bar's
  tooltip system only calls `showTooltip`/`hideTooltip` on a target that
  exposes a `tooltipHovered` property — this widget gets that (plus the
  pointer cursor on hover, and click-target registration) for free by
  building on `qs.Ui`'s `WidgetButton`, so don't drop that base without
  replacing what it provides. Separately: `omarchy-shell shell
  rescanPlugins` reliably picks up logic/property changes, but a change to
  the QML **root type** (e.g. `Item` → `WidgetButton`) may not fully apply
  until `omarchy restart shell`.
- **Changing a setting (`omarchy bar set ...`) has no visible effect**: two
  separate things to know here, both discovered getting this plugin's
  settings working at all:
  1. `bar.shellQuote` — listed in the bar plugin's own `README.md` as
     available to custom widgets — **does not exist** on `PluginBarApi`, the
     facade third-party plugins actually get (see
     `/usr/share/omarchy/shell/Ui/PluginBarApi.qml`). Calling it throws a
     `TypeError` inside the `Process.command` binding, which QML swallows by
     silently keeping the command's last successfully-evaluated value —
     meaning every settings change after the first render was **silently
     ignored forever**, with no visible error unless you go looking at the
     shell's own log. This widget quotes its own args (see `shQuote` in
     `Dexcom.qml`) instead of relying on that method; if you fork this and
     reach for `bar.shellQuote`, don't.
  2. `omarchy bar set` always stores values as strings, including booleans —
     a stored `"false"` is still a non-empty JS string and therefore
     JS-truthy. Compare with `String(value).toLowerCase() === "true"` (see
     `settingBool` in `Dexcom.qml`), not a bare truthiness check.
  3. Even with both of those fixed, a settings change only reaches a
     *running* widget instance on its next poll or a full reload — like the
     root-type case above, `omarchy restart shell` is the reliable way to
     see a settings change take effect immediately rather than waiting for
     the poll interval.
- **Building a popup on top of `WidgetButton`**: don't. A bar widget that
  wants a popup panel (not just a tooltip) needs `qs.Ui`'s `Panel` as the
  *root* type instead, with the visible bar text/cursor/tooltip moved onto a
  `WidgetButton` **child** (`button` in `Dexcom.qml`), and the popup itself
  built with `KeyboardPanel` (also third-party-safe — confirmed via the
  already-installed AirPods plugin using the identical pattern). One gotcha
  along the way: `KeyboardPanel`'s default content property only accepts
  visual `Item`s, so a `Connections {}` block used to trigger graph repaints
  has to live outside it (as a sibling of `button`/`panel`), not nested
  inside as a "child" of the popup content.
- **A range button appears pre-selected when opening the popup via
  `omarchy-shell ... open` (IPC) instead of an actual click**: seen once in
  testing on this system's non-standard Hyprland fork, not reproduced via a
  real click. `selectedRangeMinutes` is confirmed to only ever change inside
  the range buttons' own click handler, so if this recurs for you, it's an
  environment/compositor quirk around synthetic opens, not a logic bug —
  worth a report against your specific setup if it's consistent.

## License

MIT
