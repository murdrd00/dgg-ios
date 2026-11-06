# DGG for iPhone

Native iOS client for destiny.gg. `DGGKit` and the emote, chat text and player code
were copied from [dgg-tv](https://github.com/murdrd00/dgg-tv), whose NOTES.md explains
how the protocol, emote engine and Kick latency work. This file covers what's
different on a phone.

## Status

Builds for the iOS Simulator and for devices. **It has not been launched yet**, on
either: every screen below is untested, so expect layout fixes on first run. The chat
client changes were tested against live chat from the command line, read-only.

Not built yet: Picture in Picture and audio in the background. Leaving the app stops
the stream, as on TV.

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

Still worth measuring on a phone: rows use a `UITextView`, which is heavy. If scrolling
drops frames, drawing text into a plain layer is the next step.

## Coming back from the background

iOS freezes the app, so the socket can return dead with nothing to say so. The
watchdog would take 45 seconds to notice. `reconnectIfStale` reconnects at once if
nothing has arrived for 8 seconds, and takes about 0.1s against live chat. It skips the
backoff on purpose. Going through `noteDisconnect` took 4.4s, because the dead socket's
last callback started a second backoff.

The server replays its last 150 lines on every connect, so `.history` drops lines
already on screen, matched on nick, time and text. Replayed lines get new ids, so ids
can't be used for this.

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

`xcrun simctl` needs the iOS runtime: `xcodebuild -downloadPlatform iOS`.
`DGGTV_TEST_STREAM=<url>` and `DGGTV_SILENT` still work as launch environment values.
