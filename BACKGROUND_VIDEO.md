# Background video (macOS)

> This is an unofficial modification of
> [Ghostty](https://github.com/ghostty-org/ghostty), not affiliated with or
> endorsed by the Ghostty project. These notes cover only the background video
> feature added on top of it.

Plays a looping video behind every terminal window. macOS only.

## Quick start

1. For YouTube links, install `yt-dlp` and a JavaScript runtime it can use:
   `brew install yt-dlp deno`. Local files and direct links need nothing.
2. Open **View > Background Video…** (Cmd+Shift+B), paste a link or choose a
   file, and press **Play**.

The panel saves its values to `~/.config/ghostty/background-video.conf`
(`$XDG_CONFIG_HOME` is respected). That file is loaded after every other config
file, so it wins over the same options set elsewhere.

## Sources

- A local file path.
- A direct link to a video file or an HLS stream (`.m3u8`).
- A page URL such as a YouTube video or live stream, resolved with `yt-dlp`.

H.264 only: AVFoundation cannot play YouTube's VP9/WebM streams.

## The panel

| Control | What it does |
| --- | --- |
| Link field, **Choose File…**, **Play**, **Turn Off** | Pick the video, start it, or remove it. |
| **Pause** / **Resume** | Pauses by hand until resumed or until another video is played. Also in **View > Pause Background Video** (Opt+Cmd+B). |
| **Dim** | How strongly the terminal background color covers the video. |
| **Blur** | Blur radius applied to the video. |
| **Volume** | Volume, `Off` by default. Only streams that carry audio have any. |
| **Frame rate** | Highest frame rate to use, 30 or 60, for web links. |
| **Keep playing in background** | Do not pause while the windows are covered or minimized. |
| **YouTube account** | **Sign In…** / **Sign Out**, see [YouTube notes](#youtube-notes). |

Dim, Blur and Volume apply live. Changing the frame rate resolves a web link
again, which takes a few seconds.

## Config keys

| Key | Default | Meaning |
| --- | --- | --- |
| `background-video` | unset | Path or link of the video. |
| `background-video-opacity` | `0.3` | How strongly the background color covers the video, `0` to `1`. |
| `background-video-blur` | `2` | Blur radius in points, `0` for sharp. |
| `background-video-volume` | `0` | `0` (muted) to `1`. |
| `background-video-play-in-background` | `false` | Keep playing while no window showing the video is visible. |
| `background-video-max-fps` | `60` | Highest frame rate for sources that offer several. |

While a video is set, `background-opacity` does not apply; it applies again
once the video is turned off.

## How it behaves

- One video is shared by every window and tab, so they decode a single stream.
- With the default `macos-titlebar-style = transparent`, the video also fills
  the titlebar area, so it covers the whole window. Other titlebar styles were
  not tested.
- It pauses while no window showing it is visible, unless **Keep playing in
  background** is on. It stops while no window is open.
- Resolution is capped at 1080p. HLS is preferred over single-file streams.
- The frame rate cap picks the `yt-dlp` format and filters HLS variants by
  their `FRAME-RATE`. Local files and direct links play at their own rate. At
  30 fps a 60 fps source may only offer lower resolutions: the HLS list of the
  video this was tested with had 30 fps variants only up to 480p.
- Stream URLs from `yt-dlp` expire after a few hours, and networks drop. A
  stream that fails or does not start within 30 seconds is resolved again with
  an increasing delay, from 5 seconds up to 5 minutes.

## YouTube notes

- `yt-dlp` needs a JavaScript runtime for YouTube; `deno` works.
- **VPNs such as Cloudflare WARP** can make YouTube answer `Sign in to confirm
  you're not a bot`, and then the video does not load. Turn the VPN off, or sign
  in as described below.
- **Sign In…** opens Google's sign-in page in a web view of its own, apart from
  your browsers. Once signed in, the cookies are saved to
  `~/Library/Application Support/<bundle id>/youtube-cookies.txt`, readable
  only by you. They are a **fallback**: a plain `yt-dlp` run goes first, and the
  cookies are used only when YouTube asks to confirm the request is not a bot.
  A signed-in session changes which formats `yt-dlp` can see, and the HLS ones
  can disappear. **Sign Out** deletes the file and clears the web view's data.
- Google may ask for extra verification when signing in from a new device, for
  example a video selfie. The web view may not be able to complete it.
- A long video with no HLS format cannot be streamed: the player does not start
  its single-file stream. Download a clip and use **Choose File…** instead.

## Saving CPU

- Use 30 fps.
- Lower the blur, which costs more the larger the frame is.
- Prefer a local file.
- Leave **Keep playing in background** off.

## Building

`zig build -Doptimize=ReleaseFast` with Zig 0.16 builds the app to
`macos/build/ReleaseLocal/Ghostty.app`. It is signed ad hoc and keeps the
official bundle id `com.mitchellh.ghostty`, so macOS may ask again for
permissions you gave the official app. Add `auto-update = off` to your config so
an official update does not replace it.

## Where the code is

- `macos/Sources/Features/Terminal/BackgroundVideo.swift`: player, `yt-dlp`, HLS.
- `macos/Sources/Features/Terminal/BackgroundVideoPanel.swift`: the panel and
  `background-video.conf`.
- `macos/Sources/Features/Terminal/BackgroundVideoLogin.swift`: YouTube sign-in.
- `src/config/Config.zig`: the `background-video-*` keys.
