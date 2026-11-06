# DGG for iPhone

Native iOS client for destiny.gg. `DGGKit` and the emote, chat text and player code
were copied from [dgg-tv](https://github.com/murdrd00/dgg-tv), whose NOTES.md explains
how the protocol, emote engine and Kick latency work. This file covers what's
different on a phone.

## Status

Runs in the iPhone 18 Pro simulator, on iOS 27.2. Checked there, against live chat:
chat, flairs, rainbow names, animated emotes, combos, the pin, a real poll, the embed
pills, swiping the video, scrolling back, landscape, Settings, text size, YouTube in the
app, the message box with its suggestions, and tapping a link.

**Not yet run on a real iPhone**, so these are still unknown: Kick and Twitch picture
(see below), real posting, scrolling smoothness and battery. Posting and voting have
only run through the test hooks, which never reach chat.

Not built yet: Picture in Picture and audio in the background. Leaving the app stops
the stream, as on TV.

## Video in the simulator

Kick and Twitch look broken in the iOS Simulator and this is not the app. The picture
shows a soft or frozen frame, or goes black, with thousands of `err=-8969` (bad data)
from `VTDecompression` in the log. The simulator decodes in software and it chokes on
these streams:

| Test | Result |
|---|---|
| Twitch through AVPlayer on a Mac | 1080p, 54 fps, no errors |
| Kick, plain, on a Mac | 1080p, 57 fps, no errors |
| Kick through `LiveLoader`, on a Mac | 1080p, 58 fps, no errors |
| Apple's bipbop stream in the iPhone simulator | 960x720, moving, no bad data errors |

So don't chase this in the simulator. Judge video on a phone. If a stream gives no frame
within 15 seconds, the player says so rather than sitting there black.

`AVPlayerLayer` needs its scale set by hand. AVPlayer picks quality to suit the layer
and it was reporting 402x226, which is points, on a 1206x678 picture. That's what
`Surface.didMoveToWindow` is for. `primaryVideoOutputSize` in the log shows the value.

## Performance

Chat is the hot path at about 400 messages a minute, so it's a `UITableView` rather
than a SwiftUI list.

- SwiftUI doesn't observe the chat lines at all. `ChatListController` pulls them on
  its own timer, so a new message never re-evaluates a SwiftUI body.
- Each line's text and height are worked out once and cached.
- Each batch is one diffable update of only the rows that changed.
- Emotes stay Core Animation layers, so they play with no timer and no redraws.
- The chat socket opens while flairs load, rather than after.
- `URLCache` is raised to 256 MB, or emotes would download again on every launch.
- Nothing plays until a stream is picked, which also saves mobile data.

With chat running and no video, the simulator measured 0.3-3.6% CPU in a Debug build.
That's a sanity check rather than a phone figure.

Chat stops taking new lines the moment a finger lands on it, not when a drag starts.
Otherwise a link in fast chat moves out from under the tap.

Still worth measuring on a phone: rows use a `UITextView`, which is heavy. If scrolling
drops frames, drawing text into a plain layer is the next step.

## Coming back from the background

iOS freezes the app, so the socket can return dead with nothing to say so. The
watchdog would take 45 seconds to notice. `reconnectIfStale` reconnects at once if
nothing has arrived for 8 seconds, and takes about 0.1s against live chat. It skips the
backoff on purpose. Going through `noteDisconnect` took 4.4s, because the dead socket's
last callback started a second backoff.

The server replays its last 150 lines on every connect, so `.history` drops lines it
already has, on screen or waiting, matched on nick, time and text. Replayed lines get new
ids, so ids can't be used for this. Anything new queues like a normal line, so a
reconnect can't move what's being read. The simulator doesn't freeze sockets, so this
path has been tested against live chat from the command line but not seen in the app.

## People and mentions

Taken from the site's own client, `destinygg/chat-gui`, rather than guessed:

- A highlighted line uses `$color-chat-highlight`, `#06263e`, which is dark blue. Your
  name as a whole word counts, links don't, and neither do your own lines.
- Stalk is `/api/chat/stalk`, which answers 403 to a guest. It's sent the Login Key as
  the `authtoken` cookie. Chat accepts that, but whether this API does hasn't been tested.
- Open Logs goes to rustlesearch.dev.
- Whispers are `PRIVMSG {nick, data}`. Anything else starting with `/` is stopped in
  `command`, because sent as a message it would be posted publicly.
- Highlighted and ignored names are kept on this phone, not synced with the site.

The connected count starts from `NAMES` and follows `JOIN` and `QUIT`.

## Light and dark

The site's flair colours are chosen for a dark page. `ChatText.readable` darkens pale ones
in light mode. Colours in attributed strings have to be dynamic `UIColor`s, because
cached lines don't get rebuilt when the mode changes.

## CarPlay

Not built. Apple only allows it with a category entitlement it grants on request, and
video isn't a thing an app can show while driving, so the realistic form is audio only.
It needs a paid developer account and background audio first.

## Posting

`ChatClient.send(message:)` sends `MSG {"data": ...}`, and is only called from the
send button. Chat refuses a message with `ERR`, which shows above the message box.
The reason strings in `showNotice` are from memory of the site's client and have not
been checked, so an unknown one shows as "Message not sent (reason)".

## YouTube

iOS has a web engine, so YouTube plays in a `WKWebView`, which tvOS can't do. The page
is loaded under destiny.gg's address because YouTube refuses to play with no origin.
Taps go to YouTube's player, so its close button stays up rather than auto-hiding, and
swiping the video doesn't switch embeds there. Use the pills instead.

## Testing without a device

The simulator needs the iOS runtime: `xcodebuild -downloadPlatform iOS`. These launch
environment values only exist in Debug builds, except the first two:

| Value | Does |
|---|---|
| `DGGTV_TEST_STREAM=<url>` | Plays a known-good stream |
| `DGGTV_SILENT` | No sound |
| `DGG_TEST_SIGNED_IN` | Shows the message box. What's sent only appears locally |
| `DGG_TEST_POLL` | Plays a made-up poll, and its votes go nowhere |
| `DGG_TEST_YOUTUBE=<id>` | Opens that video |

Pass them to `simctl launch` with a `SIMCTL_CHILD_` prefix. A real poll that starts during
a test replaces the made-up one.
