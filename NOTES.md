# DGG for iPhone

Native iOS client for destiny.gg. `DGGKit` and the emote, chat text and player code
were copied from [dgg-tv](https://github.com/murdrd00/dgg-tv), whose NOTES.md explains
how the protocol, emote engine and Kick latency work. This file covers what's
different on a phone.

## Status

Runs on an iPhone 14 Pro as well as the simulator. Posting, audio in the background and
the lock screen controls have all been used on the phone. Still unconfirmed: whispers,
Stalk with a real Login Key, and how scrolling and battery hold up over time.

CarPlay isn't built, though the showcase image includes it. See below.

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

## Listening

Audio only drops the stream to its smallest rendition and removes the player views, so
AVPlayer stops decoding video. Twitch has a true audio rendition. Kick's lowest is 160p
video, which still downloads but is never decoded. The setting is remembered. In portrait
and landscape it swaps the picture for `AudioBar`, which gives chat the room.

Leaving the app keeps the sound going through `audiovisualBackgroundPlaybackPolicy`
and drops to the same low quality, unless Picture in Picture is showing the picture. With
the Settings toggle on, leaving floats the video instead. YouTube can't do any of this,
since it's a web player, and leaving pauses it.

A floating picture belongs to one player layer, so while it's up a change of stream
reloads that player rather than swapping to the other one.

`NowPlaying` drives the lock screen, Control Center and headphones. Next and previous
step through the embeds, and grey out at the ends of the list. Pause and every seek
command are off, because it's all live, so headphones can't pause it either. Play stays:
iOS stops the player for a call or lost headphones, and after 5 seconds it reloads to
get back to live. The simulator's lock button doesn't lock it, so check this on a phone.

## CarPlay

A real CarPlay app needs an audio entitlement Apple grants on request, which needs a paid
developer account. It would list the embeds and hand off to the audio code above.

Until then, CarPlay's own Now Playing screen should work for any app playing audio, with
`NowPlaying` supplying the title and next and previous. Not tested in a car.

## Posting

Sending is a one second hold on the button by default, with a ring that closes as it
counts, because the keyboard's own send key got pressed by accident. Return does nothing
now. iOS always keeps a key in that corner, so it's a plain grey one. Hold to send can be
turned off in Settings.

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
| `DGG_STAGE=<image>` | README screenshots: that picture and sample chat, with no connection to chat |
| `DGG_STAGE_AUDIO`, `DGG_STAGE_POLL` | Add audio only and a sample poll to the above |

Pass them to `simctl launch` with a `SIMCTL_CHILD_` prefix. A real poll that starts during
a test replaces the made-up one.

## Delay on Kick

`LiveEdge` matches dgg-tv: one Minimize latency switch, and a single skip after a stream
opens rather than speeding up. dgg-tv's NOTES.md has the measurements. The one difference
is that pausing is allowed here, so only a player stuck waiting counts as frozen. Checked
in the simulator as far as the skip firing, since Kick has no picture there. Judge it on
a phone.

## AngelThump

Embeds like `#angelthump/ozma` play. Its web player asks `vigor.angelthump.com/<channel>/token`
for an anonymous token, sending a fixed `Identifier` header, and then plays
`vigor.angelthump.com/hls/<channel>.m3u8?token=...`, an ordinary HLS stream. The app does
the same, once per open. Live status and titles come from `api.angelthump.com/v3/streams`.
Before this, an unknown platform in the site's feed was dropped, so an AngelThump-only
Big Screen showed nothing at all. Minimize latency is Kick only, so these run about 25s
behind.

It stalled every so often with a 4s forward buffer: one quality at about 4.5 Mbps, and
segments that take 0.4s to start arriving, so a single slow one ran it dry. It now buffers
up to 30s ahead like rewritten Kick, which doesn't change the delay.

## Pause and losing signal

Pause is back, in the middle of the picture, the audio bar, the lock screen and headphones. Playing
again within 5s carries on; after that it reloads at live.

AVPlayer rides out a short loss by itself. After a long one, like a drive through a dead
zone, the stream failed or sat waiting and needed a tap on play. Now, unless paused, a
stream that's failed or quiet for 15s is reopened, backing off from 3s to 30s between
tries, and at once when `NWPathMonitor` says the connection is back. With no connection
at all it restarts the player on the last address that worked instead of asking for a
new one, so the player is left trying rather than failing at once. A failure without
signal no longer counts against Kick's rewritten playlists.

Untested on the road. iOS may suspend an app whose audio has stopped, and nothing here
runs while it's suspended. If that's what happens, it will still pick up when the app
is opened or play is pressed, but not by itself.
