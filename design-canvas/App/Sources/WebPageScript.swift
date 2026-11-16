/// Scripts the web renderer runs in a captured page.
enum WebPageScript {
    /// Waits for web fonts and for the page to settle (pages animate in), then puts the
    /// light theme on the root element when asked. `light` and `settle` are arguments.
    static let settle = """
        if (light) document.documentElement.dataset.theme = 'light';
        if (document.fonts && document.fonts.ready) { try { await document.fonts.ready; } catch (e) {} }
        await new Promise(r => setTimeout(r, settle));
        if (light) document.documentElement.dataset.theme = 'light';
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        return true;
        """

    /// The visible DOM and the `:root` custom properties, as `WebSnapshot` JSON.
    ///
    /// Invisible elements (display none, hidden, transparent, zero-size, outside the
    /// viewport) are left out. Wrapper-only elements (no text, nothing drawn, no id, role
    /// or label, one child) collapse into their child, so the tree reads like the design.
    /// Each element's path is unique in the page and stable across reloads: an `id` when
    /// it has a unique one, else its parent's path, `>`, its tag and first class, and an
    /// index among siblings with the same tag and class.
    static let snapshot = """
        const W = innerWidth, H = innerHeight, MAX = 1500;
        const SKIP = new Set(['script','style','meta','link','noscript','template','head','title','br','wbr','source','track','base']);
        const LEAF = new Set(['svg','canvas','img','video','audio','iframe','input','select','textarea','picture','object','embed','math']);
        const KEEP = new Set(['button','a','input','select','textarea','img','svg','canvas','video','iframe','label','h1','h2','h3','h4','h5','h6','p','li']);
        let emitted = 0, visited = 0;
        const clean = s => String(s).replace(/[^A-Za-z0-9_-]/g, '');
        const r1 = v => Math.round(v * 10) / 10;
        const transparent = c => !c || c === 'transparent' || /rgba\\([^)]*,\\s*0\\)$/.test(c) || /\\/\\s*0\\)$/.test(c);
        const classesOf = el => (el.getAttribute('class') || '').trim().split(/\\s+/).filter(Boolean);
        const signature = el => { const c = classesOf(el).map(clean).find(Boolean); return el.tagName.toLowerCase() + (c ? '.' + c : ''); };
        const uniqueID = el => { if (!el.id || !clean(el.id)) return false; try { return document.querySelectorAll('#' + CSS.escape(el.id)).length === 1; } catch (e) { return false; } };
        function ownText(el) {
          const inline = Array.from(el.children).every(c => getComputedStyle(c).display.startsWith('inline') && !LEAF.has(c.tagName.toLowerCase()));
          let t = '';
          if (el.children.length && inline) t = el.textContent;
          else for (const n of el.childNodes) if (n.nodeType === 3) t += n.textContent;
          t = t.replace(/\\s+/g, ' ').trim();
          return t.length > 140 ? t.slice(0, 139) + '…' : t;
        }
        function styles(el, cs, hasText) {
          const s = {};
          if (!transparent(cs.backgroundColor)) s.backgroundColor = cs.backgroundColor;
          const bw = parseFloat(cs.borderTopWidth) || 0;
          if (bw > 0 && cs.borderTopStyle !== 'none' && !transparent(cs.borderTopColor)) { s.borderColor = cs.borderTopColor; s.borderWidth = String(r1(bw)); }
          const radius = parseFloat(cs.borderTopLeftRadius) || 0;
          if (radius > 0) s.borderRadius = String(r1(radius));
          const pads = [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft].map(v => r1(parseFloat(v) || 0));
          if (pads.some(v => v > 0)) s.padding = pads.every(v => v === pads[0]) ? String(pads[0]) : pads.join(' ');
          if (cs.display !== 'block' && cs.display !== 'inline') s.display = cs.display;
          if (cs.display.includes('flex')) s.flexDirection = cs.flexDirection;
          if (cs.display.includes('flex') || cs.display.includes('grid')) {
            const g = parseFloat(cs.rowGap) || parseFloat(cs.columnGap) || 0;
            if (g > 0) s.gap = String(r1(g));
          }
          const op = parseFloat(cs.opacity);
          if (op < 1) s.opacity = String(Math.round(op * 100) / 100);
          const backdrop = cs.backdropFilter || cs.webkitBackdropFilter;
          if (backdrop && backdrop !== 'none') s.backdropFilter = backdrop;
          if (hasText) {
            s.color = cs.color;
            s.fontSize = String(r1(parseFloat(cs.fontSize) || 0));
            s.fontWeight = cs.fontWeight;
            s.fontFamily = cs.fontFamily.split(',')[0].replace(/["']/g, '').trim();
            const lh = parseFloat(cs.lineHeight);
            if (isFinite(lh)) s.lineHeight = String(r1(lh));
          }
          return s;
        }
        function visit(el, path, isRoot) {
          if (emitted >= MAX || ++visited > 20000) return [];
          const tag = el.tagName.toLowerCase();
          if (SKIP.has(tag)) return [];
          const cs = getComputedStyle(el);
          if (!isRoot && (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0)) return [];
          const kids = [];
          if (!LEAF.has(tag)) {
            const elements = Array.from(el.children);
            const signatures = elements.map(signature);
            const total = {}, seen = {};
            signatures.forEach(s => total[s] = (total[s] || 0) + 1);
            elements.forEach((child, i) => {
              const s = signatures[i];
              seen[s] = (seen[s] || 0) + 1;
              const childPath = uniqueID(child) ? '#' + clean(child.id) : path + '>' + s + (total[s] > 1 ? '[' + seen[s] + ']' : '');
              kids.push(...visit(child, childPath, false));
            });
          }
          const rect = el.getBoundingClientRect();
          const sized = rect.width >= 1 && rect.height >= 1;
          const offscreen = rect.right <= 0 || rect.bottom <= 0 || rect.left >= W || rect.top >= H;
          if (!isRoot && (cs.display === 'contents' || !sized || offscreen)) return kids;
          const text = LEAF.has(tag) ? '' : ownText(el);
          const s = styles(el, cs, !!text);
          const drawn = s.backgroundColor || s.borderColor || s.backdropFilter || cs.boxShadow !== 'none';
          const role = el.getAttribute('role');
          const label = el.getAttribute('aria-label') || el.getAttribute('alt');
          if (!isRoot && !text && !drawn && !el.id && !role && !label && !KEEP.has(tag)) {
            if (kids.length <= 1) return kids;
          }
          emitted++;
          const node = { path, tag, frame: [r1(rect.left), r1(rect.top), r1(rect.width), r1(rect.height)] };
          if (el.id) node.id = el.id;
          const classes = classesOf(el);
          if (classes.length) node.classes = classes.slice(0, 8);
          if (role) node.role = role;
          if (label) node.label = label.slice(0, 140);
          if (text) node.text = text;
          if (Object.keys(s).length) node.styles = s;
          if (kids.length) node.children = kids;
          return [node];
        }
        function variables() {
          const names = new Set();
          const walk = rules => {
            for (const rule of rules) {
              if (rule.style && rule.selectorText && /(^|[\\s,]):root|(^|[\\s,])html\\b/.test(rule.selectorText)) {
                for (const p of rule.style) if (p.startsWith('--')) names.add(p);
              }
              try { if (rule.cssRules) walk(rule.cssRules); } catch (e) {}
            }
          };
          for (const sheet of document.styleSheets) { try { walk(sheet.cssRules); } catch (e) {} }
          for (const p of document.documentElement.style) if (p.startsWith('--')) names.add(p);
          const root = getComputedStyle(document.documentElement);
          const rem = parseFloat(root.fontSize) || 16;
          const probe = document.createElement('div');
          probe.style.display = 'none';
          document.documentElement.appendChild(probe);
          const out = [];
          for (const name of Array.from(names).sort()) {
            const raw = root.getPropertyValue(name).trim();
            if (!raw) continue;
            const v = { name: name.slice(2), raw };
            if (CSS.supports('color', raw)) {
              probe.style.color = '';
              probe.style.color = raw;
              v.color = getComputedStyle(probe).color;
            } else {
              const m = raw.match(/^(-?\\d*\\.?\\d+)(px|rem)?$/);
              if (m) v.number = parseFloat(m[1]) * (m[2] === 'rem' ? rem : 1);
            }
            out.push(v);
          }
          probe.remove();
          return out;
        }
        const body = document.body || document.documentElement;
        const root = visit(body, body.tagName.toLowerCase(), true)[0];
        const bodyBackground = getComputedStyle(body).backgroundColor;
        const background = transparent(bodyBackground) ? getComputedStyle(document.documentElement).backgroundColor : bodyBackground;
        return JSON.stringify({ url: location.href, title: document.title, width: W, height: H, background, root, variables: variables() });
        """
}
