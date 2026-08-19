# YouTube Plus

> **Unofficial.** A personal, third-party project. Not affiliated with,
> authorised by, or endorsed by YouTube or Google, and not the official YouTube
> application. "YouTube" is a trademark of Google LLC.

YouTube in a native macOS window, with SponsorBlock and an ad blocker built in.

## Install

Download `YouTube Plus.dmg` from
[Releases](https://github.com/zucchiniii/youtube-for-macos/releases), open it and
drag the app onto Applications.

The first launch needs one extra step, because the app is signed ad hoc rather
than with a paid Apple Developer ID: **right-click the app and choose Open**,
then confirm. Only once — it opens normally afterwards. If macOS refuses
outright, clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/YouTube Plus.app"
```

Requires macOS 14 or later.

## Build it yourself

```bash
git clone https://github.com/zucchiniii/youtube-for-macos.git
cd youtube-for-macos
./build.sh run
```

That compiles, assembles `build/YouTube Plus.app`, draws the icon, ad-hoc signs
it and launches. `./build.sh` builds without launching.

To produce the disk image:

```bash
./Tools/make-dmg.sh
```

Building needs a Swift 6 toolchain (Xcode 16+). No dependencies.

---

## What it is

The interface is YouTube's own site, running in a WebKit view. The home feed,
search, subscriptions, playlists, comments, the player, its scrub bar, quality
menu, captions and full-screen button are all the real thing, so everything
behaves the way you already know and nothing breaks when YouTube changes its
layout.

YouTube Plus adds the parts YouTube does not have:

**SponsorBlock.** Segments come from the community database. Each of the ten
categories gets its own action — skip automatically, show a skip button, mute,
mark only, or ignore. Segments are drawn in their category colours directly on
YouTube's scrub bar, and listed under the video with their time ranges and a Jump
link. When something is skipped, a notice appears inside the player with an
Unskip button and 👍/👎 buttons that vote back to the database. A running total of
time saved lives in the SponsorBlock menu. All of it is configurable in
Settings › SponsorBlock.

Privacy mode is on by default: the server is queried by a four-character hash
prefix shared by many videos, so it never learns which video you are watching.

**Ad blocking.** The important part is not request filtering — it is that the ad
placements (`adPlacements`, `playerAds`, `adSlots`) are stripped out of YouTube's
player response before its own code reads them, so no ad is ever scheduled.
Blocking the ad's requests alone is actively worse than useless: the player still
reserves the slot and then sits on a black screen buffering an ad that will never
arrive, for roughly as long as the ad would have run.

On top of that, ad and ad-tracking hosts are blocked inside WebKit, banner and
overlay ads are removed, and as a fallback any ad that still appears has its skip
button clicked, or is muted and run out at 16×.

Ads that YouTube stitches directly into the video stream cannot be removed this
way — they are the same bytes as the video.

**No Premium prompts.** The "get YouTube without the ads" dialog and its mealbar
are dismissed and removed on sight, whether or not ad blocking is on.

**Quality.** YouTube leaves playback on Auto, which often settles below what a
video actually offers. Settings › General lets you pin a resolution, or ask for
the highest each video has — applied as it starts, falling back gracefully when
a video does not carry the rung you asked for.

Note that *1080p Premium* (enhanced bitrate) is not among the options. It is a
paid YouTube Premium entitlement granted server-side, and is not present in the
player's quality list for accounts without the subscription — no client can
request it into existence.

**A native shell.** Real macOS menus, keyboard shortcuts, an always-on-top
option, and a Shorts-hiding toggle.

## Signing in

Sign in on the page itself, exactly as you would in a browser — the Sign in
button at the top right. The session is stored on this Mac in the app's own
WebKit data store and persists across launches, so you only do it once. Your
password goes straight to Google; YouTube Plus never sees it.

Settings › General has a "Sign out and clear site data" button.

The first launch shows Google's cookie-consent dialog. YouTube Plus does not answer
it for you — that choice is yours. Whatever you pick is remembered.

## Keyboard

The page keeps YouTube's own shortcuts, so `space`, `k`, `j`/`l`, the arrow keys,
`f` for full screen and `c` for captions all work as usual. On top of those:

| Key | Action |
| --- | --- |
| `⌘1`–`⌘4` | Home, Subscriptions, History, Watch Later |
| `⌘←` / `⌘→` | Back and forward |
| `⌘R` | Reload |
| `⌘O` | Open the YouTube link on the clipboard |
| `⌘⇧B` | Toggle SponsorBlock |
| `⌘⇧A` | Toggle ad blocking |

## How it works

`Web/PageScript.swift` holds the JavaScript injected into youtube.com. Skipping
runs inside the page rather than in Swift: the segment list and your preferences
are pushed in once per video, and from then on the page handles every frame
locally. That keeps skips accurate without a message round trip four times a
second, and lets the notice, the skip button and the coloured scrub-bar marks be
real DOM elements sitting correctly inside YouTube's interface.

Swift keeps the parts that belong outside the page: fetching segments from the
SponsorBlock API, recording votes, the time-saved statistics, the compiled
ad-blocking rules, and the window and menus.

```
Sources/YouTubePlus/
  App/YouTubePlusApp.swift    window, menus, shortcuts
  Web/YouTubeView.swift       the web view, navigation policy, page↔Swift bridge
  Web/PageScript.swift        injected SponsorBlock + ad handling
  Web/BrowserState.swift      navigation state and commands
  Services/SponsorBlock.swift segment fetching and voting
  Services/AdBlocker.swift    compiled WebKit content rules
  Storage/Settings.swift      preferences
  UI/Settings/                the settings window
Tools/MakeIcon.swift          draws the app icon at build time
Tools/make-dmg.sh             packages the app as a disk image
```

## Performance

The injected script is event driven rather than polled: skips ride the player's
own `timeupdate`, page cleanup runs from a throttled MutationObserver, and the
SponsorBlock panel is re-attached rather than rebuilt when YouTube's renderer
detaches it. Preferences are pushed into the page only when they actually
change. This matters at 4K, where the page has no headroom to spare — an earlier
version rebuilt the panel about ten times a second and pushed preferences on
every frame update.

Two constraints worth knowing about, both discovered the hard way:

- YouTube enforces Trusted Types, so any `innerHTML` assignment throws. Every
  injected element is built with `createElement`/`textContent`.
- Never force a width or height onto `#movie_player` or the `<video>` element.
  It measures correctly and the frames decode, but nothing is composited and the
  picture stays black while the audio plays.

## Notes

- Playback is YouTube's own player, so it is subject to whatever YouTube serves
  you. An earlier version of this app streamed the video natively with AVPlayer;
  that was removed because YouTube stops serving unattested direct streams after
  roughly a megabyte, and because a custom player meant reimplementing a scrub
  bar, quality menu and captions that YouTube already does better.
- Ad blocking is best-effort. YouTube changes its ad delivery often; the rules
  and selectors in `AdBlocker.swift` and `PageScript.swift` are where to adjust.

