import Foundation

/// The JavaScript the WebKit backend runs in its own content world. Every script is the body of an
/// async function (`callAsyncJavaScript`): agent-supplied values arrive as arguments, never spliced
/// into the source, and every script returns a JSON string.
enum WebKitScripts {
    /// Collects the page's elements into `window.__ac` (an isolated world: the page cannot see it) and
    /// returns them with their role, label, state and frame. `gen` changes on every snapshot, so an id
    /// from an older one is refused instead of landing on a different element.
    static let snapshot = """
    const INTERACTIVE = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=checkbox],[role=radio],[role=switch],[role=option],[role=combobox],[role=textbox],[role=searchbox],[role=slider],[role=spinbutton],[role=treeitem],[contenteditable=""],[contenteditable="true"],[tabindex]:not([tabindex="-1"]),[onclick]';
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','HEAD','META','LINK','TITLE','BR','HTML','BODY','SVG','PATH','G']);
    const ac = window.__ac || (window.__ac = { gen: 0, nodes: [] });
    ac.gen += 1;
    ac.nodes = [];
    const shown = (el) => {
      const s = getComputedStyle(el);
      if (s.visibility === 'hidden' || s.display === 'none') return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    const clean = (t) => (t || '').replace(/\\s+/g, ' ').trim();
    const textOf = (el) => clean(el.innerText || el.textContent);
    const roleOf = (el) => {
      const explicit = (el.getAttribute('role') || '').split(' ')[0].toLowerCase();
      if (explicit) return explicit;
      const tag = el.tagName.toLowerCase();
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (tag === 'a') return el.hasAttribute('href') ? 'link' : 'generic';
      if (tag === 'button' || tag === 'summary') return 'button';
      if (tag === 'select') return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'input') {
        if (['button','submit','reset','image','file','color'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        if (type === 'search') return 'searchbox';
        if (type === 'number') return 'spinbutton';
        return 'textbox';
      }
      if (/^h[1-6]$/.test(tag)) return 'heading';
      if (tag === 'img') return 'image';
      if (el.isContentEditable) return 'textbox';
      return 'generic';
    };
    const labelOf = (el) => {
      const aria = el.getAttribute('aria-label');
      if (aria && clean(aria)) return clean(aria);
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const t = clean(by.split(/\\s+/).map((id) => { const n = document.getElementById(id); return n ? n.textContent : ''; }).join(' '));
        if (t) return t;
      }
      if (el.labels && el.labels.length) { const t = clean(Array.from(el.labels).map((l) => l.textContent).join(' ')); if (t) return t; }
      const tag = el.tagName.toLowerCase();
      if (tag === 'input' || tag === 'textarea' || tag === 'select') {
        const type = (el.getAttribute('type') || '').toLowerCase();
        if (['button','submit','reset'].includes(type) && el.value) return clean(el.value);
        if (el.placeholder) return clean(el.placeholder);
        if (el.title) return clean(el.title);
        return clean(el.name || el.id || '');
      }
      if (tag === 'img') return clean(el.alt || el.title || '');
      const t = textOf(el);
      if (t) return t.length > 160 ? t.slice(0, 157) + '...' : t;
      return clean(el.title || el.getAttribute('alt') || '');
    };
    const identCss = identifier;
    const out = [];
    let total = 0;
    const included = new Set();
    const visit = (root) => {
      for (const el of root.querySelectorAll('*')) {
        if (el.shadowRoot) visit(el.shadowRoot);
        if (SKIP.has(el.tagName.toUpperCase())) continue;
        const ident = identCss ? el.matches(identCss) : false;
        let take = ident || el.matches(INTERACTIVE);
        let role = null;
        if (!take && !interactiveOnly) {
          const tag = el.tagName.toLowerCase();
          if (/^h[1-6]$/.test(tag) || (tag === 'img' && el.alt) || tag === 'label') take = true;
          else if (Array.from(el.childNodes).some((n) => n.nodeType === 3 && clean(n.textContent))) { take = true; role = 'text'; }
        }
        if (!take && el.parentElement && !included.has(el.parentElement)) {
          // A div with a click handler has no semantics; the pointer is what says it is a control.
          const cursor = getComputedStyle(el).cursor;
          if (cursor === 'pointer' && getComputedStyle(el.parentElement).cursor !== 'pointer' && (textOf(el) || el.getAttribute('aria-label'))) { take = true; role = 'button'; }
        }
        if (!take) continue;
        if (!shown(el) && !ident) continue;
        included.add(el);
        total += 1;
        if (out.length >= max) continue;
        const r = el.getBoundingClientRect();
        const entry = {
          i: ac.nodes.length,
          role: role || roleOf(el),
          label: labelOf(el),
          enabled: !(el.disabled === true || el.getAttribute('aria-disabled') === 'true'),
          x: Math.round(r.left * 10) / 10, y: Math.round(r.top * 10) / 10,
          w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10,
        };
        if (ident) entry.ident = true;
        if ('value' in el && typeof el.value === 'string' && entry.role !== 'button') entry.value = el.value.slice(0, 200);
        if (el.type === 'checkbox' || el.type === 'radio') entry.checked = !!el.checked;
        ac.nodes.push(el);
        out.push(entry);
      }
    };
    visit(document);
    return JSON.stringify({ gen: ac.gen, url: location.href, title: document.title, total: total, elements: out });
    """

    /// Scrolls the element into view and answers where a real click should land and whether
    /// something else covers that point.
    static let clickPoint = """
    const ac = window.__ac;
    if (!ac || ac.gen !== gen) return JSON.stringify({ stale: true });
    const el = ac.nodes[index];
    if (!el || !el.isConnected) return JSON.stringify({ stale: true });
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return JSON.stringify({ notClickable: 'it has no visible area (display:none, zero size, or fully clipped)' });
    const x = Math.min(Math.max(r.left + r.width / 2, 1), window.innerWidth - 1);
    const y = Math.min(Math.max(r.top + r.height / 2, 1), window.innerHeight - 1);
    const hit = document.elementFromPoint(x, y);
    const ok = !!hit && (el === hit || el.contains(hit) || hit.contains(el) || (hit.getRootNode() instanceof ShadowRoot));
    const tag = el.tagName.toLowerCase();
    const type = (el.getAttribute('type') || '').toLowerCase();
    const native = tag === 'select' || (tag === 'input' && ['file','color','date','datetime-local','month','time','week'].includes(type));
    const covered = ok ? null : (hit ? (hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '')) : 'nothing');
    return JSON.stringify({ x: x, y: y, ok: ok, native: native, covered: covered });
    """

    /// The plain DOM click used when a real pointer click cannot land (covered element).
    static let domClick = """
    const ac = window.__ac;
    if (!ac || ac.gen !== gen) return JSON.stringify({ stale: true });
    const el = ac.nodes[index];
    if (!el || !el.isConnected) return JSON.stringify({ stale: true });
    el.click();
    return JSON.stringify({ ok: true });
    """

    /// Focus the element and select its content so the next input replaces it; a `select` is set
    /// by option text or value instead, because a native menu cannot be opened off screen.
    static let prepareTyping = """
    const ac = window.__ac;
    if (!ac || ac.gen !== gen) return JSON.stringify({ stale: true });
    const el = ac.nodes[index];
    if (!el || !el.isConnected) return JSON.stringify({ stale: true });
    el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    if (el.tagName === 'SELECT') {
      const want = text.trim().toLowerCase();
      const options = Array.from(el.options);
      const hit = options.find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
        || options.find((o) => o.text.toLowerCase().includes(want));
      if (!hit) return JSON.stringify({ error: 'no option matches "' + text + '" (options: ' + options.slice(0, 12).map((o) => o.text.trim()).join(' | ') + ')' });
      el.value = hit.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return JSON.stringify({ handled: true, selected: hit.text.trim() });
    }
    if (el.tagName === 'INPUT' && ['checkbox','radio','file','button','submit','reset','image','color','range'].includes((el.type || '').toLowerCase())) {
      return JSON.stringify({ error: 'a ' + el.type + ' input takes no typed text; use click' });
    }
    el.focus({ preventScroll: true });
    if ('value' in el && typeof el.select === 'function') { try { el.select(); } catch (e) {} }
    else {
      const range = document.createRange();
      range.selectNodeContents(el);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
    return JSON.stringify({ handled: false, focused: document.activeElement === el || el.contains(document.activeElement) });
    """

    static let readElement = """
    const ac = window.__ac;
    if (!ac || ac.gen !== gen) return JSON.stringify({ stale: true });
    const el = ac.nodes[index];
    if (!el || !el.isConnected) return JSON.stringify({ stale: true });
    const value = (el.value !== undefined && el.value !== null) ? String(el.value) : (el.innerText || el.textContent || '');
    return JSON.stringify({ text: value });
    """

    static let elementRect = """
    const ac = window.__ac;
    if (!ac || ac.gen !== gen) return JSON.stringify({ stale: true });
    const el = ac.nodes[index];
    if (!el || !el.isConnected) return JSON.stringify({ stale: true });
    el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    const r = el.getBoundingClientRect();
    return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height, vw: window.innerWidth, vh: window.innerHeight });
    """

    /// What the page itself sees: used for every result's `viewport` and to prove it is not throttled.
    static let pageState = """
    return JSON.stringify({
      visibility: document.visibilityState, hidden: document.hidden,
      width: window.innerWidth, height: window.innerHeight, dpr: window.devicePixelRatio,
      dark: window.matchMedia('(prefers-color-scheme: dark)').matches,
      scrollHeight: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0),
      scrollY: window.scrollY, readyState: document.readyState, title: document.title, url: location.href
    });
    """

    static let bodyText = "return JSON.stringify({ text: document.body ? document.body.innerText : '' });"

    static let scrollBy = """
    window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
    return JSON.stringify({ x: window.scrollX, y: window.scrollY });
    """

    /// `run_app_code`: global eval in the page's own world, awaiting a returned promise.
    static let evaluate = """
    const value = await (0, eval)(code);
    return JSON.stringify(value === undefined ? null : value);
    """

    /// Used only when the occlusion SPI is missing: the page is told it is visible, which keeps
    /// code that reads `document.hidden` polling, though WebKit still throttles its timers.
    static let forceVisible = """
    (function () {
      try {
        Object.defineProperty(document, 'hidden', { configurable: true, get: function () { return false; } });
        Object.defineProperty(document, 'visibilityState', { configurable: true, get: function () { return 'visible'; } });
      } catch (e) {}
    })();
    """
}
