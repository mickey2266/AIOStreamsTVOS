Disclaimer: This project is vibecoded with Claude. The web app itself is the official web app from the aiostreams repo, but all the stuff on top to make it work for tvOS is courtesy of Claude.

# AIOStreams for Apple TV

The [AIOStreams](https://github.com/Viren070/AIOStreams) web app's standalone build (the one that
signs in to any Jellyfin server) on tvOS, playing through
[AetherEngine](https://github.com/superuser404notfound/AetherEngine). The page draws every screen
and the player's controls, unchanged; this app shows it in a web view over the player, as the
desktop and Android apps do, and turns the Siri Remote into the keys the page already handles.

It is unofficial and experimental. It uses private tvOS APIs, so it can't go on the App Store; the
IPA is sideloaded.

## Installing

Needs an Apple TV on tvOS 18 or later. The IPA is unsigned, so a sideloading tool that handles
Apple TV signs it with your own Apple ID before installing it; with a free Apple ID the signature
lasts 7 days, with a paid developer account a year.

- **From a sideloading source**: add
  `https://raw.githubusercontent.com/mickey2266/AIOStreamsTVOS/main/altstore/source.json` to an
  Apple TV sideloader that reads AltStore-format sources (FlareStore, for one). It lists every
  release and offers each new one as an update. AltStore and SideStore can add it too, but neither
  installs to an Apple TV.
- **By hand**: download `AIOStreams.ipa` from the latest
  [release](https://github.com/mickey2266/AIOStreamsTVOS/releases/latest), or the **Nightly**
  prerelease for the newest build of `main` or of a branch built by hand (its notes name which), and
  open it in your sideloading tool.

Then sign in to your Jellyfin server in the app, as in AIOStreams' web app. For Dolby Atmos, set
the Apple TV's **Settings → Video and Audio → Audio Format** to **Auto**, and keep **Continuous
Audio Connection** off (see Dolby Atmos below).

## How it fits together

```
┌──────────────────────────── screen ────────────────────────────┐
│  WKWebView, transparent: the web app and its player controls   │
│        ▲  window.aiostreamsApp: JSON messages both ways        │
│  SubtitleOverlay: the engine's subtitles, in the page's style  │
│  AetherPlayerView: AVPlayer's picture, or the engine's own     │
└────────────────────────────────────────────────────────────────┘
```

The web layer follows the working aiostreams-tvos project, which loads an AIOStreams server's own
page the same way:

- **The web view** is WKWebView. tvOS ships WebKit but leaves it out of the SDK, so `AIOWebView.m`
  loads it with `dlopen` and calls it through the Objective-C runtime.
- **The page** is `packages/web`'s standalone build, bundled in the app as `WebBuild` and served by
  a URL scheme handler at `aiostv://localhost/`, so it has an origin of its own for sign-ins and
  settings.
- **Filling the screen:** WebKit fits the page to the screen less tvOS's safe area but draws it
  from the left edge, leaving a strip on the right. The app cancels the safe area and hands the web
  view the whole screen to lay out in (`fillScreen`).
- **The focus ring:** WebKit only counts the page focused while its content view is first responder,
  and `:focus` and `:focus-visible` need that. The app makes it first responder after each load and
  whenever its own screens close (`focusPage`).
- **The remote:** `AppWindow` takes the remote's presses and swipes before WebKit's content view
  can, and hands them to the page as keys through `__aioTV`.
- **The bridge** is the page's `window.aiostreamsApp`, added by a user script at document start.
  Page to app goes through `webkit.messageHandlers.aiostreamsNative`; app to page through
  `evaluateJavaScript`, which never blocks the app.
- **The player** is [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (LGPL),
  added through Swift Package Manager by the local package `Packages/AetherHost`. FFmpeg reads the
  file and repackages it for AVPlayer, so VideoToolbox decodes and tvOS presents the video and sound
  as it does for its own apps; what AVPlayer can't decode (AV1 without hardware, VP9, MPEG-2, VC-1)
  the engine decodes itself. `AetherPlayer` and `PlayerChannel` follow AIOStreams' Android
  `PlayerChannel`: the same messages, so the page is unchanged.
- **`Packages/AetherHost`** pins the engine's version and re-exports it. The engine's optional
  components are package traits, which XcodeGen can't set, so they're turned on there: TrueHD
  Atmos and DTS:X object rendering are on, for the page's Object audio switch; the Dolby Vision
  ones are off.

### Dolby Atmos

The point of the switch from mpv, which decodes every sound itself and so sends a receiver plain
PCM and never Atmos.

- **E-AC-3 with Atmos (Dolby Digital Plus JOC)**, the Atmos of streaming services and most web
  releases, is copied into the stream AVPlayer plays untouched, and tvOS sends it to the receiver
  as Dolby MAT. The receiver shows Dolby Atmos.
- **TrueHD, DTS and DTS-HD** can't leave an Apple TV as a bitstream, so they're decoded to
  lossless multichannel PCM (up to 7.1), as Infuse plays them, whatever the passthrough setting.
  TrueHD Atmos and DTS:X play as their 7.1, without the objects and heights. A receiver takes PCM
  over HDMI or eARC; a soundbar behind a TV's plain ARC gets stereo.
- **Object audio** (Settings → Audio → Output on the page, tvOS only, off by default, from the
  next video; `patches/web/0012-tvos-object-audio-switch.patch`): the engine renders TrueHD Atmos
  objects and DTS:X heights into the Speakers layout under the switch, 7.1.4 (the default) or
  9.1.6. Since AetherEngine 7.57 it builds that bed from the track's own lossless 7.1 (DTS:X's 7.1
  with its heights folded in), with the objects and heights steering it onto the speakers above
  and around, rather than mixing a decode of the objects themselves. tvOS sends it to the receiver as 12 or 16
  channels of PCM inside Dolby MAT, so it shows Atmos; the receiver fits it to the speakers it has,
  so 7.1.4 is the one for every smaller system. 9.1.6 places objects on wides and middle heights
  instead of leaving the receiver to spread them there. The switch and Speakers show only with
  Audio channels on Automatic: 7.1 is a limit too and plays the 7.1, and Stereo or 5.1 mix it
  down. Needs tvOS 26, a 48 kHz track, and dialogue boost and night mode off, which shape the
  sound (the engine puts shaping ahead of the render); anything else plays its 7.1 as above. With it on, the automatic audio pick prefers a
  TrueHD Atmos or DTS:X track over another format in the same language. The statistics' Object
  audio line shows the bed and the objects playing. On the engine's software player (below) the
  same engine setting also hands an E-AC-3 Atmos track to tvOS's renderer compressed, which
  played nothing when tried (de850fa), so that case may be silent with the switch on. In the
  picture-in-picture window the silent Dolby Atmos stream the engine plays beside a rendered bed,
  so a receiver shows Atmos (`AtmosOutputActivator`), stops: with it, the bed played nothing in the
  window, with or without a display mode switch. Some receivers may show multichannel PCM rather
  than Atmos for the window. Not yet tried on a receiver.
- **What turns Atmos off**: the page's Audio channels set to Stereo or 5.1 (the engine decodes the
  sound to fit), and any output but HDMI, which alone carries Dolby MAT: Bluetooth gets a stereo
  mix, AirPods a spatial render. So does video the engine decodes itself (AV1, which no Apple TV
  decodes in hardware, VP9, or anything with Hardware decoding off): it plays an E-AC-3 Atmos
  track's 5.1 or 7.1 bed as PCM.
- **The audio session** is only activated when a video starts. Activating it at launch, as the mpv
  build did, fixes the HDMI route at what the link reported then, which with Continuous Audio
  Connection off is 2 channels (AetherEngine#24). With it off, the link is still at 2 channels
  as a video starts too, and asking for those 2 holds it there, so the app never asks for 2 or
  fewer: it asks for the full width only once the link offers more than stereo, when the route
  changes and as the picture starts, then one, three and six seconds later. That doesn't always
  get the full width (see Continuous Audio Connection below). The statistics' PCM output is the
  channels sent, not the link's width (32 with the setting on). The app menu's Audio output line
  gives the channels in use, the most the route takes and the number asked for.

For Atmos at all, set **Settings → Video and Audio → Audio Format** to **Auto** (or Change Format →
**Dolby Atmos**) on the Apple TV.

**Settings → Video and Audio → Audio Format → Continuous Audio Connection** decides how decoded
sound reaches the receiver. **Keep it off.** Turn it on only if surround the Apple TV decodes
(TrueHD, DTS-HD, or any track the page reshapes) keeps playing as stereo, and turning on the app
menu's Dolby primer (below) doesn't fix it. With it on, decoded sound reaches the receiver as
multichannel, but it may use the wrong channel mapping, with surround channels playing from the
wrong speakers.

With it off, some setups take decoded sound only as stereo. On a TV and soundbar on eARC that do:

- Sound the Apple TV decodes plays as stereo: TrueHD and DTS-HD, and any track the page's Audio
  channels, dialogue boost or night mode reshapes. The session asks for 8 channels and gets them
  (`preferred=8`), but tvOS keeps the HDMI output at 2 (`HDMIOutput[ch=2]`, `output=2`), so the
  decoded PCM is downmixed. Infuse and Plex users report the same with Samsung TVs and soundbars
  on eARC. E-AC-3 and AC-3 played as a stream copy are unaffected: they reach the soundbar still
  encoded, E-AC-3 Atmos inside Dolby MAT on a 2-channel carrier, and the soundbar decodes every
  channel itself (Dolby's 7.1.4 demo plays in full with the setting off).

  A Dolby bitstream widens the link, and it stays wide for the PCM that follows: Infuse played
  TrueHD as stereo PCM, then as multichannel PCM after a switch to the E-AC-3 track and back,
  and this app's TrueHD did too from then on. A second of silent Dolby played before the video
  loaded didn't do it: the load's silence let the link fall back to stereo. So, with the app
  menu's **Turn the Dolby primer on** (off by default, kept across launches, from the next video),
  silent Dolby Digital Plus Atmos (AetherEngine's `silent-atmos.mp4`) plays through every load, a return from
  the background and an audio track switch, and stops a few seconds after the video's own sound
  has started, so the two overlap as in Infuse. That widens the link (the soundbar shows Dolby),
  but the video's player has set its sound output up at stereo by then and keeps it: the soundbar
  showed stereo PCM until a pause and play by hand, then multichannel PCM. When the pause comes
  matters. Paused just as the Dolby stopped, the link was silent for half a second, fell back to
  stereo, and no later pause and play brought it back. Paused while the Dolby still played, it
  stayed at stereo once the Dolby stopped. Paused by hand some seconds after the Dolby had
  stopped, with the TrueHD playing on, it went to multichannel, twice. So the Dolby stops three
  seconds after the first frame while the video plays, and five seconds later a video whose sound
  the Apple TV decodes over more than 2 channels pauses for a second and plays again. The page
  isn't told about the pause. The video also loads paused and waits 3 seconds under the Dolby,
  the page still showing buffering, so the soundbar has switched to it before the video plays.
  The hold alone left the soundbar at stereo PCM; the hold with a pause and play after it gave
  multichannel PCM. A 0.3-second pause two seconds after the Dolby wasn't enough on a Samsung
  soundbar, which needed a second pause and play by hand. Measured from a cold link, with the pause five seconds after the
  Dolby and a second long: TrueHD showed Dolby during the load, then stereo PCM, then
  multichannel PCM after the pause, about eight seconds in, with about three seconds of silence
  as the soundbar switched. DTS and DTS-HD did the same, and so did a return from the background
  and an audio track switch. Not yet
  measured: whether every 7.1 channel reaches its own speaker. The app menu's Dolby primer line says whether the
  Dolby played and whether the video was paused and played, or that the primer is off. Its route reads 2 channels either
  way, so only the soundbar shows whether it worked.
- Picture in picture closes on an HDR or frame-rate video: the window opens, the video goes back
  full screen, then the TV goes to the Home screen.

With it on, both work: multichannel PCM and the window over the Home screen. It may use the wrong
channel mapping, though, which is why it's best off, with the Dolby primer on where decoded
surround plays as stereo. With it on,
tvOS sends all sound inside Dolby MAT, decoded PCM included, which the TV passes over eARC intact;
with it off, decoded sound goes out as plain PCM, which this TV's eARC takes only as stereo. The
picture-in-picture failure is likely, but unconfirmed, tvOS setting the HDMI audio link up again
at the change of sound format as the window opens. `max=32` shows
in the route with the setting off too, so the route doesn't tell the two settings apart. The player's statistics show the track, its decoder and the
output: `E-AC-3 Atmos passthrough` is Atmos on its way to the receiver. The app
menu (hold Play/Pause) and the diagnostics add the audio route and the engine's recent audio log.

When a video freezes or falls behind its sound, the same report has the playback health: the
buffer held ahead (and its lowest in the last 30 s), stalls, dropped frames, the rate the video
plays at against what the source delivered, and producer restarts. A buffer that runs dry with
the source below the video's rate is the network; a full buffer with frames dropping is the
picture falling behind. The source is read over one held connection by default (AetherEngine's
`heldSourceConnection`, HTTP/1.1 only), rather than ranged requests that start again at least
every 128 MB, every dozen seconds of a remux. Either way, a connection that runs below the video's
average rate for 8 seconds while the player waits on it is replaced by a new one (three in a row,
then it rests two minutes), as debrid CDNs often slow one connection and serve a new one at full
speed. The menu's **Use ranged source requests** switches back,
from the next video, and **Hold one source connection** returns to the default.

The menu's **Play a test video…** plays an http(s) link you type (a file or an HLS playlist; the
last one is remembered) in the page's own player, with its controls, track menus, statistics and
picture-in-picture button, and its player settings. The app opens it with an
`aiostreams://test-video?url=…` link, which a web patch adds along with the page that plays it
(`patches/web/0006-test-video-page.patch`); nothing is reported to the server. A video already open
closes first, Back stops the test video, and the menu reports on it as on any video.

### HDR

- **HDR10, HDR10+ and HLG** reach the TV in their own mode. The engine asks tvOS for
  the matching TV mode at the video's frame rate before it plays, and for the TV's own mode when
  playback stops. tvOS only switches with **Settings → Video and Audio → Match Content** (Dynamic
  Range, and Frame Rate if you want that too) turned on.
- **Dolby Vision** reaches a Dolby Vision TV in its own mode; profile 7 plays as single-layer
  profile 8.1. The page's **Dolby Vision** switch (playback settings, Video) turned off plays the
  base layer there instead, from the next video. On a TV without Dolby Vision it always plays as its base layer (AetherEngine's
  `dolbyVisionHandling = .baseLayerOnly`): profiles 7, 8.1 and 8.4 as HDR10 (with any HDR10+
  metadata) or HLG, with no profile 7 to 8.1 conversion and no Dolby Vision work for AVPlayer per
  frame. Profile 5 has no base layer and keeps playing as Dolby Vision, tone-mapped by AVPlayer.

### Subtitles

The engine decodes them, text, ASS and PGS, DVB and DVD pictures, and the app draws them over the
video (`App/Player/SubtitleOverlay.swift`). Text takes the page's style: colour, outline,
shadow, box, size and position, in the units the page sends for mpv. Pictures (PGS, DVB, DVD)
keep the disc's look and place, drawn 20% under the disc's size at Normal and scaled by the
page's subtitle size, which the player's controls step too.

ASS and SSA go to libass (`App/Player/AssRenderer.swift`, from
[swift-libass](https://github.com/mihai8804858/swift-libass)), as mpv drew them: the file's
styles, positioning, animation, karaoke and drawings. Dialogue is drawn 20% under the file's size
and scaled by the page's subtitle size, as the text subtitles are; signs keep theirs. Fonts
come from tvOS through CoreText, and from a script's own `[Fonts]` section; fonts attached to an
MKV aren't read, as the engine doesn't hand them over, so a typeset that names one gets the
nearest tvOS font. When the page forces its style on ASS, they're drawn as plain text in that
style instead.

The page's automatic subtitle sync lines an added subtitle (an addon's, the server's or your own)
up with one of the file's own tracks. The app answers its `player-subtitle-lines` asks: the engine
decodes that track on its second subtitle channel, without drawing it, and the app sends the page
each line's start and end as it comes. A file with no subtitles of its own has nothing to sync
against.

### Trailers

YouTube trailers play in the player. The app asks YouTube's player API for the video's stream, as
AIOStreams' desktop and Android apps do (`App/Player/YouTube.swift`). Where YouTube gives none,
the page opens the trailer's link, which goes to the YouTube app if it's installed.

### Seek-bar thumbnails

Seeking shows a picture of the keyframe at or before the position, over the seek bar and in the
remote's scrub row, as in AIOStreams' desktop and Android apps. The app answers the page's
`player-thumbnail` asks the way those apps do: the newest ask wins, the picture on screen isn't
sent again, and each picture is a 384-pixel-wide JPEG the page loads from
`aiostv://localhost/thumbnail/…` (the newest 256 are kept).

AetherEngine's `FrameExtractor` makes them (`App/Player/Thumbnails.swift`): a decoder of its own on
the file that seeks to keyframes, tone maps HDR and Dolby Vision to SDR, and holds back while the
playing video is short of data. Asks are rounded to the second, so the scrub row's repeats come
from what's already made. It closes after 45 seconds without an ask, and opens the file again on
the next one.

### Picture in picture

While a video plays, the **picture-in-picture button** at the end of the player's bottom row moves
it into a small window, and the app steps back to the Home screen; the video keeps playing over the
Home screen and other apps (`App/Player/PictureInPicture.swift`). This is the Android app's
picture-in-picture, always offered: the page's Android app section, with its switch for it, is
hidden here. The page hides its player while the window shows. tvOS only starts it from inside an app, so
the bridge script adds the button to the page's controls, in the look of the page's own.

- The window holds AetherEngine's AVPlayer layer (`nativePlayerLayer`), and its play/pause and
  skip buttons drive AVPlayer directly; the page catches up when the app is back.
- Only videos the engine plays through AVPlayer get the button. One it decodes itself (its
  software route) draws into a sample buffer display layer, which tvOS never puts in the window
  (Apple feedback FB9751461, which also kept mpv out).
- Text subtitles show in the window through the engine's native subtitle rendition
  (`prepareNativeSubtitles`), selected only while the window shows; picture subtitles (PGS, DVD)
  and ASS styling don't, as the app's overlay can't leave the app.
- An HDR video, or one at its own frame rate, has the TV in a mode of its own, and tvOS gives the
  Home screen its mode back when the window opens. Done there, in the background, that switch left
  the window's video paused for good, so the app switches first: it drops the engine's display
  criteria, waits for the TV to settle (the screen goes black for about 2 seconds, in the app),
  plays the video again if the switch paused it, waits until it plays (and half a second more),
  then opens the window. Opened a hundredth of a second after the play, the window began to start
  and tvOS never said it showed, so the app stayed in front instead of going to the Home screen;
  if tvOS stays silent 2 seconds on and the window shows, the app goes anyway. The criteria go back when
  the video returns to the app. Only a video that switched the TV when it started does this (the
  app watches tvOS's mode-switch notifications); the rest open the window straight away.
- Opening the app again, or the window's full-screen button, puts the video back in the app. tvOS
  ignored the app's ask to close the window made the moment it was back (the window stayed over
  the app), so it asks 0.6 s later, and again every 0.6 s while the window shows, four times at most.
  Closing the window pauses the video, as on Android. Only a return from the background counts
  as opening the app again: tvOS takes focus from the app and gives it back while the window
  settles, and when it ignores the first Home screen ask (often just after a mode switch), and
  taking that for a return put the video back full screen just as the app left for the Home
  screen.
- The app has the `audio` background mode, which tvOS needs to keep playing in the window, and the
  engine keeps its session through the background while the window shows.
- The audio session's long-form audio policy, which the app and the engine declare on tvOS for
  HDMI, doesn't block the window here; it blocks picture in picture only on iOS, where the engine
  declares the default policy instead. If tvOS doesn't allow the window within 4 seconds, the
  button says it isn't available.

### Top Shelf

With the app in the top row of the home screen, the Top Shelf shows **Continue Watching** and
**Next Up** from your Jellyfin server. The page already builds this list for Android TV's Watch Next
row (the home page's resume points and next episodes, 10 at most) and sends it as a `watch-next`
message whenever it changes, and an empty one on sign-out. The app saves it in an App Group
container it shares with its Top Shelf extension (`TopShelf/`), and tells tvOS to ask the extension
again.

- Selecting a title opens its page in the app (`aiostreams://item/…`); Play plays it, from where it
  stopped (`aiostreams://play/…`).
- The list is as of the app's last run: the page asks the server again a couple of seconds after
  the app leaves the screen, and the app stays awake that long.
- With nothing to show, tvOS shows the Top Shelf image instead.
- The App Group is `group.io.github.aiostreams.tvos`. The CI build ad-hoc signs the app and the
  extension with it, so a sideloading tool can carry it over when it re-signs. Some tools swap it
  for generic groups (`group.<hash>.1` to `.5`) in no set order, so the app writes the list to every
  group it's signed with, and the extension reads the newest copy from any of them.
- The app menu (hold Play/Pause) and the diagnostics the page asks the app for show the groups,
  the extension's bundle ID and profile, the page's list and when tvOS last asked the extension. If
  tvOS never asks, restart the Apple TV once after installing.
- The extension needs a profile of its own, for an App ID under the app's with the same App Group.
  A certificate with one explicit profile signs both with the app's App ID, and tvOS doesn't run
  the extension then.
- The extension links with `-e _NSExtensionMain` (`project.yml`). On Xcode's own entry point it
  exits as tvOS starts it on tvOS 27.2, and the Top Shelf shows only its image. With this one, an
  update sent while the app sat in the top row once failed with "Connection refused (os error 61)";
  builds then all had the same build number, and each now has its own. If an update fails that way,
  move the app out of the top row, update, and move it back.

### Memory

tvOS ends WebKit's web content process when it holds too much, and the page then loads again. What
kept that from happening while browsing:

- **Artwork size.** The page sizes artwork from the screen, which on a 4K TV asked for 3840-wide
  backdrops, 32 MB each once decoded. A TV now asks for no picture wider than 1920 pixels
  (`patches/web/0015-tvos-pictures-at-most-1920-wide.patch`), so a backdrop is 1920×1080 at most,
  8 MB, as tvOS's own apps draw them. The bridge script also reports a device pixel ratio of 1.
- **Cards near the screen only.** Long rows and the Discover grid draw only the cards near the screen
  and hold the others' places empty (patches 0001 and 0002); the grid draws within one screen's
  height above and below. A grid is 10 or 12 posters across on a TV, so a wider margin kept 300 or
  more cards mounted.
- **Pictures let go of.** The bridge script swaps a picture more than three screens away (cards'
  artwork, backdrops and logos) for a blank one, which lets WebKit drop its decoded copy, and puts
  it back within two. It does the same for every picture on a page kept out of sight: the home page,
  kept under every other page, and the whole page while the player shows. They come back as that
  page is drawn again. When tvOS warns of low memory, it lets go of all but a little past the screen.

The app menu (hold Play/Pause) shows the app's memory, the pictures, cards and elements the page
holds, and, when the page's process was ended, what it held just before.

Two more of the bridge script's switches, set while chasing those memory kills, are still off:

- **`EFFECTS`**: no masks, filters or backdrop filters anywhere. WebKit draws each into a surface
  of its own at the TV's 2x scale, and the kills came within a second or two of an item page
  opening its version picker, which draws its backdrop under two masks or a poster under a blur
  across most of the screen. Edges that would fade end sharply, and blurred washes are plain.
  The few washes the page needs are drawn once on a tiny canvas instead (patches 0004 and 0005).
  The one exception: with the page's **Blur episodes you haven't started** on (Settings →
  Interface → Spoilers), the episode pictures and text it blurs keep their filters.
- **`LAYERS`**: nothing kept as a layer at rest (`will-change`), except the glide layers the slides
  use, and loading placeholders hold still instead of pulsing. The rotating hero kept several
  full-screen backdrops as standing layers, about 33 MB each at the TV's 2x.

Setting either back to `true` in `App/Web/BridgeScript.swift` draws them again.

### Posing as the Android TV app

The web app picks its behaviour from the bridge's `platform`, and only knows `android`, `windows`,
`macos` and `linux`. To leave the AIOStreams repo untouched, this app reports itself as the Android
app on a TV (`platform: 'android'`, `tv: true`). That gets the TV layout, remote navigation, the
Back behaviour and the bundled-player path. It also means:

- Jellyfin lists the device as **AIOStreams Apple TV** (`patches/web/0008-tvos-named-apple-tv.patch`),
  where the Android TV app is **AIOStreams Android TV**. It's the client name the server sees too
  (`X-AIOStreams-Client`), so a config expression written for Android TV doesn't match it.
- The bridge also says `appleTv: true`, and a web patch
  (`patches/web/0007-tvos-hides-settings-it-ignores.patch`) hides the Android settings that do
  nothing here:
  - The whole **Android app** section: updates (none here), **Play in the background** (leaving
    the app pauses the video), the mpv.conf editor, and **Picture-in-picture**, whose button the
    player always shows. Its **Report a problem** row goes with it; the app menu (hold
    Play/Pause) has the app's diagnostics.
  - **Match the video's frame rate**: tvOS's own Match Content decides.
  - **Tunneled playback**.
  - **Engine**.
  - **Pass surround audio through** and its formats: an Apple TV copies Dolby Digital (Plus) and
    decodes the rest to PCM whatever is asked.
- Settings → About names the app's version **tvOS app**, and its Credits list AetherEngine as the
  player, with FFmpeg, dav1d, libdovi, LibTrueHD, libzvbi, libass and VideoToolbox, rather than mpv
  (`patches/web/0010-tvos-about-names-its-engine.patch`). They're in English only.
- Settings → **Donate** lists the GitHub Sponsors and Ko-fi links as text
  (`https://github.com/sponsors/Viren070`, `https://ko-fi.com/Viren070`) rather than buttons that
  open them, as a TV has no browser to open them in (`patches/web/0011-tvos-donate-shows-links.patch`).
- On a TV, the remote moves focus along a row of posters and the row scrolls only when the next
  poster would leave the screen, rather than the focus staying where the row's first poster starts
  while the row slides under it (`patches/web/0013-tvos-rows-move-focus.patch`). Keys and a
  gamepad elsewhere keep the page's own behaviour.
- A keyed move up or down scrolls the page rather than jumping and easing the whole page back as one
  layer its height, which juddered on an Apple TV even on the settings page
  (`patches/web/0014-tvos-scrolls-can-skip-layers.patch`). The scroll is WebKit's own smooth scroll
  (`patches/web/0017-tvos-webkit-smooth-scrolls.patch`): the page's own easing set the scroll
  position from the page's thread every frame, so any long task there, such as a row's cards
  mounting, stalled it. `NATIVE_SCROLLS` in `App/Web/BridgeScript.swift` set to `false` goes back to
  the page's easing. Rows across keep their eased layers.
- The home page's library rows start loading a screen before they come into view, and add their
  cards only once a scroll has stopped, or after 0.7 seconds of a held key
  (`patches/web/0016-tvos-home-rows-draw-between-scrolls.patch`), rather than all twenty at once in
  the middle of one.
- A home row's name is a link to its whole catalog in Discover, which the page's remote navigation
  skips. Here it's a stop of its own above the row's posters: Up from any of them goes to it, Down
  into the row from above lands on it first, and Click opens the catalog
  (`patches/web/0018-tvos-row-titles-open-catalog.patch`).
- With **Infuse** as the player (Settings → Playback → Player), the link names the video by its title,
  with the episode for an episode, rather than the file's name:
  `infuse://x-callback-url/play?x-success={returnUrl}&url={encodedUrl}&filename={title}&sub={subtitles}&position={position}`
  (`patches/web/0019-tvos-infuse-link-names-the-title.patch`). Infuse opens the `aiostreams://` link
  in `x-success` when it's done, and the page saves where it stopped.
- **SenPlayer** and **VidHub** are players to pick there too, with links of the same kind
  (`patches/web/0020-tvos-senplayer-and-vidhub.patch`):
  `SenPlayer://x-callback-url/play?x-success={returnUrl}&url={encodedUrl}&sub={subtitles}&name={title}&position={position}`
  and
  `open-vidhub://x-callback-url/play?x-success={returnUrl}&url={encodedUrl}&filename={title}&sub={subtitles}&position={position}`.

  **Hardware decoding** always shows, where the page hid it while a stored engine setting said
  ExoPlayer.
- AetherEngine always plays. The app answers the page that it plays with ExoPlayer, which like
  AetherEngine plays on the system's decoders, so the page shows ExoPlayer's statistics, filled in
  from the engine. Their Engine line names AetherEngine and its version, which the app sends with
  the numbers (`patches/web/0009-tvos-stats-name-the-engine.patch`). The **Play with mpv** retry the page offers after a failed load, when a stored
  engine setting isn't Automatic, does nothing.
- **Cache size** (Settings → Playback → Player) sizes the engine's buffer: with a size picked, it
  buffers ahead until the cache holds that much, at least about 40 seconds and at most a quarter of
  the free space, and keeps what played in the same space for seeking back. Automatic buffers 10
  minutes ahead (about 6 GB of an 80 Mbit/s remux), or as much as a quarter of the free space holds
  if that's less, so a remux rides out a slow stretch of the source; the picked sizes, 1000 MB at
  most, hold less. It applies from the next video, and only to video AVPlayer plays: the engine's
  software player keeps a fixed 96 MB ahead and 128 MB behind in memory.

## The remote

| Siri Remote                         | Does                                              |
| ----------------------------------- | ------------------------------------------------- |
| Clickpad edges / swipe              | Arrow keys (held edges repeat; a swipe up or down moves one row, or two when it's long; across, it moves as many posters as its length; an edge the swipe starts or ends on adds no arrow of its own; Left from a row's or a grid line's first poster opens the navigation)|
| Click                               | Enter (held, the page's hold actions)             |
| Click on a text field               | tvOS's search keyboard over the page, typing straight into the field (dictation on the mic button); Menu or moving off the keys closes it. The linear keyboard keeps tvOS's full-screen layout over a black backdrop, with the page showing in the space below it. The grid keyboard (Settings → General → Keyboard) sits in a black box at the screen's top right, its keys' width as measured from what tvOS draws, with the page to its left. Passwords and PINs get the keyboard in an alert |
| Click in a searchable list          | The pickers with up and down carets, such as Discover's catalog picker: picks the highlighted entry, including the one highlighted as the list opens or after a search; opens the keyboard only when nothing is left to pick |
| Up from a searchable list's top entry | Opens the keyboard to search (a held Up, or a quick run of presses, stops at the top instead) |
| Back / Menu                         | The page's Back; twice on Home leaves the app     |
| Play/Pause                          | Play/Pause                                        |
| **Hold Play/Pause (1 s)**           | App menu: the app's diagnostics (move left onto them, then swipe or click up and down to scroll), play a test video from a link, reload, switch the source connection, turn the Dolby primer on or off, or reset the app's data |

## Saved data

tvOS can drop a web view's stored data between launches, and with it the page's sign-in. The app
keeps a copy of the page's localStorage in its own settings (about 350,000 characters at most,
values over 100,000 left out), puts back what is missing as the page starts, and hears of every
change. **Reset the app's data** in the app menu clears both, then loads the page again.

## External players

Settings → Playback → Player lists Infuse, VLC and Outplayer (the app reports an iPad user agent so
the page offers the iOS presets), or a custom link. Play opens the link with `UIApplication.open`.
Infuse's `x-success` callback, `aiostreams://return/item/…`, comes back to this app, which hands it
to the page; the page saves where you stopped.

## Building

The GitHub Actions workflow builds an unsigned `AIOStreams.ipa` for Apple TV hardware. Every run
attaches it as an artifact, each push to `main` and each run started by hand (Actions → Build →
Run workflow, on any branch) replaces the **Nightly** release, and a `v*` tag
publishes a release of its own. Sign it with your own Apple ID using a sideloading tool that
handles Apple TV; with a free Apple ID the signature lasts 7 days, with a paid account a year.

### Sideloading source

Tagged releases are listed in the AltStore-format source in `altstore/source.json` (see
Installing). The build workflow adds
every `v*` release to the source (`scripts/update-source.py`: the version from `project.yml`'s
`MARKETING_VERSION`, the build the workflow's run number), so a release is tagged after
`MARKETING_VERSION` is bumped to match. The nightly isn't listed.

Each CI build's `CFBundleVersion` is the workflow's run number, for the app and its Top Shelf
extension alike, so every build installs as a newer one than the last; the pack step fails if the two
differ. The engine's prebuilt FFmpeg frameworks come with `MinimumOSVersion` 26.0 in their
Info.plists, though their binaries are built for tvOS 16, and tvOS checks every bundle's as the app
installs, so the pack step gives them the app's 18.0 and fails if any bundle asks for a newer tvOS
than the app. 1.1.0's frameworks still said 26.0, so it didn't install below tvOS 26.

On a Mac with Xcode 27 (AetherEngine supports no older one), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and Node 22+, for tvOS 18 or later:

```sh
bash scripts/fetch-web.sh       # clones AIOStreams into .build/ and builds the web app into WebBuild
xcodegen generate               # writes AIOStreamsTV.xcodeproj from project.yml
open AIOStreamsTV.xcodeproj     # Xcode fetches AetherEngine and its FFmpeg build through SwiftPM
```

The engine is pinned to one commit in `Packages/AetherHost/Package.swift`: upstream AetherEngine 7.57.0
plus the app's fork's own commits ([mickey2266/AetherEngine](https://github.com/mickey2266/AetherEngine),
branch `aiostreams-7.57`, each described there):
- the engine's software player, which plays interlaced H.264 among others, labels its 7.1 as
  CoreAudio's WAVE_7_1, so the side and rear surrounds play from their own speakers instead of each
  other's;
- remuxes read 64 MB ahead in 128 MB ranges, a connection running below the video's rate is
  replaced, and the Atmos confirmation runs on the held source connection;
- the silent Atmos stream beside a rendered TrueHD Atmos or DTS:X bed stops while the
  picture-in-picture window shows. Lossless surround (TrueHD, DTS-HD) reaches AVPlayer as FLAC. Its FFmpeg comes as
dynamic frameworks that Xcode embeds in the app; nothing else in the app may bring an FFmpeg of its
own, or it takes the engine's symbols.

`AIOSTREAMS_DIR=/path/to/AIOStreams bash scripts/fetch-web.sh` builds from a checkout you already have
instead, and `AIOSTREAMS_REF=<branch or tag>` picks what to clone. The script applies the patches in
`patches/web/` for the build and takes them out again after it, so that repo is left as it was;
`AIOSTREAMS_PATCHES=0` builds without them. They draw only the catalog cards near the screen, in long
rows and in grids, so a long scroll doesn't keep every card it passed, and save only a catalog's first
two pages on the device, so one scrolled far doesn't come back with every page at once. A collection
without landscape art, and each server's card, get their blurred wash drawn once on a tiny canvas
instead of through a CSS blur, which the TV would otherwise draw again on every frame anything over it
moves. The rest are described above: the 1920-pixel artwork limit (Memory), and the TV's names,
hidden settings, focus, scrolling and home rows (Posing as the Android TV app). The **Upstream settings watch** workflow (`.github/workflows/upstream-settings-watch.yml`)
checks upstream every Monday and keeps one issue open while its Android app settings
(`pages/settings/apps.tsx` and the section list in `pages/settings/index.tsx`) differ from the
commit in `.github/upstream-watch/settings-baseline`; put upstream's newest commit there once
you've looked, and the next run closes it. A patch that no longer applies
to AIOStreams stops the build and is named, to be redone against the new code. The app menu shows the
web app's commit and how many patches it was built with. Safari's Develop menu on a Mac can inspect
the page.

## Layout

| Folder         | What it holds                                                          |
| -------------- | ---------------------------------------------------------------------- |
| `App/Web`      | The WKWebView wrapper and scheme handler, the bridge script, storage   |
| `App/Bridge`   | JSON helpers                                                           |
| `App/Player`   | AetherEngine, the audio session, the player messages, subtitles, seek-bar thumbnails, Now Playing and remote commands, YouTube trailers |
| `App/Input`    | The window that takes the remote, the keys it becomes, the keyboard    |
| `App/Support`  | Identity, folders, the mpv.conf note, the app menu, the app's own answers, the Top Shelf list |
| `TopShelf`     | The Top Shelf extension: Continue Watching and Next Up                 |
| `Shared`       | What the app and the extension both read: the saved list               |
| `Packages`     | `AetherHost`: AetherEngine at a pinned commit, for the app to link |
| `scripts`      | Building the web app into `WebBuild` (git-ignored); adding a release to the sideloading source |
| `altstore`     | The AltStore-format sideloading source and its icon |
| `patches/web`  | Changes to the AIOStreams web app, applied only for this app's build |

## Licences

AetherEngine is LGPL-3.0 with an app store exception, and its FFmpeg build is LGPL-2.1, linked
dynamically. LibTrueHD, linked for TrueHD Atmos object rendering, is MIT, with truehdd's `truehd`
and `oamd` crates under Apache-2.0 (its `NOTICE` is in the app's Licences list). `App/Player/silent-atmos.mp4` is AetherEngine's, written by its
`Scripts/make-silent-atmos.swift` (from SpatialAudioBridge, Apache-2.0). Builds of this app are for personal use. The web app is AIOStreams', under its
licence.
