# DGG: Destiny.gg on iPhone

A native iOS app for [destiny.gg](https://www.destiny.gg). It shows the Big Screen embed list, plays streams, and runs live chat, in place of a home screen link to the site.

DGG is still in development, and there are no builds to install yet.

## Features

- The same embed list as the Big Screen page, with viewer counts
- Kick and Twitch streams play natively, and YouTube embeds play in the app too
- Low delay on Kick, adjustable in Settings
- Live chat with animated emotes, combos, flairs and greentext
- Post in chat with emote suggestions as you type, whisper, and vote in polls
- Tap a name to stalk, highlight, whisper, ignore or open their logs
- Mentions highlight the way they do on the site
- Follows your phone's light or dark mode
- Swipe the video to switch embeds, and turn the phone sideways for video beside chat

## Signing In

1. On destiny.gg, go to Profile, then Developer, and click **Create Login Key**
2. In the app, tap the gear, then paste the key under **Account**

The key stays in your iPhone's Keychain and is only sent to destiny.gg. Treat it like a password.

## Development

The chat, emote and stream code is in the `DGGKit` package under `Sources`, and the app is in `App/DGG`. The Xcode project is generated from `project.yml`, so run `xcodegen` after adding app files.

This started as a copy of the shared code from [dgg-tv](https://github.com/murdrd00/dgg-tv), and the two now change separately.

[NOTES.md](NOTES.md) has the longer story of how everything works and why.
