import Foundation

/**
 * The script WebKit runs at document start, in the main frame, before the
 * page's own. It gives the page `window.aiostreamsApp`, the bridge AIOStreams'
 * Android app gives it (protocol 2), so the unmodified web app lays itself
 * out for a TV and plays through this app's player. Follows bridge.js of the
 * working aiostreams-tvos project.
 *
 * Page to app: `webkit.messageHandlers.aiostreamsNative.postMessage(json)`.
 * App to page: `__aioReceive(message)`. The remote: `__aioTV.down/up/type`.
 */
enum BridgeScript {
    /// `storage` is the app's copy of localStorage by origin, as JSON.
    static func make(version: String, device: String, deviceId: String, hours24: Bool, storage: String) -> String {
        template
            .replacingOccurrences(of: "__VERSION__", with: literal(version))
            .replacingOccurrences(of: "__DEVICE__", with: literal(device))
            .replacingOccurrences(of: "__DEVICE_ID__", with: literal(deviceId))
            .replacingOccurrences(of: "__HOURS24__", with: hours24 ? "true" : "false")
            .replacingOccurrences(of: "__STORAGE__", with: storage)
    }

    private static func literal(_ text: String) -> String {
        JSON.string([text]).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private static let template = #"""
(() => {
  if (window.top !== window || window.aiostreamsApp) return;
  const handler = window.webkit?.messageHandlers?.aiostreamsNative;
  if (!handler) return;

  /*
   * Artwork otherwise goes through workers that shrink it on OffscreenCanvas
   * and hand back blob URLs, which tvOS's WebKit shows as broken images.
   * Without OffscreenCanvas the page loads each picture as a plain <img>.
   */
  try {
    delete window.OffscreenCanvas;
  } catch {}
  /*
   * The page asks for artwork at devicePixelRatio times its size, and tvOS
   * reports 2 on a 4K TV, so each backdrop comes as a 3840-wide picture,
   * 33 MB once decoded. A page of rows and backdrops then runs WebKit's
   * process out of memory while browsing. At 1 it takes the 1080p sizes, a
   * quarter of the memory; tvOS's own apps draw artwork at that size too.
   */
  // WebKit's own ratio, which it still draws at, kept for the memory log.
  let drawScale = 0;
  try {
    drawScale = window.devicePixelRatio || 0;
  } catch {}
  try {
    Object.defineProperty(window, 'devicePixelRatio', { get: () => 1, configurable: true });
  } catch {}

  /*
   * The page's Casual and Cursive subtitle fonts are CSS stacks of faces
   * tvOS doesn't have ("Comic Sans MS", casual, sans-serif and "Segoe
   * Script", "Snell Roundhand", cursive), so its previews drew both in the
   * system's sans serif. The app carries Comic Neue and Dancing Script
   * (App/Fonts, SIL Open Font License), served at /app-fonts/; they're
   * declared here under the names first in each stack, which the page
   * already asks for, so it needs no change of its own.
   */
  try {
    const face = (family, file, weight, style) =>
      `@font-face{font-family:"${family}";src:url("/app-fonts/${file}") format("truetype");` +
      `font-weight:${weight};font-style:${style};font-display:swap}`;
    const fonts = document.createElement('style');
    fonts.textContent = [
      face('Comic Sans MS', 'ComicNeue-Regular.ttf', '100 600', 'normal'),
      face('Comic Sans MS', 'ComicNeue-Bold.ttf', '700 900', 'normal'),
      face('Comic Sans MS', 'ComicNeue-Italic.ttf', '100 600', 'italic'),
      face('Comic Sans MS', 'ComicNeue-BoldItalic.ttf', '700 900', 'italic'),
      face('Segoe Script', 'DancingScript.ttf', '400 700', 'normal'),
    ].join('');
    (document.head || document.documentElement).appendChild(fonts);
  } catch {}

  /*
   * On a TV the page eases keyed scrolling by sliding the page, or a row of
   * cards, in nested layers (`data-glide-layer`), one animation per key
   * press. A held key repeats about nine times a second, so scrolling fast
   * keeps several page-sized slides running at once, and WebKit draws the
   * rows they bring in ahead of time while they run: the likely reason the
   * home and discover pages ran its process out of memory when scrolled
   * fast. A held key's repeats now jump to each row instead of sliding; a
   * single press still slides. Held lasts a moment past the last key, so the
   * first slide after letting go isn't cut to a jump too.
   */
  let held = false;
  let lastDown = 0;
  const HELD_LASTS = 250;
  const holding = () => held && performance.now() - lastDown < HELD_LASTS;
  /*
   * Glide layers. Each layer is kept composited (`will-change: transform`):
   * three nested ones the height of the page, and three more the width of
   * every row. With SLIDES off, those are plain boxes, and every keyed scroll
   * jumps, single presses too (tried while chasing the page's memory kills).
   */
  const SLIDES = true;
  /*
   * Rows' glide layers only near focus. Every row's three, kept composited at WebKit's 2x, came to
   * about 200 MB by the page's estimate on a title page, more than its pictures: the likely reason
   * its process was still ended moving between pages. With ROW_LAYERS_NEAR, only the row with focus
   * and the rows either side of it keep theirs (`data-glide-near`, set as focus moves); the rest are
   * drawn with the page, as they look the same holding still. Focus reaches a row from its
   * neighbour, which has its layers made already by then, before its first glide across.
   */
  const ROW_LAYERS_NEAR = true;
  /** The rows either side of the one with focus that keep their layers. */
  const NEAR_ROWS = 1;
  if (ROW_LAYERS_NEAR && SLIDES) {
    try {
      const ROW = "[data-ui='media-row']";
      const NEAR = 'data-glide-near';
      let near = new Set();
      const mark = (target) => {
        const rows = [...document.querySelectorAll(ROW)].filter((row) => !row.closest('[inert]'));
        if (!rows.length) return;
        const row = target instanceof Element ? target.closest(ROW) : null;
        const at = row ? rows.indexOf(row) : -1;
        // Off the rows (the hero, the navigation), as it was; at first, the top rows, which focus reaches first.
        if (at < 0 && near.size && [...near].some((r) => r.isConnected && !r.closest('[inert]'))) return;
        const from = Math.max(0, at < 0 ? 0 : at - NEAR_ROWS);
        const next = new Set(rows.slice(from, (at < 0 ? 0 : at) + NEAR_ROWS + 1));
        for (const r of near) if (!next.has(r)) r.removeAttribute(NEAR);
        for (const r of next) if (!near.has(r)) r.setAttribute(NEAR, '');
        near = next;
      };
      document.addEventListener('focusin', (e) => mark(e.target), true);
      // Rows mounted since, and a page shown again, are marked by the next move; and once, as it starts.
      addEventListener('load', () => mark(document.activeElement));
    } catch {}
  }
  /*
   * A keyed move up or down eases the scroll position itself, frame by frame:
   * the page's glide code finds no layer to ease a box's content in
   * (patches/web/0014), the page's and the home rows' box alike. Its own way
   * jumps and eases the whole content, a layer the page's height, back over the
   * jump, and on an Apple TV that judders even on the settings page, which has
   * no artwork. Rows across keep their eased layers.
   */
  const PAGE_SCROLLS = true;
  try {
    Object.defineProperty(window, '__aioTVScrolls', { value: PAGE_SCROLLS });
  } catch {}
  /*
   * One glide layer for a row, not three (patches/web/0061). The three nest, each the size of the
   * row's content, so a held key's overlapping slides each take one; here a held key's repeats jump
   * (above), and a press while one slides takes over what it has left, which one layer does.
   */
  try {
    Object.defineProperty(window, '__aioTVGlideLayers', { value: SLIDES ? 1 : 3 });
  } catch {}
  /*
   * Test: those keyed scrolls up and down are WebKit's own smooth scroll
   * (`scrollTo` with `behavior: 'smooth'`, patches/web/0017) rather than the
   * page's, which sets the scroll position from the page's thread each frame:
   * any long task there, such as a row's cards mounting, stalls the scroll.
   * WebKit's runs where the page's work can't hold it up, but starts again
   * from a standstill at each press, which a held key's repeats may show.
   * Set it to false for the page's own easing again.
   */
  const NATIVE_SCROLLS = true;
  try {
    Object.defineProperty(window, '__aioTVNativeScrolls', { value: PAGE_SCROLLS && NATIVE_SCROLLS });
  } catch {}
  /*
   * Test: no masks or filters. The kills come within a second or two of an
   * item page opening with its version picker (`?pick=`), which draws its
   * backdrop under two nested `mask-image`s, or, without one, a poster under
   * `blur-3xl` across most of the screen. WebKit draws masks and filters into
   * surfaces of their own at the screen's 2x scale. With EFFECTS off, edges
   * that fade end sharply and blurred washes are plain. On, so every theme
   * option and fade looks as upstream draws it; set it to false again if the
   * memory kills come back.
   */
  const EFFECTS = true;
  /*
   * Standing layers and pulsing placeholders. The rotating hero keeps several
   * full-screen backdrops as standing layers (`will-change`), and rows that
   * are loading show pulsing placeholders, each animated as a layer of its
   * own. With LAYERS off, nothing asks to stay a layer and the placeholders
   * hold still (tried while chasing the page's memory kills, a screen-sized
   * layer being about 33 MB at the TV's 2x).
   */
  const LAYERS = false;
  try {
    const rules = [];
    // With SLIDES on, the glide layers keep their own will-change, so they slide as before.
    if (!LAYERS)
      rules.push(
        (SLIDES ? '*:not([data-glide-layer])' : '*') + ',*::before,*::after{will-change:auto!important}',
        '.animate-pulse,.UI-Skeleton__root{animation:none!important}'
      );
    else if (!SLIDES) rules.push('[data-glide-layer]{will-change:auto!important}');
    if (ROW_LAYERS_NEAR && SLIDES)
      rules.push(
        "[data-ui='media-row'] [data-glide-layer]{will-change:auto!important}",
        "[data-ui='media-row'][data-glide-near] [data-glide-layer]{will-change:transform!important}"
      );
    /*
     * The page's own glide layers, and the home rows' under the following hero, slide nothing here:
     * a keyed move up or down eases the scroll position instead (PAGE_SCROLLS). Kept as layers they
     * were each drawn the page's size at 2x, the most of the page's drawing layers. They stay what
     * holds anything `position: fixed` inside them, as a layer does, with layout containment.
     */
    if (PAGE_SCROLLS)
      rules.push(
        "[data-glide-layer]:not([data-ui='media-row'] [data-glide-layer]){will-change:auto!important;contain:layout}"
      );
    /*
     * The page's "Blur episodes you haven't started" setting marks the page
     * `data-blur-spoilers` and blurs those episodes' pictures and text with
     * `filter`, so while it's on, the pictures and text it blurs keep their
     * filters. A blurred episode card is small, and a remote's focus on one
     * takes its blur off.
     */
    const SPOILERS =
      "[data-ui='artwork'],[data-ui='episode-title']>span,p[data-ui='episode-title']," +
      "[data-ui='episode-synopsis'],[data-ui='wide-card-subtitle']";
    /*
     * A spoiler's text, which upstream blurs with `filter: blur(5px)` (styles.css), is drawn blurred
     * as a shadow of itself instead, in its own colour, with the letters themselves clear. WebKit
     * drew each filter into a surface of its own, sized to the text it had: switching seasons gave
     * the same cards new episodes, and part of a new synopsis showed through a hard edge where the
     * old one's surface ended. A shadow is drawn with the text, so it has no surface to go stale.
     * The selector is upstream's for that rule.
     */
    rules.push(
      "html[data-blur-spoilers] :is([data-ui='episode-card'],[data-ui='episode-list-item']," +
        "[data-ui='player-episode'],[data-row='next-up'] [data-ui='wide-card']," +
        "[data-row='upcoming'] [data-ui='wide-card'],[data-row='resume'] [data-ui='wide-card']," +
        "[data-ui='calendar-entry'][data-episode])" +
        ":not([data-watched],[data-in-progress],[data-current],:hover,:focus-within,[data-menu-open]>*) " +
        ":is([data-ui='episode-title']>span,p[data-ui='episode-title'],[data-ui='episode-synopsis']," +
        "[data-ui='wide-card-subtitle'],[data-ui='calendar-entry-subtitle'])" +
        '{filter:none!important;-webkit-text-fill-color:transparent;text-shadow:0 0 10px currentColor}'
    );
    /*
     * A trailer playing by itself in the hero or behind a title page shows through a hole the page
     * cuts in its background with a mask (upstream's `useVideoHole`, features/trailers/preview.tsx),
     * set only while it plays. Stripped, the background covers the app's video: sound, black picture.
     */
    const HOLE = "[data-ui='page-background']";
    /*
     * With "Background from artwork" on, the hero's and a title's art fade out into the blurred wash
     * behind the page with a mask (upstream's styles.css, `html[data-art-wash]`), and their shades
     * go transparent. Stripped, the art ends sharply with nothing to shade the text over it, so those
     * two keep their masks then. Each is about a screen's surface while shown; the setting is off by
     * default.
     */
    const ART_FADES = "html[data-art-wash] [data-ui='hero-art'],html[data-art-wash] [data-ui='item-backdrop']";
    /*
     * Upstream draws the hero's and a title backdrop's shades as the page's colour under a mask
     * (1332031a3, "replace opacity modifiers on CSS variable colours"). Stripped, each is a solid
     * slab of the page's colour over the art. With masks off, they're drawn as the gradients those
     * masks make instead, which need no surface of their own. The hero trailer's fades have no
     * name of their own, so they're found by their mask's class.
     */
    const mix = (p) => 'color-mix(in srgb,var(--background) ' + p + '%,transparent)';
    const shade = (dir, mid) =>
      '{background:linear-gradient(to ' + dir + ',var(--background),' + mid + ',transparent)!important}';
    const SIDE = "[data-ui='hero-shade'][data-name='side']";
    const TRAILER_SIDE = "[class*='[mask-image:linear-gradient(to_right,black,rgb(0_0_0/0.6)_30%']";
    const TRAILER_BOTTOM = "[class*='[mask-image:linear-gradient(to_top,black,rgb(0_0_0/0.6)_30%']";
    const TRAILER_TOP = "[class*='[mask-image:linear-gradient(to_bottom,rgb(0_0_0/0.7),transparent)]']";
    const NO_MASK = '{-webkit-mask-image:none!important;mask-image:none!important}';
    /*
     * With EFFECTS on, a title page still drew three masks the size of the screen: the backdrop's
     * 2px bottom edge, the frame inside it (its 12rem fade in at the start), and the bottom shade.
     * WebKit draws each into a surface of its own at 2x, and with the version picker opening as the
     * page scrolled to its episodes, the page's process was ended for memory again. Each of these
     * fades art into the page's own colour, and so does that colour drawn over it as a gradient:
     * the same pixels, with no surface. The shades are drawn so always (with the artwork background
     * on they're transparent either way); the art's own fades only while the page's colour is under
     * it, as with the artwork background they fade into the moving wash, which needs the mask.
     */
    const SOLID = "html:not([data-art-wash]) ";
    const edge = (dir, size) =>
      "{content:'';position:absolute;pointer-events:none;" + size +
      ';background:linear-gradient(to ' + dir + ',var(--background),transparent)}';
    const solidFades = [
      [SIDE, TRAILER_SIDE, TRAILER_BOTTOM, TRAILER_TOP,
        "[data-ui='hero-shade'][data-name='bottom']", "[data-ui='item-backdrop-shade'][data-name='bottom']"]
        .join(',') + NO_MASK,
      "[data-ui='item-backdrop-shade'][data-name='bottom']" + shade('top', mix(70)),
      SIDE + shade('right', mix(70) + ' 35%'),
      "html[dir='rtl'] " + SIDE + shade('left', mix(70) + ' 35%'),
      "[data-ui='hero-shade'][data-name='bottom']" + shade('top', mix(60)),
      TRAILER_SIDE + shade('right', mix(60) + ' 30%'),
      "html[dir='rtl'] " + TRAILER_SIDE + shade('left', mix(60) + ' 30%'),
      TRAILER_BOTTOM + shade('top', mix(60) + ' 30%'),
      TRAILER_TOP + '{background:linear-gradient(to bottom,' + mix(70) + ',transparent)!important}',
      [SOLID + "[data-ui='item-backdrop']", SOLID + "[data-ui='hero-art']", SOLID + "[data-ui='backdrop-frame']"]
        .join(',') + NO_MASK,
      [SOLID + "[data-ui='item-backdrop']::after", SOLID + "[data-ui='hero-art']::after"].join(',') +
        edge('top', 'left:0;right:0;bottom:0;height:2px'),
      SOLID + "[data-ui='backdrop-frame']::after" + edge('right', 'top:0;bottom:0;left:0;width:12rem'),
      "html[dir='rtl']:not([data-art-wash]) [data-ui='backdrop-frame']::after" +
        edge('left', 'top:0;bottom:0;right:0;left:auto;width:12rem'),
    ];
    rules.push(...solidFades);
    /*
     * The app draws the backdrop shown at 4K beneath the page (patches/web/0048, BackdropStage.swift),
     * through a hole in the page's background, once the page has held still. Its own copy is hidden
     * meanwhile, still decoded for when it scrolls, and the masks over it, which the hole's edges now
     * stand in for, are taken off so WebKit makes no surfaces for them. The edges and shades drawn
     * over the art stay.
     */
    const APP_BACKDROP = 'html[data-app-backdrop] ';
    const APP_BACKDROP_SOLID = 'html[data-app-backdrop]:not([data-art-wash]) ';
    /*
     * With "Background from artwork" on, the app draws the wash beneath the page and fades each new
     * one in itself (patches/web/0050, WashStage.swift), so the page's background and its root, which
     * is painted the page's colour too, are clear while the app's is drawn (`data-app-wash`). The
     * root's rule is upstream's for an on-screen keyboard, outweighed here.
     */
    rules.push(
      "html[data-app-wash] [data-ui='page-background']{background-color:transparent!important}",
      'html.see-through[data-app-wash][data-app-wash][data-app-wash]:not(.playing){background-color:transparent!important}',
      // The page's colour, drawn by the app beneath everything whether or not the wash is on
      // (patches/web/0058, `tvos-page-color`), so the app's art shows through the page with no hole
      // cut for it, and follows the page's scroll there frame by frame.
      "html[data-app-color] [data-ui='page-background']{background-color:transparent!important}",
      'html.see-through[data-app-color][data-app-color][data-app-color]:not(.playing){background-color:transparent!important}',
      // Cleared, the background still takes a layer the screen's size, as `position: fixed`, and the
      // page over it layers of their own for overlapping it. Hidden instead (4117b98), composited
      // memory halved, but scrolling a title page while its trailer played drew the sidebar, fixed
      // too, partway down the screen; giving the sidebar a layer of its own didn't keep it in place.
      // So it's hidden only while no trailer cuts its hole (`data-video-hole`): measured on Home
      // with scripts/inspect-memory.py layers, the background's 31.6 MB went, and with it the 45 to
      // 60 MB layer the page's content took for overlapping it (125 MB of layers at rest down to 49,
      // 236 MB at the peak down to 150). While a trailer plays it's shown as before, so the case the
      // sidebar was drawn out of place in is as it was. The keyboard reads the page's colour off a
      // probe inside it, which a hidden box still gives.
      "html[data-app-color]:not([data-video-hole]) [data-ui='page-background']{display:none!important}"
    );
    // The rotating hero's art and the one following the card in focus (whole window or corner), and a title page's.
    rules.push(
      // Opacity too, the compositor's own: the copy still showed with visibility alone, its masks
      // stripped by the rule below, so the art had hard edges over the app's faded one. Only the
      // pictures, whose own fades are animations, so the copy is back at once as the page scrolls.
      // No transitions either: a running one outranks even `!important`, and the last title's
      // picture fading out (`transition-opacity duration-700`) was drawn over the app's art at 0.95
      // for its 0.7 s, a flash at the edges where the two fade differently. A picture that would
      // have faded is at its end at once, unseen. Animations stay: they don't outrank this, and
      // taken off and given back, the newest picture's fade in would start again at each scroll.
      [APP_BACKDROP + "[data-ui='hero-art'] img", APP_BACKDROP + "[data-ui='hero-corner'] img",
        APP_BACKDROP + "[data-ui='item-backdrop-image']"].join(',') +
        '{visibility:hidden!important;opacity:0!important;transition:none!important}',
      // Not with "Background from artwork" on, where the masks fade the art into the wash: given
      // back as the page took over from the app's art, WebKit drew the copy before its masks, so
      // for a moment after each move the art showed with hard bottom and start edges. They stay,
      // drawn, while the copy is hidden, as during the page's own scrolls.
      [APP_BACKDROP_SOLID + "[data-ui='hero-art']", APP_BACKDROP_SOLID + "[data-ui='item-backdrop']",
        APP_BACKDROP_SOLID + "[data-ui='backdrop-frame']", APP_BACKDROP_SOLID + "[data-ui='hero-corner']",
        APP_BACKDROP_SOLID + "[data-ui='hero-corner']>div"].join(',') + NO_MASK
    );
    /*
     * Frosted and liquid glass (Theme > Glass surface: the navigation, and with Glass panels on, the
     * menus, dialogs and settings cards over the artwork background) are a thin fill over a
     * `backdrop-filter` blur. Stripped, they're nearly see-through, so they keep their blur, drawn as
     * upstream intends. Each blurred surface is a layer of its own while shown; Glass surface set to
     * Solid draws none.
     */
    const GLASS_PANELS =
      ".UI-Popover__root,.UI-DropdownMenu__root,.UI-DropdownMenu__subContent,.UI-ContextMenu__root," +
      ".UI-Select__content,.UI-Tooltip__root,.UI-Modal__content,.UI-Drawer__content," +
      "[data-ui='settings-card-body'],[data-ui='settings-tab-group'],[data-ui='pill-tabs']";
    const GLASS =
      ".glass-surface:not([data-surface='solid']),html[data-art-wash][data-art-glass]:not(.playing) :is(" +
      GLASS_PANELS + ')';
    if (!EFFECTS)
      rules.push(
        'html:not([data-blur-spoilers]) *,html[data-blur-spoilers] *:not(' + SPOILERS + '),' +
          '*::before,*::after{filter:none!important}',
        '*:not(' + GLASS + '),*::before,*::after{-webkit-backdrop-filter:none!important;backdrop-filter:none!important}',
        '*:not(' + HOLE + '):not(' + ART_FADES + '),*::before,*::after{-webkit-mask-image:none!important;mask-image:none!important}'
      );
    if (rules.length) {
      const style = document.createElement('style');
      style.textContent = rules.join('\n');
      (document.head || document.documentElement).appendChild(style);
    }
  } catch {}
  // When the last slide that is still running ends, so the artwork sweep below can wait for it.
  let slidingUntil = 0;
  /*
   * "Background from artwork" fades each new background in over the last with an opacity
   * animation on a canvas behind the whole page (upstream's components/shell/art-wash.tsx). While
   * it runs, WebKit makes that canvas a layer of its own, the screen's size at 2x, and with it
   * every part of the page drawn over it, so they stay above it. Resting on card after card started
   * fade after fade, and the page's process was ended for memory with only its usual pictures
   * held (116 MB in 66). With ART_FADES_STEPPED, the fade is stepped from the page each frame
   * instead, on the same curve, which WebKit draws without making layers for it.
   *
   * Off: the page went on being ended with the fade stepped, until the pictures were drawn to the
   * size they're shown at (ImageFit), and stepped, each frame repaints the whole screen beneath
   * the page, which lags each change of background. Upstream's own fade runs on the GPU.
   */
  const ART_FADES_STEPPED = false;
  // CSS's `ease-out`, cubic-bezier(0, 0, 0.58, 1): the progress at `x` of the time, found by bisection.
  const easeOut = (x) => {
    const at = (t, a, b) => 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t;
    let lo = 0;
    let hi = 1;
    for (let i = 0; i < 20; i++) {
      const t = (lo + hi) / 2;
      if (at(t, 0, 0.58) < x) lo = t;
      else hi = t;
    }
    return at((lo + hi) / 2, 0, 1);
  };
  const stepping = new WeakMap();
  /** Fades `el`'s opacity from 0 to 1 over `duration` ms, frame by frame, as `animate` would. */
  const stepFadeIn = (el, duration) => {
    stepping.get(el)?.();
    let done;
    const finished = new Promise((resolve) => (done = resolve));
    let frame = 0;
    const stop = () => {
      cancelAnimationFrame(frame);
      stepping.delete(el);
      // With no fill, an ended animation leaves the element's own opacity.
      el.style.removeProperty('opacity');
      done();
    };
    stepping.set(el, stop);
    el.style.opacity = '0';
    const start = performance.now();
    const step = (now) => {
      const x = Math.min(1, (now - start) / duration);
      if (x >= 1) return stop();
      el.style.opacity = String(easeOut(x));
      frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return { finished, cancel: stop, finish: stop };
  };
  const artFade = (el, keyframes, options) =>
    ART_FADES_STEPPED &&
    el.tagName === 'CANVAS' &&
    !!el.closest?.("[data-ui='art-wash']") &&
    Array.isArray(keyframes) &&
    keyframes.length === 2 &&
    keyframes[0]?.opacity === 0 &&
    keyframes[1]?.opacity === 1 &&
    typeof options?.duration === 'number';
  /*
   * Animations started through `animate` (the page's own, and Framer Motion's page entrance on
   * each page's box), watched weakly. One that ended holding its last frame (`fill: forwards` or
   * `both`) stays in WebKit's timeline with its element, and with a removed element, its whole
   * removed page: each page closed was still held, one apiece, the box taken down with them the
   * page's own. As one's element leaves the page it's cancelled, which lets the timeline let go.
   */
  const madeAnimations = [];
  const ANIMATIONS_WATCHED = 3000;
  const animationsCancelled = new Map();
  const animationOn = (el) =>
    (el.getAttribute && (el.getAttribute('data-page') || el.getAttribute('data-ui'))) ||
    String(el.tagName || 'element').toLowerCase();
  const watchAnimation = (animation) => {
    if (animation && typeof WeakRef === 'function') {
      madeAnimations.push(new WeakRef(animation));
      if (madeAnimations.length > ANIMATIONS_WATCHED) madeAnimations.splice(0, madeAnimations.length - ANIMATIONS_WATCHED);
    }
    return animation;
  };
  /** Each animation whose element is off the page is cancelled, and those cancelled counted by element. */
  const cancelRemovedAnimations = () => {
    let kept = 0;
    for (const ref of madeAnimations) {
      const animation = ref.deref();
      if (!animation) continue;
      madeAnimations[kept++] = ref;
      const target = animation.effect?.target;
      if (!target || target.isConnected || animation.playState === 'idle') continue;
      try {
        animation.cancel();
        const on = animationOn(target);
        animationsCancelled.set(on, (animationsCancelled.get(on) || 0) + 1);
      } catch {}
    }
    madeAnimations.length = kept;
  };
  let cancelTimer = 0;
  /** Soon after removals settle, so an element moved rather than removed is back by then. */
  /*
   * Cards that fade in by CSS on an Apple TV (patches/web/0066), watched weakly as their fade ends,
   * so the memory log can say whether any outlive their page as the `animate` ones did.
   */
  const cardsIn = [];
  try {
    if (typeof WeakRef === 'function')
      document.addEventListener(
        'animationend',
        (e) => {
          if (!String(e.animationName || '').startsWith('aio-card-')) return;
          cardsIn.push(new WeakRef(e.target));
          if (cardsIn.length > ANIMATIONS_WATCHED) cardsIn.splice(0, cardsIn.length - ANIMATIONS_WATCHED);
        },
        true
      );
  } catch {}
  const soonCancelRemovedAnimations = () => {
    clearTimeout(cancelTimer);
    cancelTimer = setTimeout(cancelRemovedAnimations, 500);
  };
  try {
    const animate = Element.prototype.animate;
    Element.prototype.animate = function (keyframes, options) {
      if (artFade(this, keyframes, options)) return stepFadeIn(this, options.duration);
      const glide = !!(this.hasAttribute && this.hasAttribute('data-glide-layer'));
      if (glide && (!SLIDES || holding())) return watchAnimation(animate.call(this, keyframes, { duration: 0 }));
      const duration = typeof options === 'number' ? options : options?.duration;
      if (glide && typeof duration === 'number' && duration > 0)
        slidingUntil = Math.max(slidingUntil, performance.now() + duration);
      return watchAnimation(animate.call(this, keyframes, options));
    };
  } catch {}
  // The page's saved copies of artwork come back as blob URLs too, so the app keeps artwork itself and
  // the page's Artwork switch decides that cache (`__aioArtworkCache` below, patches/web/0071).

  /*
   * Every picture at the width the page asked for it. Each artwork address names the width it's
   * drawn at in device pixels (`maxWidth`), but the server resizes only hosts it knows, and the
   * page's artwork workers, which would draw the rest down, don't start for the app's scheme on
   * this WebKit: a card got a 1654x2339 poster, 15 MB decoded, and the page's pictures reached
   * 200 MB. Such an image loads from the app's `/fit/<width>?u=<address>` instead (ImageFit.swift),
   * which passes one already no wider as it is and decodes a wider one at the smaller size, so the
   * page never holds the original. Set on any `<img>`, however the page sets its address.
   */
  const FIT_IMAGES = true;
  try {
    // Only as the app's own page (WebApp.scheme), whose scheme handler answers `/fit/`.
    if (FIT_IMAGES && location.protocol === 'aiostv:') {
      const fitPrefix = location.protocol + '//' + location.host + '/fit/';
      const fitted = (value) => {
        if (typeof value !== 'string' || !/^https?:\/\//i.test(value)) return value;
        try {
          const address = new URL(value);
          const width = parseInt(address.searchParams.get('maxWidth') || address.searchParams.get('fillWidth') || '', 10);
          // One whose address names no width comes through the app too, kept as it is (`full`), so
          // the artwork cache the page's settings decide (ArtworkCache.swift) holds every picture.
          return fitPrefix + (width > 0 ? width : 'full') + '?u=' + encodeURIComponent(value);
        } catch {
          return value;
        }
      };
      const src = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
      if (src?.set)
        Object.defineProperty(HTMLImageElement.prototype, 'src', {
          ...src,
          set(value) {
            src.set.call(this, fitted(value));
          },
        });
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (this instanceof HTMLImageElement && String(name).toLowerCase() === 'src') value = fitted(value);
        return setAttribute.call(this, name, value);
      };
      /*
       * A picture the app couldn't fetch (one in six once, "Could not connect to the server") is
       * loaded from its own address instead, as the page would have, rather than left missing.
       * Set past the rewrite above, so it isn't sent to the app again. The error stops here, on
       * the way down to the picture: React listens on the `<img>` itself, and the hero's and a
       * title page's logos took the app's miss as their own failure (`onError`) and showed the
       * title's name instead, before the original had a chance. A miss on the original reaches
       * the page as before.
       */
      document.addEventListener(
        'error',
        (e) => {
          const img = e.target;
          if (!(img instanceof HTMLImageElement)) return;
          const at = img.getAttribute('src') || '';
          if (!at.startsWith(fitPrefix)) return;
          try {
            const original = new URL(at).searchParams.get('u');
            if (original) {
              e.stopPropagation();
              setAttribute.call(img, 'src', original);
            }
          } catch {}
        },
        true
      );
      /*
       * The page's "Blur episodes you haven't started" blurs a spoiler's picture with
       * `filter: blur(12px)` (upstream's styles.css, `html[data-blur-spoilers]`), which WebKit draws
       * into a surface of its own at 2x, one per card. Instead, while the page would blur a picture,
       * it loads the app's blurred copy (`&blur=`, ImageFit.swift), a third as wide, and the page's
       * filter comes off that copy alone. When the blur would come off (focus on the card, or the
       * episode started or watched), the sharp copy is put back; until it arrives the blurred one
       * shows, and a sharp one that should be blurred keeps the page's filter until it's swapped, so
       * nothing shows unblurred that the page would blur. SPOILER_ART is upstream's selector for the
       * pictures it blurs.
       */
      const SPOILER_BLUR = 12;
      const SPOILER_ART =
        "html[data-blur-spoilers] :is([data-ui='episode-card'],[data-ui='episode-list-item']," +
        "[data-ui='player-episode'],[data-row='next-up'] [data-ui='wide-card']," +
        "[data-row='upcoming'] [data-ui='wide-card'],[data-row='resume'] [data-ui='wide-card']," +
        "[data-ui='calendar-entry'][data-episode]," +
        "[data-ui='calendar-day']:not(:hover,:focus-within) [data-ui='calendar-day-art'][data-episode])" +
        ":not([data-watched],[data-in-progress],[data-current],:hover,:focus-within,[data-menu-open]>*) " +
        "[data-ui='artwork']";
      const BLURRED_COPY = '&blur=';
      // A WebKit that can't read the selector leaves the page's own blur as it is.
      document.documentElement.matches(SPOILER_ART);
      const spoilerStyle = document.createElement('style');
      spoilerStyle.textContent =
        "html[data-blur-spoilers] img[data-ui='artwork'][src^='" + fitPrefix + "'][src*='" + BLURRED_COPY +
        "']{filter:none!important}";
      (document.head || document.documentElement).appendChild(spoilerStyle);
      // In the copy's own pixels, which the page asks for at its ratio: 1.5 on a 1280-wide page.
      const spoilerRadius = () => Math.round(SPOILER_BLUR * Math.min(2, screen.width / innerWidth || 1));
      let spoilersSeen = false;
      let spoilerFrame = 0;
      const matchSpoilers = () => {
        spoilerFrame = 0;
        const on = document.documentElement.hasAttribute('data-blur-spoilers');
        // Nothing to do until the setting has been on once: then copies may be left to put back.
        if (!on && !spoilersSeen) return;
        spoilersSeen = true;
        const radius = spoilerRadius();
        for (const img of document.querySelectorAll("img[data-ui='artwork']")) {
          const at = img.getAttribute('src');
          if (!at || !at.startsWith(fitPrefix)) continue;
          const blurred = at.includes(BLURRED_COPY);
          const blur = on && img.matches(SPOILER_ART);
          if (blur === blurred) continue;
          // As text, so the sharp copy's address is the page's own again, which WebKit has cached.
          setAttribute.call(img, 'src', blur ? at + BLURRED_COPY + radius : at.replace(/&blur=[^&]*/, ''));
        }
      };
      const soonSpoilers = () => {
        if (!spoilerFrame) spoilerFrame = requestAnimationFrame(matchSpoilers);
      };
      // Focus takes a card's blur off with no change to the page's markup.
      document.addEventListener('focusin', soonSpoilers, true);
      document.addEventListener('focusout', soonSpoilers, true);
      new MutationObserver(soonSpoilers).observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['src', 'data-blur-spoilers', 'data-watched', 'data-in-progress', 'data-current', 'data-menu-open'],
        childList: true,
        subtree: true,
      });
    }
  } catch {}

  /*
   * The page keeps every card it has shown mounted, and WebKit keeps each
   * mounted <img>'s decoded picture, so a long scroll through a catalog
   * fills WebKit's process until tvOS ends it ("ran out of memory"). A
   * picture far from the screen (cards' artwork, backdrops, logos)
   * has its picture swapped for a blank one, which lets WebKit drop the
   * decoded copy, and gets it back as it nears the screen again, from
   * WebKit's cache. A swap React made since is left alone. Measured on
   * scroll and keys, at most four times a second, and once after they stop.
   *
   * Released past three screens and back within two: a picture put back
   * within one was still being decoded as a scroll reached it, which judders.
   * When tvOS warns of low memory, `trim` lets go of all but a little past
   * where pictures come back, so the next sweep doesn't restore them at once.
   *
   * Every picture is swept, not only the cards': a backdrop is the biggest
   * one there is. A page the page keeps but doesn't draw (the home page under
   * every other, or the whole page under the player) is inert and skipped by
   * layout; its pictures are let go of wherever they sit, and come back when
   * it's drawn again, as the inert attribute comes off.
   */
  const BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  const RELEASE_SCREENS = 3;
  const RESTORE_SCREENS = 2;
  const TRIM_SCREENS = 2.25;
  const SWEEP_EVERY = 250;
  const released = new WeakMap();
  const away = (rect, size, start, end) =>
    Math.max(0, rect[start] - size, -rect[end]) / size;
  const sweep = (releaseAt = RELEASE_SCREENS) => {
    const w = window.innerWidth;
    const h = window.innerHeight;
    if (!w || !h) return;
    // Every box is read before any picture changes, so the page is laid out once, not after each swap.
    const found = [];
    // The few inert boxes are looked at once, rather than every picture looking up through its ancestors.
    const hidden = new Set();
    for (const box of document.querySelectorAll('[inert]')) {
      // A kept page is `invisible` and skips its content; a closed panel is inert but drawn.
      const style = getComputedStyle(box);
      if (style.visibility !== 'hidden' && style.contentVisibility !== 'hidden') continue;
      for (const img of box.getElementsByTagName('img')) hidden.add(img);
    }
    for (const img of document.images) {
      const src = img.getAttribute('src');
      if (!src) continue;
      // The page's own inline pictures are left alone; the blank one only when the sweep put it there.
      if (src === BLANK ? !released.has(img) : src.startsWith('data:')) continue;
      // Not read for its box: inside skipped content, that would lay the kept page out.
      if (hidden.has(img)) {
        found.push([img, src, Infinity]);
        continue;
      }
      const rect = img.getBoundingClientRect();
      if (!rect.width && !rect.height) {
        // Not laid out: a kept page goes, anything else (a closed menu's) is left as it is.
        if (img.closest('[inert]')) found.push([img, src, Infinity]);
        continue;
      }
      found.push([img, src, Math.max(away(rect, h, 'top', 'bottom'), away(rect, w, 'left', 'right'))]);
    }
    for (const [img, src, far] of found) {
      if (src === BLANK) {
        const real = released.get(img);
        if (real === undefined) continue;
        if (far < RESTORE_SCREENS) {
          released.delete(img);
          img.setAttribute('src', real);
        }
      } else if (far > releaseAt && !src.startsWith('data:')) {
        released.set(img, src);
        img.setAttribute('src', BLANK);
      }
    }
  };
  /*
   * A single press slides the page for 250 ms. A sweep in the frame after the
   * press, or one landing as the slide ends, measures every card and swaps
   * pictures while it runs, so it waits until the slide is over. Presses that
   * keep a slide running still get a sweep at least once a second, for memory.
   */
  const SLIDE_SETTLE = 50;
  const SWEEP_AT_LEAST = 1000;
  let lastSweep = 0;
  let sweepTimer = 0;
  const soonSweep = () => {
    const now = performance.now();
    const sliding = now < slidingUntil && now - lastSweep < SWEEP_AT_LEAST;
    clearTimeout(sweepTimer);
    // The trailing one catches where a scroll came to rest.
    sweepTimer = setTimeout(() => {
      lastSweep = performance.now();
      sweep();
    }, sliding ? Math.max(SWEEP_EVERY, slidingUntil - now + SLIDE_SETTLE) : SWEEP_EVERY);
    if (sliding || now - lastSweep < SWEEP_EVERY) return;
    lastSweep = now;
    // Not handed to the frame as it is, which would pass the frame's time as `releaseAt`.
    requestAnimationFrame(() => sweep());
  };
  try {
    // Capture: the page and each row scroll in their own containers.
    document.addEventListener('scroll', soonSweep, { capture: true, passive: true });
  } catch {}
  try {
    // A page kept out of sight, or drawn again: its pictures go, or come back.
    new MutationObserver(() => soonSweep()).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['inert'],
      subtree: true,
    });
  } catch {}
  /*
   * A picture taken off the page with what held it (a title page closing, a row's cards
   * replaced) lets go of its image at once. Until the element itself is collected it keeps its
   * decoded copy, and the collector lags: from title to title three times in 7 s, 879 such
   * pictures held about 258 MB as the page's process was ended at its 1 GB limit, and emptying
   * WebKit's memory cache at each move didn't save it, as an image still in use isn't let go of.
   * One moved rather than removed is back on the page by the time this runs, and is left alone;
   * one put back later gets its address back.
   */
  /*
   * A page taken down (each `[data-page]` box, which the page never puts back) is taken apart,
   * each element off its parent, once it's still off the page a moment later. Closed pages were
   * still held, one apiece, after collections on demand, and cancelling their animations didn't
   * free them; one element held keeps its whole tree through its parent. Apart, whatever holds an
   * element keeps that element alone.
   */
  let pagesLeft = [];
  let pagesDismantled = 0;
  let dismantleTimer = 0;
  const dismantle = () => {
    const pages = pagesLeft;
    pagesLeft = [];
    for (const page of pages) {
      if (page.isConnected) continue;
      try {
        const elements = [...page.getElementsByTagName('*')];
        // From the deepest up, so each comes off its parent with nothing left under it to keep.
        for (let i = elements.length - 1; i >= 0; i--) elements[i].remove();
        page.replaceChildren();
        pagesDismantled++;
      } catch {}
    }
  };
  const soonDismantle = () => {
    clearTimeout(dismantleTimer);
    dismantleTimer = setTimeout(dismantle, 500);
  };
  try {
    const parked = new WeakMap();
    const imagesIn = (node, out) => {
      if (node.nodeType !== 1) return;
      if (node.tagName === 'IMG') out.push(node);
      else for (const img of node.getElementsByTagName('img')) out.push(img);
    };
    new MutationObserver((records) => {
      const left = [];
      const back = [];
      let removedAny = false;
      for (const record of records) {
        if (record.removedNodes.length) removedAny = true;
        for (const node of record.removedNodes) {
          const from = left.length;
          imagesIn(node, left);
          // For the memory log: which page, and what was taken down with the picture.
          if (left.length > from && node.nodeType === 1) {
            const what =
              node.getAttribute('data-page') ||
              node.getAttribute('data-ui') ||
              node.querySelector?.('[data-ui]')?.getAttribute('data-ui') ||
              node.tagName.toLowerCase();
            for (let i = from; i < left.length; i++) {
              if (!removedFrom.has(left[i])) removedFrom.set(left[i], what);
            }
          }
        }
        for (const node of record.addedNodes) imagesIn(node, back);
      }
      for (const img of back) {
        const src = parked.get(img);
        if (src === undefined) continue;
        parked.delete(img);
        if (img.getAttribute('src') === BLANK) img.setAttribute('src', src);
      }
      for (const img of left) {
        if (img.isConnected) continue;
        const src = img.getAttribute('src');
        if (!src || src.startsWith('data:')) continue;
        parked.set(img, src);
        img.setAttribute('src', BLANK);
      }
      // What was taken down may have animations holding it in WebKit's timeline.
      if (removedAny) soonCancelRemovedAnimations();
      for (const record of records) {
        for (const node of record.removedNodes) {
          if (node.nodeType === 1 && node.hasAttribute('data-page')) pagesLeft.push(node);
        }
      }
      if (pagesLeft.length) soonDismantle();
    }).observe(document.documentElement, { childList: true, subtree: true });
  } catch {}

  const listeners = new Set();
  const post = (message) => handler.postMessage(JSON.stringify(message));
  /*
   * A web link the page opens in a new window (Donate, About's links and credits, Account's
   * configuration page, any other): a TV has no browser, and WebKit opened no window for it, so it
   * went nowhere. The app shows it as a QR code for a phone instead (`tvos-open-link`, LinkScreen).
   * Anything else goes to WebKit's own as before.
   */
  try {
    const openWindow = window.open;
    window.open = function (url, ...rest) {
      try {
        const address = new URL(String(url ?? ''), location.href);
        if (address.protocol === 'http:' || address.protocol === 'https:') {
          post({ type: 'tvos-open-link', url: address.href });
          return null;
        }
      } catch {}
      return openWindow.call(this, url, ...rest);
    };
  } catch {}
  /*
   * A `player-frame` is in the page's pixels times its viewport scale (the page's `unzoomed`). The page
   * asks a TV for a 1280-wide viewport, and whether WebKit scales that up to the screen is WebKit's to
   * say, so the page's width in the same measure goes with it: the app maps the frame by the web
   * view's width over this, whatever the page's scale (VideoStage).
   */
  /*
   * A trailer that plays by itself in a card, the hero or a title page loads in one of the page's
   * effects and is framed in the next, in the same turn. A load is held to the end of its turn, with
   * whatever follows it in that turn, in order, and goes out marked `framed` when the page has a frame
   * set by then: the app keeps the TV's mode for it rather than blanking to match a muted preview
   * (`LoadRequest.framed`).
   */
  // Not `held`: that name is the held remote key's, above, and a second `let` of it is a syntax
  // error that stops this whole script, and with it the page's storage, TV layout and remote.
  let framed = false;
  let heldMessages = null;
  const flush = () => {
    const messages = heldMessages;
    heldMessages = null;
    if (framed) messages[0] = { ...messages[0], framed: true };
    for (const message of messages) post(message);
  };
  const send = (message) => {
    if (message && message.type === 'player-frame') {
      framed = !!message.frame;
      if (message.frame) {
        try {
          const scale = (window.visualViewport && window.visualViewport.scale) || 1;
          message = { ...message, pageWidth: window.innerWidth * scale };
        } catch {}
      }
    }
    if (heldMessages) return void heldMessages.push(message);
    if (message && message.type === 'player-load') {
      heldMessages = [message];
      queueMicrotask(flush);
      return;
    }
    post(message);
  };

  /*
   * tvOS can drop a web view's stored data between launches, and with it the
   * page's sign-in. The app keeps a copy of localStorage (by origin), puts
   * back what is missing as the page starts, and hears of every change.
   */
  try {
    const saved = __STORAGE__?.[location.origin];
    if (saved && typeof saved === 'object') {
      for (const [key, value] of Object.entries(saved)) {
        if (typeof value === 'string' && localStorage.getItem(key) === null)
          localStorage.setItem(key, value);
      }
    }
  } catch {}
  try {
    const proto = Storage.prototype;
    const { setItem, removeItem, clear } = proto;
    const local = (store) => {
      try {
        return store === window.localStorage;
      } catch {
        return false;
      }
    };
    const origin = location.origin;
    proto.setItem = function (key, value) {
      setItem.call(this, key, value);
      if (local(this))
        send({ type: 'tvos-storage', origin, key: String(key), value: String(value) });
    };
    proto.removeItem = function (key) {
      removeItem.call(this, key);
      if (local(this)) send({ type: 'tvos-storage', origin, key: String(key), value: null });
    };
    proto.clear = function () {
      clear.call(this);
      if (local(this)) send({ type: 'tvos-storage', origin, clear: true });
    };
  } catch {}

  /*
   * The app's artwork cache, which the page's Settings > Cache decides (ArtworkCache.swift): the page's
   * own saved artwork comes back as blob URLs, which this WebKit doesn't draw, so the page saves none
   * (patches/web/0071) and the app keeps what it fetches. Its "Save what you browse" and Artwork
   * switches turn the app's on and off, and "Space to use", less what the page saves itself, is the
   * room it has. The page asks through `__aioArtworkCache` for the bytes kept, for its Artwork row,
   * and to clear it, with Artwork's Clear and "Clear everything".
   */
  try {
    const CACHE_ON = 'aiostreams-web-cache';
    const CACHE_ARTWORK = 'aiostreams-web-cache-artwork';
    const CACHE_SIZE = 'aiostreams-web-cache-size';
    // Builds before this one kept the Artwork switch off, as the page's copies don't draw here: put
    // back to the page's default once, now that it means the app's cache.
    const LINKED = 'aiostv-artwork-cache-linked';
    if (localStorage.getItem(LINKED) === null) {
      localStorage.removeItem(CACHE_ARTWORK);
      localStorage.setItem(LINKED, '1');
    }
    // As the page's device settings keep them: JSON, and absent at the default.
    const setting = (key, fallback) => {
      try {
        const raw = localStorage.getItem(key);
        const value = raw === null ? fallback : JSON.parse(raw);
        return typeof value === typeof fallback ? value : fallback;
      } catch {
        return fallback;
      }
    };
    let pageBytes = 0;
    let told = '';
    const tell = () => {
      const on = setting(CACHE_ON, true) && setting(CACHE_ARTWORK, true);
      // In whole megabytes down, so each page the page saves doesn't move it.
      const limit = Math.max(0, Math.floor((setting(CACHE_SIZE, 500) * 1e6 - pageBytes) / 1e6) * 1e6);
      const message = { type: 'tvos-artwork-cache', on, limit };
      const text = JSON.stringify(message);
      if (text === told) return;
      told = text;
      post(message);
    };
    const proto = Storage.prototype;
    const { setItem, removeItem, clear } = proto;
    const watched = (key) => key === CACHE_ON || key === CACHE_ARTWORK || key === CACHE_SIZE;
    proto.setItem = function (key, value) {
      setItem.call(this, key, value);
      if (watched(String(key))) tell();
    };
    proto.removeItem = function (key) {
      removeItem.call(this, key);
      if (watched(String(key))) tell();
    };
    proto.clear = function () {
      clear.call(this);
      tell();
    };
    // Each request's answer (`tvos-artwork-cache-reply`), by its id; none in 3 s counts as nothing kept.
    let asked = 0;
    const waiting = new Map();
    listeners.add((message) => {
      if (!message || message.type !== 'tvos-artwork-cache-reply') return;
      const done = waiting.get(message.id);
      if (done) done(Number(message.bytes) || 0);
    });
    const ask = (type) =>
      new Promise((resolve) => {
        const id = ++asked;
        const timer = setTimeout(() => finish(0), 3000);
        const finish = (bytes) => {
          clearTimeout(timer);
          waiting.delete(id);
          resolve(bytes);
        };
        waiting.set(id, finish);
        post({ type, id });
      });
    Object.defineProperty(window, '__aioArtworkCache', {
      value: Object.freeze({
        /** The bytes the app keeps. */
        bytes: () => ask('tvos-artwork-cache-usage'),
        /** Clears it all. */
        clear: () => ask('tvos-artwork-cache-clear').then(() => undefined),
        /** What the page saves itself, which the room the app has leaves out. */
        pageBytes(bytes) {
          pageBytes = Math.max(0, Number(bytes) || 0);
          tell();
        },
      }),
    });
    tell();
  } catch {}

  // The app calls this with each message for the page.
  Object.defineProperty(window, '__aioReceive', {
    value(message) {
      for (const listener of listeners) {
        try {
          listener(message);
        } catch (error) {
          console.error(error);
        }
      }
    },
  });

  window.aiostreamsApp = Object.freeze({
    protocol: 2,
    version: __VERSION__,
    // The page treats the Android app on a TV as a TV; tvOS gets the same.
    platform: 'android',
    tv: true,
    voice: false,
    // The page then listens for `gamepad` messages instead of polling the Gamepad API every frame,
    // as it otherwise does on a host without this. None are sent: tvOS hands a controller's d-pad
    // and buttons to AppWindow as presses, like the remote's, and those reach the page as keys.
    gamepadButtons: true,
    // The page hides its player while the picture-in-picture window shows; the app's button in the
    // player starts the window (PictureInPicture.swift).
    pip: true,
    // The app draws its video small where the page says (`player-frame`, VideoStage.swift): the
    // page's mini player docked in a preview, and trailers that play by themselves in cards, the
    // hero and title pages, which the page starts only where the player can be placed so.
    miniPlayer: true,
    // Hides the Android settings this app can't honour (patches/web/0007): the Android app section
    // (updates, picture-in-picture, background play, mpv.conf), the engine, tunneling, frame-rate
    // matching (tvOS's own Match Content) and passthrough.
    appleTv: true,
    // The system's 12- or 24-hour clock, for the page's Time format on Automatic (the player's clock,
    // the TV guide), as the Android app sends it.
    hours24: __HOURS24__,
    device: __DEVICE__,
    deviceId: __DEVICE_ID__,
    send,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  });

  /*
   * The page's language, which the web app sets on the root as it activates one, for the app's own
   * screens (the web link's QR code, LinkScreen.swift), so they follow the page rather than tvOS.
   */
  let sentLanguage = '';
  const sendLanguage = () => {
    const language = document.documentElement.lang || '';
    if (!language || language === sentLanguage) return;
    sentLanguage = language;
    send({ type: 'tvos-language', language });
  };
  new MutationObserver(sendLanguage).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['lang'],
  });
  sendLanguage();

  /*
   * The Siri Remote, as the keys the page's own remote handling reads. Back
   * goes through the bridge instead, as on Android.
   */
  const NOT_TEXT = new Set([
    'button', 'checkbox', 'radio', 'range', 'submit', 'reset',
    'color', 'file', 'image', 'hidden',
  ]);
  const isTextField = (el) =>
    !!el &&
    (el.tagName === 'TEXTAREA' ||
      (el.tagName === 'INPUT' && !NOT_TEXT.has((el.type || 'text').toLowerCase())));
  const target = () => document.activeElement || document.body;
  // React tracks the value it last set, so set it as the browser would.
  const setValue = (el, value) => {
    const proto =
      el.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  };
  let editing = null;
  /** The key that opened the keyboard, whose release the page never saw pressed. */
  let swallowed = null;
  /*
   * A searchable list, such as the pickers with the up and down carets (the
   * page's Combobox, on cmdk): its search field keeps focus while Up and Down
   * move a highlight through the list (aria-activedescendant, or cmdk's
   * highlighted item). Enter picks whatever is highlighted, as cmdk highlights
   * the first entry as the list opens and the first match after a search, so
   * Enter on it straight away is a pick too. The keyboard opens with Up from
   * the top entry, onto the search field above the list, or with Enter when
   * nothing is highlighted (a search that matched nothing).
   */
  const listField = (el) =>
    !!el &&
    (el.hasAttribute('aria-activedescendant') ||
      el.hasAttribute('cmdk-input') ||
      el.getAttribute('role') === 'combobox');
  const isHighlighted = (item) =>
    !!item &&
    (item.getAttribute('data-selected') === 'true' || item.getAttribute('aria-selected') === 'true');
  /** The list's entries a highlight can land on, first to last. */
  const entries = (el) => {
    const root = el.closest('[cmdk-root]');
    if (root)
      return [...root.querySelectorAll('[cmdk-item]')].filter(
        (item) => item.getAttribute('aria-disabled') !== 'true' && item.getAttribute('data-disabled') !== 'true'
      );
    const id = el.getAttribute('aria-controls') || el.getAttribute('aria-owns');
    const list = id && document.getElementById(id);
    return list
      ? [...list.querySelectorAll('[role=option]')].filter((item) => item.getAttribute('aria-disabled') !== 'true')
      : [];
  };
  const highlightedEntry = (el) => {
    const id = el.getAttribute('aria-activedescendant');
    const active = id && document.getElementById(id);
    if (active) return active;
    return entries(el).find(isHighlighted) || null;
  };
  /**
   * Up from here leaves the list for its search field: the top entry is highlighted, or the open
   * list has nothing to highlight. A closed list field keeps Up for moving on.
   */
  const atTop = (el) => {
    const all = entries(el);
    if (!all.length) return el.getAttribute('aria-expanded') === 'true';
    const current = highlightedEntry(el);
    return !current || current === all[0];
  };

  const key = (type, name, repeat) =>
    target().dispatchEvent(
      new KeyboardEvent(type, {
        key: name,
        code: name,
        repeat: !!repeat,
        bubbles: true,
        cancelable: true,
      })
    );

  /*
   * Left from a row's first poster opens the navigation on the left. The page
   * moves focus into it only when nothing on its own side sits just beside
   * focus, so near the top of the home page (the hero, Continue Watching,
   * Next Up) Left from the first card often went nowhere. When Left from a
   * card in a row leaves focus where it was, it goes to the navigation's
   * current page, as the page enters it itself; Right from there comes back
   * to the card. Not in a dialog, the player, a text field or a slider.
   */
  const NAV_SIDE = '[data-ui="tv-rail"], [data-ui="sidebar"], [data-ui="corner-menu"]';
  const OWN_KEYS =
    '[role=dialog], [role=alertdialog], [role=menu], [role=listbox], [role=slider], [role=combobox], ' +
    'input, textarea, select, [contenteditable=""], [contenteditable=true], [data-ui="player-controls"]';
  /** The card focus left for the navigation, which Right returns to. */
  let leftFrom = null;
  const shown = (el) => !!el && el.isConnected && el.getClientRects().length > 0;
  const navEntry = () => {
    const nav = [...document.querySelectorAll(NAV_SIDE)].find(shown);
    if (!nav) return null;
    const named = nav.dataset.navEnter && nav.querySelector(nav.dataset.navEnter);
    if (shown(named)) return named;
    const current = nav.querySelector('[aria-current="page"]');
    if (shown(current)) return current;
    return [...nav.querySelectorAll('button, a[href], [tabindex]:not([tabindex="-1"])')].find(shown) || null;
  };
  const inRow = (el) =>
    !!el &&
    el !== document.body &&
    !!el.closest('[data-nav-row], [data-nav-group]') &&
    !el.closest(NAV_SIDE) &&
    !el.closest(OWN_KEYS) &&
    !document.querySelector('[role=dialog][data-state=open], [role=alertdialog][data-state=open]');
  const focusNav = (to) => to.focus({ preventScroll: true, focusVisible: true });
  /*
   * The navigation sits at the page's start: on the left, and on the right when the page is laid out
   * right to left (Hebrew), where every key here that goes toward it or comes back from it is the
   * other arrow. Only Left and Right toward it were taken before, so in Hebrew Right from a row's
   * first poster, next to the navigation, never reached it.
   */
  const rtl = () => document.documentElement.dir === 'rtl';
  const TOWARD_NAV = () => (rtl() ? 'ArrowRight' : 'ArrowLeft');
  const FROM_NAV = () => (rtl() ? 'ArrowLeft' : 'ArrowRight');
  /*
   * A catalog or collection is a grid (`data-nav-wrap`), where toward the navigation from the
   * first poster of a line wraps to the end of the line above, as text does, so focus moves and
   * the check after the key never sees it stay. From a line's first poster it goes to the
   * navigation instead; off a line's end the other way still wraps. A right to left grid's line
   * starts on the right.
   */
  const startsGridLine = (el) => {
    const grid = el.closest?.('[data-nav-wrap]');
    if (!grid) return false;
    const backwards = getComputedStyle(grid).direction === 'rtl';
    let cell = el;
    while (cell && cell.parentElement !== grid) cell = cell.parentElement;
    if (!cell) return false;
    const at = cell.getBoundingClientRect();
    for (let prev = cell.previousElementSibling; prev; prev = prev.previousElementSibling) {
      const r = prev.getBoundingClientRect();
      if (!r.width && !r.height) continue;
      // The poster before it sits at or past its start edge: on the line above.
      return backwards ? r.right <= at.right + 1 : r.left >= at.left - 1;
    }
    return true;
  };
  document.addEventListener('focusin', () => {
    if (leftFrom && !document.activeElement?.closest?.(NAV_SIDE)) leftFrom = null;
  });

  /** The app's keyboard for `el`, typing into it as it goes (`input`), until it closes (`done`). */
  const openKeyboard = (el) => {
    editing = el;
    send({
      type: 'tvos-keyboard',
      value: el.value || '',
      label:
        el.getAttribute('aria-label') ||
        el.placeholder ||
        el.labels?.[0]?.textContent?.trim() ||
        '',
      secure: el.type === 'password',
      email: el.type === 'email',
      numeric:
        el.inputMode === 'numeric' ||
        el.inputMode === 'decimal' ||
        el.type === 'number' ||
        el.type === 'tel',
      url: el.type === 'url' || el.inputMode === 'url',
      ...keyboardLook(),
    });
  };

  /*
   * The top tabs (upstream's components/shell/nav/top-tabs.tsx) lay out as three columns, the logo,
   * the tabs and the end pill, the two sides kept equal (`1fr auto 1fr`) so the tabs are centred on
   * the screen. A TV has so many tabs that the end pill's side was 29 px short for it, and kept equal
   * the grid pushed the pill past the page's edge: the page was 1309 wide, which WebKit shrank to fit
   * the screen, leaving a strip down the right with none of the page in it, and everything drawn a
   * little small. Where the centred tabs don't fit, the sides go to their own widths and the tabs
   * centre in what's left between them (`data-tabs-tight`); centred again once they fit. With the
   * tabs' names shown they needed 1269 of the bar's 1200 even so, ran into the end pill, so where
   * they don't fit that way either, the bar is drawn tighter (`data-tabs-tight=compact`): half its
   * padding at the sides and between its columns, and a named tab's end padding (top-tabs.tsx's
   * `pe-5`) and the space between its icon and name a little less, about 130 px in all.
   */
  try {
    const TABS_ROW = "[data-ui='top-tabs'] .grid";
    const COMPACT = TABS_ROW + "[data-tabs-tight='compact']";
    const tabsStyle = document.createElement('style');
    tabsStyle.textContent =
      TABS_ROW + '[data-tabs-tight]{grid-template-columns:auto minmax(0,1fr) auto!important}' +
      TABS_ROW + '[data-tabs-tight]>:nth-child(2){justify-self:center}' +
      COMPACT + '{padding-left:1.25rem!important;padding-right:1.25rem!important;column-gap:0.75rem!important}' +
      COMPACT + " [data-ui='nav-item']{padding-inline-end:0.875rem!important;gap:0.75rem!important}";
    (document.head || document.documentElement).appendChild(tabsStyle);
    // The bar's needs at its own spacing, measured while it has it, for whether it'd fit again.
    let namedTabs = 0;
    let roomAsIs = 0;
    let gapAsIs = 0;
    // What a child's own content spans, rather than the column it's stretched over.
    const contentWidth = (el) => {
      let left = Infinity;
      let right = -Infinity;
      for (const child of el.children) {
        const r = child.getBoundingClientRect();
        if (!r.width) continue;
        left = Math.min(left, r.left);
        right = Math.max(right, r.right);
      }
      return right > left ? right - left : el.getBoundingClientRect().width;
    };
    const fitTabs = () => {
      const row = document.querySelector(TABS_ROW);
      if (!row || row.children.length < 3) return;
      const [start, tabs, end] = row.children;
      const was = row.getAttribute('data-tabs-tight');
      // Compact, the bar's spacing isn't upstream's: what it needs is judged from what it had then.
      if (was !== 'compact') {
        const s = getComputedStyle(row);
        roomAsIs = row.clientWidth - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight);
        gapAsIs = parseFloat(s.columnGap) || 0;
        namedTabs = tabs.getBoundingClientRect().width;
      }
      const logo = contentWidth(start);
      const endWidth = end.getBoundingClientRect().width;
      const next =
        namedTabs + 2 * gapAsIs + 2 * Math.max(logo, endWidth) <= roomAsIs + 0.5
          ? null
          : logo + namedTabs + endWidth + 2 * gapAsIs <= roomAsIs + 0.5
            ? ''
            : 'compact';
      if (next === was) return;
      if (next === null) row.removeAttribute('data-tabs-tight');
      else row.setAttribute('data-tabs-tight', next);
    };
    let tabsFrame = 0;
    const soonTabs = () => {
      if (!tabsFrame) tabsFrame = requestAnimationFrame(() => {
        tabsFrame = 0;
        fitTabs();
      });
    };
    let watched = null;
    const sizes = new ResizeObserver(soonTabs);
    // The bar comes and goes with the navigation setting, and its style remakes the row.
    new MutationObserver(() => {
      const row = document.querySelector(TABS_ROW);
      if (row !== watched) {
        sizes.disconnect();
        watched = row;
        namedTabs = 0;
        roomAsIs = 0;
        gapAsIs = 0;
        if (row) for (const el of [row, ...row.children]) sizes.observe(el);
      }
      soonTabs();
    }).observe(document.documentElement, { childList: true, subtree: true });
    addEventListener('resize', soonTabs);
  } catch {}

  /*
   * Turning "Background from artwork" (or Glass) off on a page scrolled down, Settings say, took
   * the wash and the blurs from under the page at once, and WebKit went on drawing the navigation
   * down the side, `position: fixed`, from a stale layer: as far down the screen as the page was
   * scrolled, though the page still laid it out at the top (scripts/probes/sidebar-shift.js). A
   * scroll didn't put it back (27a5315, reverted: it kept the shift until the app restarted).
   * Hidden for a frame and shown again, WebKit makes its layer anew, in place
   * (scripts/probes/sidebar-reset.js). Only on a real change: the page sets `data-art-wash` again
   * with each new wash, and the navigation mustn't blink at every card. (Up to 11d20f0, `lookNow`
   * took an empty attribute for none, so no change was ever seen: the timings tried in builds
   * until then, two frames and a second, never ran on the TV.)
   */
  try {
    const LOOK = ['data-art-wash', 'data-app-wash', 'data-art-glass'];
    /*
     * No wait: tried on the TV with scripts/probes/sidebar-tune.js, hidden at once and for one
     * frame put it back even just after a keyed scroll (WebKit's own smooth scroll, NATIVE_SCROLLS,
     * the only time it went stale). Hidden one frame, as the trailer's reset is. Both waits stay, at
     * none, for the probe to try others.
     */
    const REDRAW_AFTER_MS = 0;
    /** After a scroll, how long the page must have held still first. */
    const SCROLL_STILL_MS = 0;
    const HIDE_FRAMES = 1;
    const html = document.documentElement;
    // Set, the attributes are mostly empty (`data-art-wash=""`), which a plain join of their values
    // can't tell from none: whether each is there, and its value.
    const lookNow = () =>
      LOOK.map((name) => (html.hasAttribute(name) ? '=' + html.getAttribute(name) : '-')).join('|');
    let look = lookNow();
    let redrawing = 0;
    let changedAt = 0;
    let scrolledAt = 0;
    // What it last did, for scripts/probes/sidebar-watch.js.
    // `afterMs`, `stillMs` and `hideFrames` are read at each change, so scripts/probes/sidebar-tune.js
    // can try others on the TV without a build; they go back to these as the page reloads.
    const navRedraws = {
      changes: 0,
      ran: 0,
      last: '',
      afterMs: REDRAW_AFTER_MS,
      stillMs: SCROLL_STILL_MS,
      hideFrames: HIDE_FRAMES,
    };
    try {
      Object.defineProperty(window, '__aioNavRedraws', { value: navRedraws });
    } catch {}
    addEventListener('scroll', () => (scrolledAt = performance.now()), { capture: true, passive: true });
    const redrawNav = () => {
      navRedraws.changes += 1;
      navRedraws.last = 'waiting';
      changedAt = performance.now();
      clearTimeout(redrawing);
      const due = () => {
        const wait = Math.max(changedAt + navRedraws.afterMs, scrolledAt + navRedraws.stillMs) - performance.now();
        if (wait > 0) {
          redrawing = setTimeout(due, wait);
          return;
        }
        redrawing = 0;
        resetNav(navRedraws.hideFrames);
      };
      redrawing = setTimeout(due, navRedraws.afterMs);
    };
    /** Hides the navigation this many frames and shows it again, for WebKit to make its layer anew. */
    const resetNav = (hideFrames) => {
      // At the top, the stale layer is where the navigation belongs anyway.
      if (scrollY <= 0) {
        navRedraws.last = 'skipped: at the top';
        return;
      }
      // The outermost of each: the rail inside the sidebar goes with it.
      const navs = [...document.querySelectorAll(NAV_SIDE)].filter(
        (el) => !el.parentElement?.closest(NAV_SIDE) && getComputedStyle(el).position === 'fixed'
      );
      if (!navs.length) {
        navRedraws.last = 'skipped: no fixed navigation';
        return;
      }
      navRedraws.ran += 1;
      navRedraws.last = `hid ${navs.map((el) => el.dataset.ui).join(', ')} at scrollY ${Math.round(scrollY)}`;
      // Hiding the element with focus would drop it; the settings toggle has it, as a rule.
      const focused = document.activeElement;
      const hadFocus = navs.some((el) => el.contains(focused));
      for (const el of navs) el.style.setProperty('display', 'none', 'important');
      void html.offsetHeight;
      const show = () => {
        for (const el of navs) el.style.removeProperty('display');
        if (hadFocus && focused?.isConnected) focused.focus({ preventScroll: true });
      };
      // Hidden this many frames (at least one, for WebKit to drop the old layer).
      let frames = Math.max(1, hideFrames);
      const frame = () => (--frames > 0 ? requestAnimationFrame(frame) : show());
      requestAnimationFrame(frame);
    };
    new MutationObserver(() => {
      const now = lookNow();
      if (now === look) return;
      look = now;
      redrawNav();
    }).observe(html, { attributeFilter: LOOK });
    /*
     * Glass surface with Glass panels off changes nothing on the root: only the navigation's own
     * `.glass-surface` takes the new `data-surface` (frosted, liquid, solid), its blur coming or
     * going, which leaves the same stale layer.
     */
    new MutationObserver((records) => {
      if (records.some((r) => r.target.classList?.contains('glass-surface') && r.target.getAttribute('data-surface') !== r.oldValue))
        redrawNav();
    }).observe(html, { subtree: true, attributeFilter: ['data-surface'], attributeOldValue: true });
    /*
     * The same stale layer, with a title page scrolled while its trailer plays behind it: the page's
     * background is cut with a mask for the video then (upstream's `useVideoHole`, which marks
     * `data-video-hole` on the root), and WebKit drew the fixed navigation partway down the screen
     * (see the note on `data-app-color` above). From the page it can't be seen to be out of place
     * (it lays out at the top), so while a trailer shows, each scroll away from the top resets it.
     * The hero's trailer cuts the same hole (it isn't `over` the page), so the home page is reset
     * too while it plays, though it wasn't seen to shift there.
     * Tried on the TV with scripts/probes/sidebar-trailer-tune.js: hidden one frame, it's shown again
     * before WebKit draws one, so it never blinks; the timeout only gathers a frame's scroll events
     * into one reset. Only with a trailer: at every scroll on every page, each reset's layout and
     * new layer (and Glass's blur) would compete with the rows drawn in as the page scrolls.
     * `trailerSettleMs` and `trailerHideFrames` can be tried on the TV through `__aioNavRedraws`.
     */
    navRedraws.trailerSettleMs = 0;
    navRedraws.trailerHideFrames = 1;
    navRedraws.trailerResets = 0;
    /*
     * Without a trailer, on the home page (the hero) and a title page, once: the scroll that leaves
     * the top resets the navigation as it comes to rest, so its layer is made anew where the page now
     * stands. The rest of the page's scrolls don't. `leaveTopSettleMs` is how long no scroll counts
     * as rest, as a keyed scroll is WebKit's own smooth one over several frames.
     */
    navRedraws.leaveTopSettleMs = 150;
    navRedraws.leaveTopResets = 0;
    // The home page or a title page, by the route's first part, as upstream's `artPageOf` reads it.
    const heroOrTitle = () => {
      const page = (location.hash.slice(1).split('?')[0] || '/').split('/')[1] || '';
      return page === '' || page === 'item';
    };
    let atTop = scrollY <= 0;
    let leftTop = false;
    let resting = 0;
    addEventListener(
      'scroll',
      () => {
        if (scrollY <= 0) {
          atTop = true;
          leftTop = false;
          clearTimeout(resting);
          return;
        }
        if (atTop) {
          atTop = false;
          leftTop = heroOrTitle();
        }
        if (!leftTop) return;
        clearTimeout(resting);
        resting = setTimeout(() => {
          resting = 0;
          if (!leftTop || scrollY <= 0 || !heroOrTitle()) return;
          leftTop = false;
          // A trailer's own resets below already cover this scroll.
          if (html.hasAttribute('data-video-hole')) return;
          navRedraws.leaveTopResets += 1;
          resetNav(navRedraws.trailerHideFrames);
        }, navRedraws.leaveTopSettleMs);
      },
      { capture: true, passive: true }
    );
    let settling = 0;
    addEventListener(
      'scroll',
      () => {
        if (!html.hasAttribute('data-video-hole')) return;
        clearTimeout(settling);
        settling = setTimeout(() => {
          settling = 0;
          if (scrollY <= 0 || !html.hasAttribute('data-video-hole')) return;
          navRedraws.trailerResets += 1;
          resetNav(navRedraws.trailerHideFrames);
        }, navRedraws.trailerSettleMs);
      },
      { capture: true, passive: true }
    );
  } catch {}

  /*
   * What the page's own background looks like, for the keyboard's box to be drawn the same, solid:
   * the theme's colour, and with "Background from artwork" on, the artwork wash the page shows
   * (upstream's components/shell/art-wash.tsx), a 320x180 canvas stretched over the screen.
   */
  const keyboardLook = () => {
    const look = {};
    try {
      const page = document.querySelector("[data-ui='page-background']");
      // Read off a probe in the page's colour: the background itself is clear over the app's wash.
      let colour = '';
      if (page) {
        const probe = document.createElement('div');
        probe.style.cssText = 'position:absolute;width:0;height:0;background:var(--background)';
        page.appendChild(probe);
        colour = getComputedStyle(probe).backgroundColor;
        probe.remove();
      }
      if (colour) look.background = colour;
      // Over the app's own wash, the app adds it to the keyboard itself.
      if (document.documentElement.hasAttribute('data-art-wash') &&
          !document.documentElement.hasAttribute('data-app-wash')) {
        const shown = [...document.querySelectorAll("[data-ui='art-wash'] canvas")].find(
          (c) => c.style.visibility === 'visible' && c.style.zIndex === '1'
        );
        if (shown) look.wash = shown.toDataURL('image/jpeg', 0.92);
      }
    } catch {}
    return look;
  };

  /*
   * The search page opens the keyboard on its field as it opens, as tvOS's own search does, rather
   * than waiting for Select on the field. Only a visit that starts empty: Back to a search's
   * results, which has its term in the address, keeps the results on screen. Each visit's field
   * opens it once, so closing the keyboard leaves the page alone.
   */
  let searchOpened = null;
  const SEARCH_FIELD_TRIES = 40;
  const SEARCH_FIELD_WAIT = 50;
  const openSearchKeyboard = (tries = 0) => {
    if (location.hash.slice(1).split('?')[0] !== '/search') return;
    const box = document.querySelector('[data-ui="search-input"]');
    const el = box && (isTextField(box) ? box : box.querySelector('input'));
    if (!el || !el.isConnected) {
      // The page draws its field a moment after the address changes.
      if (tries < SEARCH_FIELD_TRIES) setTimeout(() => openSearchKeyboard(tries + 1), SEARCH_FIELD_WAIT);
      return;
    }
    // The page laid out around tvOS's own keyboard (patches/web/0105): the keyboard in its place, kept
    // there while the page shows, rather than over the page.
    const root = el.closest('[data-ui="search-page"]');
    if (root) return openSearchScreen(el, root);
    if (el === searchOpened || editing || el.value) return;
    searchOpened = el;
    openKeyboard(el);
  };

  /*
   * The Search page as tvOS's own search screen (patches/web/0105): the app shows tvOS's search keyboard
   * in the page's place, the linear one across its top or the grid one down its left, and the page draws
   * its chips and results in the space tvOS gives its results. Focus moves between them as on tvOS: off
   * the keys (`fromKeys`) into the page, and back as it reaches the keyboard's space in the page
   * (`[data-ui="tvos-search-keys"]`), which tells the app to give the keyboard the remote. What's typed goes
   * into the page's field as with the keyboard over the page (`input`); a term the page puts there itself, a
   * chip's, goes back to the keyboard (`tvos-search-text`).
   */
  let searchScreen = null;
  /** Focus is on its way out of the keyboard's space, so reaching it doesn't give the keyboard the remote. */
  let leavingKeys = false;
  const KEYS = '[data-ui="tvos-search-keys"]';
  const searchRect = (root) => {
    const r = root.getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height };
  };
  const openSearchScreen = (el, root) => {
    if (searchScreen && searchScreen.el === el && searchScreen.root === root) return;
    const reopened = !!searchScreen;
    closeSearchScreen(false);
    editing = el;
    // The page's own height below its top, so only its results scroll.
    root.style.setProperty('--tvos-search-top', `${root.getBoundingClientRect().top + scrollY}px`);
    searchScreen = { el, root, value: el.value || '', watch: 0 };
    send({
      type: 'tvos-search-screen',
      open: true,
      value: el.value || '',
      label: el.getAttribute('aria-label') || el.placeholder || '',
      rect: searchRect(root),
      pageWidth: window.innerWidth,
      // Back to a search's results (its term in the address) stays on the results, as tvOS's does.
      focusKeys: !el.value && !reopened,
    });
    // Its place once the page has settled, which its first frame may not have.
    setTimeout(() => {
      if (searchScreen?.root !== root || !root.isConnected) return;
      send({ type: 'tvos-search-screen', open: true, rect: searchRect(root), pageWidth: window.innerWidth });
    }, 300);
    // A term the page sets itself, a chip's, onto the keyboard's field.
    searchScreen.watch = setInterval(() => {
      const open = searchScreen;
      if (!open) return;
      if (!open.el.isConnected || !open.root.isConnected) return closeSearchScreen(true);
      if (open.el.value === open.value) return;
      open.value = open.el.value;
      send({ type: 'tvos-search-text', value: open.value });
    }, 200);
  };
  const closeSearchScreen = (tell) => {
    const open = searchScreen;
    if (!open) return;
    searchScreen = null;
    clearInterval(open.watch);
    if (editing === open.el) editing = null;
    if (tell) send({ type: 'tvos-search-screen', open: false });
  };
  // Leaving the Search page takes the keyboard with it.
  const leftSearch = () => {
    if (searchScreen && location.hash.slice(1).split('?')[0] !== '/search') closeSearchScreen(true);
  };
  document.addEventListener(
    'focusin',
    (e) => {
      if (!searchScreen || leavingKeys) return;
      if (e.target instanceof Element && e.target.matches(KEYS)) send({ type: 'tvos-search-keys' });
    },
    true
  );
  /*
   * The page's router (TanStack's hash history) moves between pages with history.pushState and
   * replaceState, which fire no hashchange, so opening Search from the navigation never reached
   * this. Both are wrapped here, at document start, before the router wraps them in turn; Back
   * and Forward come as popstate. Checked after the call, once the address has changed.
   */
  const routed = () => {
    leftSearch();
    openSearchKeyboard();
  };
  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    history[name] = function (...args) {
      const result = original.apply(this, args);
      setTimeout(routed);
      return result;
    };
  }
  window.addEventListener('popstate', routed);
  window.addEventListener('hashchange', routed);
  window.addEventListener('load', routed);

  Object.defineProperty(window, '__aioTV', {
    value: Object.freeze({
      down(name, repeat) {
        const el = target();
        // Back to the card the navigation was opened from.
        if (name === FROM_NAV() && !repeat && leftFrom && el.closest?.(NAV_SIDE) && shown(leftFrom)) {
          const card = leftFrom;
          leftFrom = null;
          swallowed = name;
          focusNav(card);
          return;
        }
        const list = isTextField(el) && listField(el);
        // tvOS has no keyboard for a web page, so the app shows its own: Enter in a text field,
        // except on a list's highlighted entry, which it picks; Up from a list's top entry. A
        // held Up, or presses as quick as its repeats, stays in the list, so running up through
        // it stops at the top rather than opening the keyboard there.
        const quick = !!repeat || performance.now() - lastDown < 150;
        const opens = list
          ? (name === 'Enter' && !highlightedEntry(el)) || (name === 'ArrowUp' && !quick && atTop(el))
          : name === 'Enter' && isTextField(el);
        if (opens) {
          if (repeat) return;
          swallowed = name;
          openKeyboard(el);
          return;
        }
        // Toward the navigation from the first poster of a grid's line: into it, not up a line.
        if (name === TOWARD_NAV() && !repeat && inRow(el) && startsGridLine(el)) {
          const to = navEntry();
          if (to) {
            lastDown = performance.now();
            leftFrom = el;
            swallowed = name;
            focusNav(to);
            return;
          }
        }
        // A held key, or presses as quick as one, such as a fast swipe on the clickpad.
        const now = performance.now();
        held = !!repeat || now - lastDown < 150;
        lastDown = now;
        key('keydown', name, repeat);
        // A scrolled slide runs no animation to wait for, so the artwork sweep is told how long it runs.
        if (PAGE_SCROLLS && (name === 'ArrowUp' || name === 'ArrowDown'))
          slidingUntil = Math.max(slidingUntil, performance.now() + 300);
        // Toward the navigation from a row's first card that the page left where it was: into it.
        if (name === TOWARD_NAV() && !repeat && inRow(el)) {
          const pressed = now;
          setTimeout(() => {
            if (lastDown !== pressed || document.activeElement !== el) return;
            const to = navEntry();
            if (!to) return;
            leftFrom = el;
            focusNav(to);
          }, 0);
        }
        // Moves that scroll by transforms alone fire no scroll event.
        soonSweep();
      },
      up(name) {
        if (name === swallowed) {
          swallowed = null;
          return;
        }
        key('keyup', name);
      },
      /** Each change on the app's search keyboard, into the field it was opened for. */
      input(value) {
        const el = editing;
        if (el && el.isConnected) setValue(el, value);
        if (searchScreen && searchScreen.el === el) searchScreen.value = value;
      },
      /**
       * Focus left the Search page's keyboard (patches/web/0105) that way: on into the page from the
       * keyboard's space, as an arrow from there takes it; toward the navigation, into it, where the
       * page found nothing that way. With nowhere to go, the keyboard has the remote again.
       */
      fromKeys(name) {
        const open = searchScreen;
        const keys = open && open.root.querySelector(KEYS);
        if (!keys) return;
        leavingKeys = true;
        keys.focus({ preventScroll: true });
        key('keydown', name, false);
        key('keyup', name);
        setTimeout(() => {
          leavingKeys = false;
          if (document.activeElement !== keys) return;
          const nav = name === TOWARD_NAV() ? navEntry() : null;
          if (nav) return focusNav(nav);
          send({ type: 'tvos-search-keys' });
        }, 60);
      },
      /** Where tvOS lays out the Search page's results, in points from the page's corner, for the page's layout. */
      searchResults(kind, x, y, webWidth) {
        const open = searchScreen;
        if (!open || !(webWidth > 0)) return;
        const px = (points) => `${Math.max(0, points) * (window.innerWidth / webWidth)}px`;
        open.root.dataset.keys = kind;
        open.root.style.setProperty('--tvos-results-x', px(x));
        open.root.style.setProperty('--tvos-results-y', px(y));
      },
      /** The app's keyboard closed; with `submit`, the field's form is sent. */
      done(submit) {
        const el = editing;
        editing = null;
        // The key that opened the keyboard was let go over it, out of the page's sight.
        swallowed = null;
        if (!el || !el.isConnected) return;
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.focus();
        // After React has taken the new value.
        const form = el.form;
        if (submit && form)
          setTimeout(() => {
            if (form.requestSubmit) form.requestSubmit();
            else form.submit();
          }, 250);
      },
      /** tvOS is short of memory: artwork beyond the screen and a little around it lets go of its picture. */
      trim() {
        requestAnimationFrame(() => sweep(TRIM_SCREENS));
      },
      /** Whether the player's picture-in-picture button shows. */
      pip(offered) {
        pipOffered = !!offered;
        watchPip(pipOffered);
        queuePip();
      },
    }),
  });

  /*
   * A picture-in-picture button in the player's bottom bar, after the page's
   * own buttons. The page has none for the apps (Android enters it on leaving
   * the app, which tvOS doesn't allow), so the app adds one while a video
   * plays and the page's Picture-in-picture setting is on. It takes the look
   * of the page's buttons, and the page's remote focus and Select reach it as
   * they reach any button. React leaves a node it didn't make alone; when it
   * builds the bar again, the button goes back in.
   */
  const PIP_ICON =
    '<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<path d="M21 9V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10c0 1.1.9 2 2 2h4"/>' +
    '<rect width="10" height="7" x="12" y="13" rx="2"/></svg>';
  let pipOffered = false;
  let pipButton = null;
  let pipQueued = false;
  /*
   * The label over the button while it has focus, as the page's own buttons
   * show theirs: the page's tooltip classes, above the button and centred on
   * it, kept on screen. The page hides its controls by taking focus away,
   * which takes the label with it.
   */
  let pipLabel = null;
  const PIP_LABEL_GAP = 4;
  /*
   * The button's name in the page's language, as the web app's own catalogs word Picture-in-picture
   * where they have it: its own, else one in the same language, else British English.
   */
  const PIP_NAMES = {
    'en-GB': 'Picture in picture', ar: 'صورة داخل صورة', ca: "Imatge dins d'imatge", de: 'Bild-in-Bild',
    el: 'Εικόνα μέσα σε εικόνα', es: 'Imagen en imagen', fi: 'Kuva kuvassa', fr: "Image dans l'image",
    he: 'תמונה בתוך תמונה', id: 'Picture-in-picture', it: 'Picture-in-picture', ms: 'Gambar dalam gambar', nb: 'Bilde-i-bilde',
    nl: 'Beeld-in-beeld', pl: 'Obraz w obrazie', pt: 'Imagem na imagem', 'pt-BR': 'Picture-in-picture',
    ro: 'Imagine în imagine', ru: 'Картинка в картинке', sl: 'Slika v sliki', sv: 'Bild-i-bild',
    tr: 'Resim içinde resim', 'zh-Hans': '画中画',
  };
  const pipName = () => {
    const lang = document.documentElement.lang || 'en-GB';
    const base = lang.split('-')[0].toLowerCase();
    if (PIP_NAMES[lang]) return PIP_NAMES[lang];
    const same = Object.keys(PIP_NAMES).find((key) => key.split('-')[0].toLowerCase() === base);
    return PIP_NAMES[same || 'en-GB'];
  };
  const showPipLabel = () => {
    if (!pipButton?.isConnected) return;
    if (!pipLabel) {
      pipLabel = document.createElement('div');
      pipLabel.setAttribute('role', 'tooltip');
      pipLabel.dataset.side = 'top';
      pipLabel.className =
        'UI-Tooltip__root z-50 overflow-hidden rounded-xl px-3 py-1.5 text-sm shadow-md ' +
        'animate-in fade-in-50 bg-gray-900 border text-white data-[side=top]:slide-in-from-bottom-1';
      pipLabel.style.position = 'fixed';
      pipLabel.style.pointerEvents = 'none';
      pipLabel.style.whiteSpace = 'nowrap';
    }
    // In the language shown now, which can change while the player is open.
    pipLabel.textContent = pipName();
    document.body.appendChild(pipLabel);
    const button = pipButton.getBoundingClientRect();
    const label = pipLabel.getBoundingClientRect();
    const left = Math.min(
      Math.max(8, button.left + button.width / 2 - label.width / 2),
      window.innerWidth - label.width - 8
    );
    pipLabel.style.left = `${left}px`;
    pipLabel.style.top = `${button.top - label.height - PIP_LABEL_GAP}px`;
  };
  const hidePipLabel = () => pipLabel?.remove();
  const placePip = () => {
    pipQueued = false;
    if (!pipOffered) {
      hidePipLabel();
      pipButton?.remove();
      return;
    }
    // The bar's last row holds play, the skips and the option buttons.
    const row = document.querySelector('[data-ui=player-bottom-bar]')?.lastElementChild;
    const like = row?.querySelector('[data-ui=player-button]');
    if (!row || !like || pipButton?.parentElement === row) return;
    if (!pipButton) {
      pipButton = document.createElement('button');
      pipButton.type = 'button';
      pipButton.dataset.ui = 'player-button';
      pipButton.dataset.name = 'tvos-pip';
      pipButton.dataset.focus = 'own';
      pipButton.innerHTML = PIP_ICON;
      pipButton.addEventListener('click', () => {
        hidePipLabel();
        send({ type: 'tvos-pip' });
      });
      pipButton.addEventListener('focus', showPipLabel);
      pipButton.addEventListener('blur', hidePipLabel);
    }
    pipButton.className = like.className;
    pipButton.setAttribute('aria-label', pipName());
    pipButton.title = pipName();
    row.appendChild(pipButton);
  };
  const queuePip = () => {
    if (pipQueued) return;
    pipQueued = true;
    requestAnimationFrame(placePip);
  };
  /*
   * Puts the button back when React rebuilds the bar. Watched only while the
   * button is offered (a video playing): on the catalog pages every row and
   * card React mounts would otherwise be a record for it.
   */
  let pipObserver = null;
  const watchPip = (on) => {
    try {
      if (on && !pipObserver) {
        pipObserver = new MutationObserver(() => {
          if (pipLabel?.isConnected && !pipButton?.isConnected) hidePipLabel();
          if (pipOffered && !pipButton?.isConnected) queuePip();
        });
        pipObserver.observe(document.documentElement, { childList: true, subtree: true });
      } else if (!on && pipObserver) {
        pipObserver.disconnect();
        pipObserver = null;
      }
    } catch {}
  };

  // A TV has no console; the app keeps these in its start-up log.
  window.addEventListener('error', (e) =>
    send({
      type: 'web-error',
      message: String(e.message || e.error) + (e.filename ? ` (${e.filename}:${e.lineno})` : ''),
    })
  );
  window.addEventListener('unhandledrejection', (e) =>
    send({ type: 'web-error', message: 'Unhandled rejection: ' + String(e.reason?.stack || e.reason) })
  );
  /*
   * Errors the page catches itself and only logs, such as one React throws while drawing, which
   * leaves its error screen under the splash, so only the logo shows. The first few go to the app
   * menu's report with the uncaught ones above.
   */
  try {
    const consoleError = console.error;
    let told = 0;
    console.error = function (...args) {
      try {
        if (told < 20) {
          told++;
          const text = args
            .map((a) => (a instanceof Error ? a.stack || a.message : typeof a === 'string' ? a : JSON.stringify(a)))
            .join(' ');
          send({ type: 'web-error', message: 'console.error: ' + text.slice(0, 600) });
        }
      } catch {}
      return consoleError.apply(this, args);
    };
  } catch {}

  /*
   * What the page holds that tvOS counts against its process, as far as the
   * page can see: every picture loaded (width × height × 4 bytes decoded),
   * the artwork the sweep released, canvases, videos and how many elements
   * there are. tvOS's WebKit won't tell the app the process's own size, so
   * this is sent every few seconds for the app's memory log, to tell
   * pictures from layers when the process is ended for memory. WebKit may
   * still keep a picture's decoded copy a while after the page lets go of
   * it, so it's a floor, not the whole.
   */
  const STATS_EVERY = 5000;
  /*
   * Pictures made anywhere, on the page or off it: `new Image()` (as the page decodes one ahead)
   * and every <img> made, watched through weak references, so watching keeps none of them. Those
   * no longer on the page but still loaded are counted: a picture let go of by the page but still
   * held by something, or not yet collected. tvOS ended the page's process at its 1 GB limit with
   * the pictures on the page about 25 MB, so the rest is somewhere none of the counts here saw.
   */
  /*
   * What may hold a page taken down, for the memory log: after collections on demand, removed
   * pictures still alive went past 1000 browsing titles, so something holds each closed page. A
   * listener on the window or the document that's never taken off keeps what its function
   * refers to, so live ones are counted by type, and live intervals too.
   */
  const liveListeners = new Map();
  let liveIntervals = 0;
  try {
    for (const target of [window, document]) {
      const add = target.addEventListener;
      const remove = target.removeEventListener;
      const name = target === window ? 'window' : 'document';
      const keyOf = (type, options) =>
        `${name} ${type}${(typeof options === 'boolean' ? options : !!options?.capture) ? ' capture' : ''}`;
      target.addEventListener = function (type, listener, options) {
        // A bare `addEventListener(...)` in strict code comes with no `this`, and is the window's.
        // Not one that takes itself off (`once`), which no removal would take out of the count, and so
        // the count would hold; one taken off by its `signal` leaves the count as it goes.
        if (listener && !options?.once && (this === target || (this == null && target === window))) {
          const key = keyOf(type, options);
          let set = liveListeners.get(key);
          if (!set) liveListeners.set(key, (set = new Set()));
          set.add(listener);
          options?.signal?.addEventListener?.('abort', () => set.delete(listener), { once: true });
        }
        return add.call(this, type, listener, options);
      };
      target.removeEventListener = function (type, listener, options) {
        if (listener && (this === target || (this == null && target === window)))
          liveListeners.get(keyOf(type, options))?.delete(listener);
        return remove.call(this, type, listener, options);
      };
    }
    const setIntervalNative = window.setInterval;
    const clearIntervalNative = window.clearInterval;
    const intervals = new Set();
    window.setInterval = function (...args) {
      const id = setIntervalNative.apply(this, args);
      intervals.add(id);
      liveIntervals = intervals.size;
      return id;
    };
    window.clearInterval = function (id) {
      intervals.delete(id);
      liveIntervals = intervals.size;
      return clearIntervalNative.call(this, id);
    };
  } catch {}
  /** What was taken down with each picture taken off the page, and the route it was made on. */
  const removedFrom = new WeakMap();
  const madeOn = new WeakMap();
  const madeImages = [];
  let imagesMade = 0;
  const MADE_WATCHED = 6000;
  const watchImage = (img) => {
    imagesMade++;
    madeOn.set(img, location.hash.slice(1).split('?')[0] || '/');
    madeImages.push(new WeakRef(img));
    // The oldest go unwatched past this many, so the list stays small.
    if (madeImages.length > MADE_WATCHED) madeImages.splice(0, madeImages.length - MADE_WATCHED);
  };
  try {
    if (typeof WeakRef === 'function') {
      const NativeImage = window.Image;
      window.Image = new Proxy(NativeImage, {
        construct(target, args) {
          const img = Reflect.construct(target, args);
          watchImage(img);
          return img;
        },
      });
      const createElement = Document.prototype.createElement;
      Document.prototype.createElement = function (name, options) {
        const el = createElement.call(this, name, options);
        if (el instanceof HTMLImageElement) watchImage(el);
        return el;
      };
    }
  } catch {}
  /*
   * How much the page keeps from the server (patches/web/0064, `__aioQueryStats`): its queries,
   * catalog pages and items, counted rather than written out as JSON, which made a spike of its own.
   * Every 30 s, as counting still reads through all of it.
   */
  const QUERY_STATS_EVERY = 30000;
  let queryStats = null;
  let queryStatsAt = -Infinity;
  const pageStats = () => {
    // Off the page: still loaded, and not on it.
    let offPage = 0;
    let offPageLoaded = 0;
    let offPageBytes = 0;
    // The pictures off the page still alive, by what was taken down with them and the page they were made on.
    const offByWhat = new Map();
    const offByRoute = new Map();
    let offPageReact = 0;
    try {
      let kept = 0;
      for (const ref of madeImages) {
        const img = ref.deref();
        if (!img) continue;
        madeImages[kept++] = ref;
        if (img.isConnected) continue;
        offPage++;
        const what = removedFrom.get(img) || 'never on the page';
        offByWhat.set(what, (offByWhat.get(what) || 0) + 1);
        // React takes its own properties off an element it unmounts; still there, it never finished.
        if (Object.keys(img).some((key) => key.startsWith('__reactFiber$') || key.startsWith('__reactProps$')))
          offPageReact++;
        const on = madeOn.get(img) || '?';
        offByRoute.set(on, (offByRoute.get(on) || 0) + 1);
        const w = img.naturalWidth;
        const h = img.naturalHeight;
        if (img.complete && w && h && !String(img.getAttribute('src') || '').startsWith('data:')) {
          offPageLoaded++;
          offPageBytes += w * h * 4;
        }
      }
      madeImages.length = kept;
    } catch {}
    try {
      const now = performance.now();
      if (now - queryStatsAt >= QUERY_STATS_EVERY && typeof window.__aioQueryStats === 'function') {
        queryStatsAt = now;
        queryStats = window.__aioQueryStats();
      }
    } catch {}
    let pictures = 0;
    let pictureBytes = 0;
    let artwork = 0;
    let artworkBytes = 0;
    let largest = 0;
    let largestSize = '';
    let largestImg = null;
    let releasedCount = 0;
    for (const img of document.images) {
      if (img.getAttribute('src') === BLANK) {
        releasedCount++;
        continue;
      }
      const w = img.naturalWidth;
      const h = img.naturalHeight;
      if (!img.complete || !w || !h) continue;
      const bytes = w * h * 4;
      pictures++;
      pictureBytes += bytes;
      if (img.getAttribute('data-ui') === 'artwork') {
        artwork++;
        artworkBytes += bytes;
      }
      if (bytes > largest) {
        largest = bytes;
        largestSize = `${w}x${h}`;
        largestImg = img;
      }
    }
    /*
     * Which element holds the largest picture, and whence: the app's `/fit/` copy (patch 0042,
     * ImageFit.swift), a blob the page made, or the host's own copy. Named so a picture past the
     * screen's width can be traced to what drew it.
     */
    let largestFrom = '';
    try {
      if (largestImg) {
        const src = largestImg.currentSrc || largestImg.src || '';
        const address = new URL(src, location.href);
        const at = src.startsWith('blob:')
          ? 'a blob'
          : address.pathname.startsWith('/fit/') && address.protocol === 'aiostv:'
            ? 'the app, drawn down'
            : address.host;
        const named =
          largestImg.getAttribute('data-ui') ||
          largestImg.closest('[data-ui]')?.getAttribute('data-ui') ||
          'img';
        largestFrom = `${named} from ${at}`;
      }
    } catch {}
    /*
     * Roughly what the page's own drawing layers take: each element drawn into a
     * buffer of its own (glide layers, will-change, blurs, videos), by its box
     * near the screen at WebKit's drawing scale, as WebKit draws a large layer
     * only near what shows. Not in the picture counts above; an estimate, as
     * WebKit may share or skip a layer that paints nothing of its own.
     */
    let layerBytes = 0;
    let layerCount = 0;
    let blurCount = 0;
    try {
      const scale = drawScale || 1;
      const nearW = innerWidth;
      const nearH = innerHeight;
      const layered = document.querySelectorAll(
        '[data-glide-layer],.will-change-transform,[class*="will-change"],[class*="backdrop-blur"],[class*="blur-"],video,canvas'
      );
      for (const el of layered) {
        if (el.closest('[inert]') && !el.closest('[data-page="home"]')) continue;
        const r = el.getBoundingClientRect();
        const w = Math.max(0, Math.min(r.right, innerWidth + nearW) - Math.max(r.left, -nearW));
        const h = Math.max(0, Math.min(r.bottom, innerHeight + nearH) - Math.max(r.top, -nearH));
        if (!w || !h) continue;
        // As drawn: a row's glide layers away from focus, and the bridge's own rules, take theirs off.
        const style = getComputedStyle(el);
        const backdrop = style.backdropFilter || style.webkitBackdropFilter || 'none';
        const blurred = backdrop !== 'none' || /blur/.test(style.filter || '');
        const own = el.tagName === 'VIDEO' || el.tagName === 'CANVAS';
        if (!own && !blurred && (style.willChange || 'auto') === 'auto') continue;
        layerCount++;
        if (blurred) blurCount++;
        // A blur draws what's behind it again, into a buffer of its own.
        layerBytes += w * h * scale * scale * 4 * (blurred ? 2 : 1);
      }
    } catch {}
    let canvasBytes = 0;
    const canvases = document.getElementsByTagName('canvas');
    for (const c of canvases) canvasBytes += c.width * c.height * 4;
    const mb = (bytes) => Math.round(bytes / 1048576);
    /*
     * What the page's artwork workers are doing (the web app's lib/artwork.ts,
     * patch 0027). Their decodes happen inside the page's process but are in
     * none of the counts above, so a kill with few pictures may be theirs.
     * None at all is reported too: this WebKit may not start them for the app's scheme.
     */
    let art = {};
    try {
      art = (window.__aioArtworkStats && window.__aioArtworkStats()) || {};
    } catch {}
    return {
      type: 'tvos-page-stats',
      drawScale,
      viewport: `${innerWidth}x${innerHeight}`,
      layerMB: Math.round(layerBytes / 1048576),
      layerCount,
      blurCount,
      artWorkers: art.workers || 0,
      artQueued: art.queued || 0,
      artRunning: art.running || 0,
      artSlow: art.slow || 0,
      artPeak: art.peakRunning || 0,
      artKept: art.kept || 0,
      artKeptMB: art.keptMB || 0,
      largestFrom,
      // The kinds of element there are most of, for a page that grows as it's browsed.
      mostUi: (() => {
        try {
          const tally = new Map();
          for (const el of document.querySelectorAll('[data-ui]')) {
            const name = el.getAttribute('data-ui');
            tally.set(name, (tally.get(name) || 0) + 1);
          }
          return [...tally].sort((a, b) => b[1] - a[1]).slice(0, 4).map(([n, c]) => `${n} ${c}`).join(', ');
        } catch {
          return '';
        }
      })(),
      // What was on screen that the reloads with "Background from artwork" on point at.
      artWash: document.documentElement.hasAttribute('data-art-wash'),
      // What the app draws beneath the page now (patches/web/0048): its colour, the wash and the backdrop.
      appArt: ['data-app-color', 'data-app-wash', 'data-app-backdrop']
        .filter((name) => document.documentElement.hasAttribute(name))
        .join(' ') || 'none',
      cardPreview: !!document.querySelector('[data-ui="open-card"]:not(.invisible)'),
      layers: document.querySelectorAll('[data-glide-layer]').length,
      episodes: document.querySelectorAll('[data-ui="episode-card"],[data-ui="episode-list-item"]').length,
      path: location.pathname + location.search + location.hash,
      pictures,
      pictureMB: mb(pictureBytes),
      artwork,
      artworkMB: mb(artworkBytes),
      largest: largestSize,
      released: releasedCount,
      canvases: canvases.length,
      canvasMB: mb(canvasBytes),
      videos: document.getElementsByTagName('video').length,
      elements: document.getElementsByTagName('*').length,
      cards: document.querySelectorAll('[data-ui="poster-card"]').length,
      imagesMade,
      offPage,
      offPageLoaded,
      offPageMB: mb(offPageBytes),
      offPageRoutes: offByRoute.size,
      offPageReact,
      pagesDismantled,
      offPageBy: (() => {
        const top = (map, n) => [...map].sort((a, b) => b[1] - a[1]).slice(0, n);
        // A title's address shortened to its last characters, enough to tell titles apart.
        const short = (route) => route.replace(/[0-9a-f-]{20,}/gi, (id) => '…' + id.slice(-6));
        const what = top(offByWhat, 4).map(([w, c]) => `${w} ${c}`).join(', ');
        const routes = top(offByRoute, 4).map(([r, c]) => `${short(r)} ${c}`).join(', ');
        return what ? `taken down with ${what}; made on ${routes}` : '';
      })(),
      // What may hold a closed page: listeners never taken off, intervals never cleared, the page's subscribers to the app.
      listenersBy: (() => {
        const live = [...liveListeners].map(([key, set]) => [key, set.size]).filter(([, n]) => n > 0);
        const total = live.reduce((sum, [, n]) => sum + n, 0);
        const most = live.sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, n]) => `${k} ${n}`).join(', ');
        return `${total} on the window and document (most ${most})`;
      })(),
      intervals: liveIntervals,
      appListeners: listeners.size,
      // Animations whose element was taken down: cancelled so WebKit's timeline lets go, and any still alive.
      animationsBy: (() => {
        let alive = 0;
        let removed = 0;
        for (const ref of madeAnimations) {
          const animation = ref.deref();
          if (!animation) continue;
          alive++;
          const target = animation.effect?.target;
          if (target && !target.isConnected) removed++;
        }
        // Cards faded in by CSS, alive and off the page: these should go with their page.
        let cardsKept = 0;
        let cardsOff = 0;
        for (const ref of cardsIn) {
          const card = ref.deref();
          if (!card) continue;
          cardsIn[cardsKept++] = ref;
          if (!card.isConnected) cardsOff++;
        }
        cardsIn.length = cardsKept;
        const total = [...animationsCancelled.values()].reduce((sum, n) => sum + n, 0);
        const most = [...animationsCancelled].sort((a, b) => b[1] - a[1]).slice(0, 4)
          .map(([on, n]) => `${on} ${n}`).join(', ');
        return `${alive} alive (${removed} on removed elements), ${total} cancelled as their element went` +
          (most ? ` (most ${most})` : '') +
          `; cards faded in by CSS ${cardsKept} alive, ${cardsOff} of them off the page`;
      })(),
      ...(queryStats && {
        queries: queryStats.queries || 0,
        queryPages: queryStats.pages || 0,
        queryItems: queryStats.items || 0,
        queryLargestItems: queryStats.largest || 0,
        queryLargest: String(queryStats.largestKey || ''),
      }),
    };
  };
  try {
    setInterval(() => {
      try {
        send(pageStats());
      } catch {}
    }, STATS_EVERY);
  } catch {}

  /*
   * Each move between pages, such as Back from a title to Home, told to the app
   * as it happens, and the page's counts a second later, once the new page is
   * drawn. An end of the page's process can then be put next to the move that
   * came just before it. The move itself is only two paths, so it adds nothing
   * to the work of the moment it reports.
   */
  const MOVE_CHECK_EVERY = 250;
  const MOVE_STATS_AFTER = 1000;
  const routeOf = (hash) => hash.slice(1).split('?')[0] || '/';
  try {
    let lastRoute = routeOf(location.hash);
    setInterval(() => {
      try {
        const route = routeOf(location.hash);
        if (route === lastRoute) return;
        send({ type: 'tvos-page-moved', from: lastRoute, to: route });
        lastRoute = route;
        setTimeout(() => {
          try {
            send(pageStats());
          } catch {}
        }, MOVE_STATS_AFTER);
      } catch {}
    }, MOVE_CHECK_EVERY);
  } catch {}

  send({ type: 'hello' });
})();
"""#
}
