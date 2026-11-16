# Design canvas architecture

## Invariants

- The document is SwiftUI-shaped. Node kinds map one-to-one to SwiftUI views and props
  to modifiers in a fixed order, so an agent or code export maps a design to SwiftUI
  directly. The canvas doesn't run SwiftUI to draw it. Web screens are the exception: the
  document holds only their address and viewport, and their content is the live page
  (see Web screens).
- The engine draws iOS's look itself. `CanvasEngine` lays out a resolved tree with
  SwiftUI's layout rules (stacks offer space to their least flexible child first,
  spacers take the rest, frames center their content) and draws system components
  (navigation stack, inset grouped list, toggle, button, status bar) from
  `AppleMetrics`. Text is Core Text with SF Pro and iOS's type ramp; symbols are SF
  Symbols drawn as vectors. The same document renders the same on a Mac as on an iPhone.
- Fidelity is measured, not guessed. Colors, type metrics and component metrics come
  from UIKit on the iOS simulator and from native renders of the sample; the fidelity
  tests hold the engine's frames to the native ones within half a point.
- Layout is computed, never stored. The inspector, hit testing, spacing and agents read
  frames from the engine's layout. Only canvas placement (`x`, `y` on page children) is
  stored.
- The canvas is tiles. Items become display lists (plain values), and tiles of 512 px
  at power-of-two levels of pixels per point are drawn from them with Core Graphics on
  worker threads, then composited by Metal. Pan and zoom only move the camera; a tile
  is drawn once per level and content version. A missing tile shows a coarser one
  scaled; a stale one shows until its replacement is ready.
- Every change is an `Edit` with an exact inverse. A failing edit, including one step of
  a batch, leaves the document unchanged, and no edit copies the document.
- `set` changes one property of one node. That is the unit of conflict resolution:
  concurrent edits to different properties never conflict, and the server's order
  decides between edits to the same property.
- Sibling order is a fractional key with ties broken by node ID, so every replica sorts
  children the same way and an insert or move touches only the moved node.
- Instances store only a component reference, their own props and overrides keyed by
  component node ID. Expansion happens at resolve time, so a component edit reaches
  every instance on the next render. Resolved IDs are `instance/node` paths, unique per
  tree; edits inside an instance become overrides on the nearest instance.
- Agents edit through the same history as the designer. Every MCP write is one undo
  step, and a batch that fails part way changes nothing. Agents see the live document,
  never a copy that could drift from the canvas.
- Comments live outside the document in `CommentStore`. They never enter undo history
  or conflict with design edits. A node pin stores the canvas item, the resolved node
  path and an offset from the node's corner, so it follows layout; its page point is
  the fallback when the node stops rendering.
- Pages are `page` nodes under the root, and canvas items are their children. A file
  with items directly under the root, from before pages, is one page, converted when a
  second page is added. A free comment pin records its page; a node pin follows its item.
  The canvas always shows a page that exists: when undo or a reload removes it, the first
  takes over. Preview opens a screen on the page shown, never one from another page.
- The Tokens page is generated (`TokenSet.boards()`): one card per token group, the ID
  up to its last dot, rows of colors, then text styles, then numbers. It is never
  stored, so it can't drift from the tokens.
- An item's origin is the top-left of its content. Titles and pins are overlays, so
  page point = item origin + local point at any zoom.
- A file is the document plus its comments, encoded deterministically: the same
  document always writes the same bytes. The editor writes it atomically about 0.4 s
  after the last change and whenever the app leaves the foreground.
- The file on disk is the source of truth. An external change reloads the editor and
  wins over an edit that hasn't been written yet; the editor ignores its own writes by
  comparing bytes.
- Spacing is computed from frames (`Spacing` in `CanvasCore`), so it includes the
  system's own insets, such as a `List` row's margins. Padding measures to the parent,
  the nearest ancestor with a frame, zero included. A list row isn't a node, so the
  engine reports row frames separately (`LayoutResult.rows`) and a row's content
  measures to its row.
- Stacks offer space like SwiftUI's: views first, least flexible first, and spacers
  share what's left, at least `spacerMinLength` each. A screen without a navigation
  stack lays its content out in the safe area.
- Preview renders the same resolved tree with real SwiftUI (`NativeNodeView`), modifiers
  in the engine's order. It is the reference the engine is held to, never the canvas.
  It always runs on iOS: in the editor on an iPhone or iPad, and in the iOS Simulator
  for the Mac editor, where the same app runs in preview mode and talks to the editor
  over the MCP server's port. The Mac's preview window streams the simulator's
  framebuffer and sends it touches and keys (`SimulatorScreen`, CoreSimulator and
  SimulatorKit); the device's PNG renders are for agents and the fallback. The Mac
  accepts a native render only for the current document revision. Toggles switched in the preview are editor state, applied to the
  resolved tree, never to the document, and cleared by the next edit.
- Only the Metal view sizes the canvas. The overlay hangs off it, so nothing the overlay
  lays out changes the camera's view size.
- The editor caches each item's layout by content key and rebuilds it when the document
  changes. Pan, zoom and hover never resolve or lay out the document.
- A property takes tokens of one kind (`Prop.tokenKind`): colors, numbers or text
  styles, following aliases. A literal where a token of that kind exists is "unbound"
  and flagged in the inspector and to agents; detaching a token writes the literal it
  resolved to.
- Tokens resolve per mode at layout time. Apple semantic colors resolve from
  `AppleColors`, light and dark.

## Web screens

A web screen shows a live page next to the app's other screens, so a team designing a
web app as static HTML, CSS and JS can lay its pages out, inspect them, comment on them
and pull their tokens into the design system.

Data flow:

1. The document stores only the screen: `platform: web`, `url`, optional `lightUrl`, a
   web viewport as `device` (`WebViewport`: Desktop 1440, Laptop 1280, Tablet 768,
   Mobile 390), and `x`/`y`.
2. The editor's `WebScreenRenderer` (App, WebKit) loads each (page, viewport,
   appearance) in an offscreen `WKWebView` the viewport's size, waits for
   `document.fonts.ready` and a 1.2 s settle, then runs `WebPageScript.snapshot` and
   `takeSnapshot`. Dark is the page as it loads; light sets `data-theme="light"` on the
   root element and the view's `prefers-color-scheme` to light, or loads `lightUrl` for
   pages that keep their theme in script state.
3. The result is a `WebSnapshot` (`CanvasCore`): the visible DOM as `WebElement`s with
   frames and computed styles, and the `:root` custom properties. Invisible elements
   are left out and wrapper-only ones collapse into their child, so the tree reads
   like the design.
4. `WebSnapshot.tree` turns it into `ResolvedNode`s of kind `element` under the screen,
   with IDs `<screen>:<element path>`; `frames` gives their frames. From there the
   canvas, hit testing, hover, the layers panel, spacing, comment pins and MCP use the
   same paths as iOS screens. The engine draws the picture as a `DrawOp.image`
   (`LayoutEngine.webScreen`), into tiles like everything else.
5. `WebTokens.importEdit` turns custom properties into `web.` tokens with light and
   dark values, as one `Edit.batch` of `Edit.token`s.

Invariants:

- The DOM is computed, never stored, like layout. The page's code is its source; the
  canvas never edits it. Element nodes refuse edits in the inspector and in MCP.
- An element path is stable across reloads: an `id` when unique in the page, else the
  parent's path, `>`, tag and first class, and an index among siblings with the same
  tag and class. Comments pin to it, so a pin survives a reload and falls back to its
  page point when the element is gone.
- Colors bind to tokens by value: a computed color equal to a token's value in that
  appearance shows as the token, preferring `web.` ones; any other color is a literal,
  flagged like `unbound`. Lengths stay literal, since many tokens share common values.
- iOS-only behaviour stays on iOS screens: web viewports have no status bar, safe areas
  or corner radius, aren't grouped-list backgrounds, don't open in the SwiftUI preview,
  and a web screen's dark copy sits its viewport's width plus 80 points to the right
  (iOS screens keep the fixed 470).
- `Edit.token` sets or removes one token in every mode and returns the previous one,
  so token imports undo exactly; it is the token's unit of conflict, like `set` for a
  property.
- WebKit stays out of `CanvasEngine` and `CanvasCore`: they build on macOS, and
  `canvas-render` draws a web screen as a placeholder with its address.

Not built yet: editing the DOM from the canvas, structured web node kinds (a web
counterpart of the SwiftUI kinds), code export to HTML and CSS, full-page heights for
web screens, and a vector picture of the page.

## Boundaries

`CanvasCore` owns the model, edits, history, token and instance resolution, spacing and
the file store. It has no UI dependency, so the MCP server and the future sync server
link it.
`CanvasEngine` owns layout, iOS's metrics and colors, text and symbol drawing, and the
Core Graphics rasterizer; it runs on macOS too, so `canvas-render` and the tests render
without a simulator. `CanvasMCP` owns JSON-RPC, the tools and a minimal HTTP transport;
it reaches the editor only through the `CanvasHost` protocol, which is what its tests
fake. `CanvasRender` owns the camera, the tile cache and the Metal renderer. The app
owns the canvas, selection, inspector and commands, and renders web screens with
WebKit (`WebScreenRenderer`), handing `CanvasMCP` their snapshots through `CanvasHost`.

## Calibrating

`tools/ios-metrics.swift` prints UIKit's semantic colors and type metrics; build it for
the simulator and run it with `xcrun simctl spawn`. Component metrics come from native
renders: render a sample screen with SwiftUI on the simulator, measure frames and pixels,
and compare with `canvas-render`'s output. A new iOS version means re-running both and
updating `Apple.swift` and the fidelity tests.

## Next steps

1. **Components.** Navigation bar items and inline titles, tab bars, search fields,
   sheets, segmented controls, steppers, sliders and text fields, each calibrated the
   same way. Materials and Liquid Glass as an approximation. Dynamic Type sizes other
   than the default, and iPad size classes.
2. **Canvas, continued.** Marquee selection, snapping and guides, and redrawing only the
   tiles under a node that changed rather than its whole item.
3. **Inspection, continued.** Editing tokens and creating one from a literal, a
   library file shared between documents, Enter and ⇧Enter to move the selection down
   and up the tree, drag to reorder in the layers panel, and redlines between elements
   in different screens.
4. **Comments, continued.** Mentions, drag to re-pin, a resolved filter, and showing
   a pin on every copy of its screen rather than the one it was placed on.
5. **Sync.** Comments sync as a second stream on the same channel. A Phoenix server with
   one process per document: clients send edits, the server assigns order and
   broadcasts, clients rebase pending local edits on top. Postgres keeps the edit log,
   snapshots go to object storage.
6. **MCP, continued.** A headless server over `canvas-render`'s engine, so agents read
   and render a file without the editor open, and a notification when the designer
   adds a comment.
7. **Code export.** Components become `View` structs, overrides become init arguments,
   tokens become a Swift package.

## Pitfalls

- Snapshotting live SwiftUI views into textures, the first renderer, was soft at any
  zoom but 1:1 and slow to update: each edit and each zoom level needed a new
  `drawHierarchy`. The engine draws display lists into tiles instead.
- Core Text objects are thread-safe but not `Sendable`. The engine's font and line
  caches box them in `@unchecked Sendable` classes behind a `Mutex`.
- On macOS, palette colors fill a symbol's cut-outs (the person in
  `person.crop.circle.fill` becomes a disc). The Mac path draws the template and paints
  it with `.sourceIn`.
- Use iOS's line heights and ascenders, not the font's: Core Text on macOS reports
  different metrics for the same SF Pro, which moves every baseline.
- iOS's status bar glyphs are smaller than SF Symbols at the same point size; the
  engine sizes each icon separately to match.
- Under "scaled to match iPad", a Catalyst app draws at 77% and everything is soft. The
  editor uses the Mac idiom, which the engine allows because screens don't depend on
  UIKit's controls.
- sRGB render targets take colors in linear light; convert first.
- The editor doesn't use `DocumentGroup`. Its autosave only fires on `UndoManager`
  changes, which would put comments into undo history. A small file store does the
  saving and watching instead.
- An atomic write replaces the file, so a watch on the old file descriptor stops
  firing. Re-watch after every write and every external rename.
- Files from the document picker on iOS are readable only inside a security scope,
  and the last file is remembered as a bookmark, not a path.
- The MCP server holds its host weakly, because the editor owns the server. A host
  that nothing else retains disappears and every tool answers "not running".
- MCP edit requests use document node IDs, while reads return resolved instance
  paths. `set_property` maps a path back to an override; `apply_edits` doesn't.
- `Document` and `Operation` clash with SwiftUI and Foundation types in app code; the
  model uses `CanvasDocument` and `Edit`.
- `Prop` has a static `title` (the property), so an instance member named `title` on it
  doesn't compile where a `Prop` is expected. The inspector's display name is `label`.
- `onModifierKeysChanged` is unavailable under Mac Catalyst. The Metal view is first
  responder and reads ⌥ from `pressesBegan`/`pressesEnded`, and from the hover
  gesture's modifier flags when another view has focus.
- A double-tap recognizer that the single tap must wait for delays every click. Both
  recognize simultaneously instead: the first tap selects, the second goes deeper.
- A canvas overlay inside the canvas's `ZStack` sized the canvas: a title as wide as a
  zoomed-in screen widened the Metal view, so the camera's view size, its zoom anchor
  and fit all drifted while zooming. The overlay hangs off the Metal view instead.
- SwiftUI in a Mac-idiom Catalyst app draws macOS's controls and type (body at 13 pt, a
  Mac switch), and overriding the hosting controller's idiom trait doesn't change that.
  The Mac editor previews in the iOS Simulator instead.
- A simulated tap with no duration doesn't flip a SwiftUI toggle; the switch needs the
  touch to last a moment, like a finger's.
- `URLSession.shared` answered the preview device's polls from its cache. The device uses
  an ephemeral session without one.
- The Mac preview window showed the simulator's renders as a plain image, and this Mac
  had no Simulator.app, so the toggle couldn't be tapped anywhere.
- A device has several `SimScreen` ports; only the main display's has a framebuffer.
  Frame callbacks fire only while the screen changes, so a still screen sends none.
- Sharing a simulator with other work sends the preview's input to whatever app is in
  front. The launcher prefers one named "Canvas Preview".
- Streaming through the main thread stuttered whenever SwiftUI was busy, and masking the
  layer with `clipShape` re-rendered every frame offscreen. Frames are drawn on the
  simulator's frame queue, at most two in flight, and the layer rounds its own corners.
- The device's PNG renders block its main thread, so rendering after every tap stuttered
  the streamed screen. They wait for 0.6 s without changes.
- `IndigoHIDMessageForMouseNSEvent` already writes both touch payloads UIKit needs, as
  a unit-square point; older code that duplicated the payload by hand isn't needed.
- Measuring each side to the nearest enclosing edge apart from the node's skipped
  parents that share an edge: a name in a VStack measured to the row around the VStack.
  Designers expect the parent, as in Figma, and ⌥ covers other elements.
- Offering a spacer its share like any other view leaves a text next to it half the
  row, so "Good morning" wrapped. SwiftUI sizes views first and gives spacers the rest.
- Showing padding and gaps on all four sides at once buries a small element under
  labels. Each side shows one line: the gap to a neighbour, or the padding when there
  is none, and the name and size badges hide while measuring.

- `WKWebView.createPDF` looked like the way to keep web screens sharp at any zoom, but
  it leaves `<canvas>` drawings out and draws elements with `backdrop-filter` or
  transparency layers as black boxes. Web screens are a bitmap at 2x instead, so they
  soften past 200% zoom.
- WebKit pauses `requestAnimationFrame` for a page it considers hidden, as one in a
  view outside any window is, and pages that draw a `<canvas>` from an animation loop
  then capture blank. The renderer puts its web views in the editor's window, behind
  the content, with `inactiveSchedulingPolicy = .none`.
- Setting `data-theme="light"` isn't enough for every page: one that writes its custom
  properties inline on the root element from script state keeps its dark values, and
  canvases drawn from that state stay dark. `lightUrl` (often the page's own
  `#theme=light`) covers those.
- In mobile content mode, iOS's `WKWebView` lays out a page without a viewport meta
  tag at 980 px, as a phone does. Viewports from 768 up load in desktop mode, so their
  layout width is the viewport's; Mobile 390 keeps mobile mode, like a phone.

## Open questions

- Separators. The native snapshot drew them 1 pt thick, devices draw a hairline; the
  engine draws a hairline (1/3 pt). Worth checking on a device.
- Components outside the sample (bordered buttons, labels, plain lists, scroll views)
  follow SwiftUI's rules but aren't calibrated against native renders yet.
- Custom designs lack gradients, images, line limits and per-edge padding beyond the
  two axes. Gradients and images need new value kinds.
- Preview shows differences the engine doesn't model yet. SwiftUI compresses text when a
  screen runs out of height (Now Playing's title goes to one line and truncates), and
  wraps some lines differently.
- Streaming depends on private simulator APIs, which can change with each Xcode. The
  renders and toggle clicks stay as the fallback. iOS has no scroll wheel, so trackpad
  scrolling is a synthesized drag; a mouse wheel's steps fling less naturally.
- Every edit re-lays out the item it touches and redraws its tiles. Large screens may
  want layout reuse per subtree.
