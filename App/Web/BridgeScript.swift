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
        '*:not(' + HOLE + '):not(' + ART_FADES + '),*::before,*::after{-webkit-mask-image:none!important;mask-image:none!important}',
        "[data-ui='item-backdrop-shade'][data-name='bottom']" + shade('top', mix(70)),
        SIDE + shade('right', mix(70) + ' 35%'),
        "html[dir='rtl'] " + SIDE + shade('left', mix(70) + ' 35%'),
        "[data-ui='hero-shade'][data-name='bottom']" + shade('top', mix(60)),
        TRAILER_SIDE + shade('right', mix(60) + ' 30%'),
        "html[dir='rtl'] " + TRAILER_SIDE + shade('left', mix(60) + ' 30%'),
        "[class*='[mask-image:linear-gradient(to_top,black,rgb(0_0_0/0.6)_30%']" + shade('top', mix(60) + ' 30%'),
        "[class*='[mask-image:linear-gradient(to_bottom,rgb(0_0_0/0.7),transparent)]']" +
          '{background:linear-gradient(to bottom,' + mix(70) + ',transparent)!important}'
      );
    if (rules.length) {
      const style = document.createElement('style');
      style.textContent = rules.join('\n');
      (document.head || document.documentElement).appendChild(style);
    }
  } catch {}
  // When the last slide that is still running ends, so the artwork sweep below can wait for it.
  let slidingUntil = 0;
  try {
    const animate = Element.prototype.animate;
    Element.prototype.animate = function (keyframes, options) {
      const glide = !!(this.hasAttribute && this.hasAttribute('data-glide-layer'));
      if (glide && (!SLIDES || holding())) return animate.call(this, keyframes, { duration: 0 });
      const duration = typeof options === 'number' ? options : options?.duration;
      if (glide && typeof duration === 'number' && duration > 0)
        slidingUntil = Math.max(slidingUntil, performance.now() + duration);
      return animate.call(this, keyframes, options);
    };
  } catch {}
  // The page's saved copies of artwork come back as blob URLs too.
  try {
    localStorage.setItem('aiostreams-web-cache-artwork', 'false');
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

  const listeners = new Set();
  const post = (message) => handler.postMessage(JSON.stringify(message));
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
   * A catalog or collection is a grid (`data-nav-wrap`), where Left from the
   * first poster of a line wraps to the end of the line above, as text does,
   * so focus moves and the check after the key never sees it stay. Left from
   * a line's first poster goes to the navigation instead; Right off a line's
   * end still wraps. Left to right grids only.
   */
  const startsGridLine = (el) => {
    const grid = el.closest?.('[data-nav-wrap]');
    if (!grid || getComputedStyle(grid).direction === 'rtl') return false;
    let cell = el;
    while (cell && cell.parentElement !== grid) cell = cell.parentElement;
    if (!cell) return false;
    const at = cell.getBoundingClientRect();
    for (let prev = cell.previousElementSibling; prev; prev = prev.previousElementSibling) {
      const r = prev.getBoundingClientRect();
      if (!r.width && !r.height) continue;
      // The poster before it sits at or past its left edge: on the line above.
      return r.left >= at.left - 1;
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
    });
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
    if (el === searchOpened || editing || el.value) return;
    searchOpened = el;
    openKeyboard(el);
  };
  /*
   * The page's router (TanStack's hash history) moves between pages with history.pushState and
   * replaceState, which fire no hashchange, so opening Search from the navigation never reached
   * this. Both are wrapped here, at document start, before the router wraps them in turn; Back
   * and Forward come as popstate. Checked after the call, once the address has changed.
   */
  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    history[name] = function (...args) {
      const result = original.apply(this, args);
      setTimeout(() => openSearchKeyboard());
      return result;
    };
  }
  window.addEventListener('popstate', () => openSearchKeyboard());
  window.addEventListener('hashchange', () => openSearchKeyboard());
  window.addEventListener('load', () => openSearchKeyboard());

  Object.defineProperty(window, '__aioTV', {
    value: Object.freeze({
      down(name, repeat) {
        const el = target();
        // Back to the card the navigation was opened from.
        if (name === 'ArrowRight' && !repeat && leftFrom && el.closest?.(NAV_SIDE) && shown(leftFrom)) {
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
        // Left from the first poster of a grid's line: into the navigation, not up a line.
        if (name === 'ArrowLeft' && !repeat && inRow(el) && startsGridLine(el)) {
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
        // Left from a row's first card that the page left where it was: into the navigation.
        if (name === 'ArrowLeft' && !repeat && inRow(el)) {
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
      /** The text typed on the app's alert keyboard, all at once. */
      type(value, submit) {
        const el = editing;
        if (el && el.isConnected) setValue(el, value);
        this.done(submit);
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
      pipLabel.textContent = 'Picture in picture';
    }
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
      pipButton.setAttribute('aria-label', 'Picture in picture');
      pipButton.title = 'Picture in picture';
      pipButton.innerHTML = PIP_ICON;
      pipButton.addEventListener('click', () => {
        hidePipLabel();
        send({ type: 'tvos-pip' });
      });
      pipButton.addEventListener('focus', showPipLabel);
      pipButton.addEventListener('blur', hidePipLabel);
    }
    pipButton.className = like.className;
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
  const pageStats = () => {
    let pictures = 0;
    let pictureBytes = 0;
    let artwork = 0;
    let artworkBytes = 0;
    let largest = 0;
    let largestSize = '';
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
      }
    }
    let canvasBytes = 0;
    const canvases = document.getElementsByTagName('canvas');
    for (const c of canvases) canvasBytes += c.width * c.height * 4;
    const mb = (bytes) => Math.round(bytes / 1048576);
    /*
     * What the page's artwork workers are doing (the web app's lib/artwork.ts,
     * patch 0027). Their decodes happen inside the page's process but are in
     * none of the counts above, so a kill with few pictures may be theirs.
     */
    let art = {};
    try {
      art = (window.__aioArtworkStats && window.__aioArtworkStats()) || {};
    } catch {}
    return {
      type: 'tvos-page-stats',
      artWorkers: art.workers || 0,
      artQueued: art.queued || 0,
      artRunning: art.running || 0,
      artSlow: art.slow || 0,
      artPeak: art.peakRunning || 0,
      artKept: art.kept || 0,
      artKeptMB: art.keptMB || 0,
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
    };
  };
  try {
    setInterval(() => {
      try {
        send(pageStats());
      } catch {}
    }, STATS_EVERY);
  } catch {}

  send({ type: 'hello' });
})();
"""#
}
