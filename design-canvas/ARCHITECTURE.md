# Design canvas architecture

## Invariants

- The document is SwiftUI-shaped. Node kinds map one-to-one to SwiftUI views and props
  to modifiers in a fixed order. Rendering, inspection and code export all read the same
  tree; nothing reimplements SwiftUI layout.
- Layout comes from rendering. The inspector, hit testing and agents read frames
  measured from the rendered views, never frames stored in the document. Only canvas
  placement (`x`, `y` on page children) is stored.
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
- An item's origin is the top-left of its rendered content. Titles and pins are
  overlays, so page point = item origin + measured local point at any zoom.
- The canvas never transforms live views. Every item renders with real SwiftUI at 1:1
  behind an opaque Metal view; Metal draws texture snapshots of them. Pan and zoom only
  move the camera, so they cost one Metal frame and no SwiftUI layout. A snapshot is
  retaken when an item's resolved tree, tokens or appearance change, or when the zoom
  needs a sharper texture level.
- A file is the document plus its comments, encoded deterministically: the same
  document always writes the same bytes. The editor writes it atomically about 0.4 s
  after the last change and whenever the app leaves the foreground.
- The file on disk is the source of truth. An external change reloads the editor and
  wins over an edit that hasn't been written yet; the editor ignores its own writes by
  comparing bytes.
- Tokens resolve per mode at render time. Apple semantic colors stay platform colors,
  so they keep adapting to appearance, contrast and the platform's own palette.

## Boundaries

`CanvasCore` owns the model, edits, history, token and instance resolution. It has no UI
dependency, so the MCP server and the future sync server link it. `CanvasMCP` owns
JSON-RPC, the tools and a minimal HTTP transport; it reaches the editor only through
the `CanvasHost` protocol, which is what its tests fake. `CanvasRender` owns the
SwiftUI interpreter, per-screen hosting, frame measurement, the camera and the Metal
renderer. The app owns the canvas,
selection, inspector and commands.

## Next steps

1. **Canvas, continued.** A texture array with instanced drawing for hundreds of
   screens, snapshotting only the dirty region of a screen, unloading renderers for
   screens far off screen, marquee selection, snapping and guides.
2. **Comments, continued.** Mentions, drag to re-pin, a resolved filter, and showing
   a pin on every copy of its screen rather than the one it was placed on.
3. **Sync.** Comments sync as a second stream on the same channel. A Phoenix server with
   one process per document: clients send edits, the server assigns order and
   broadcasts, clients rebase pending local edits on top. Postgres keeps the edit log,
   snapshots go to object storage.
4. **MCP, continued.** A headless mode that renders a document file without the editor
   open, and a notification when the designer adds a comment.
5. **Code export.** Components become `View` structs, overrides become init arguments,
   tokens become a Swift package.

## Pitfalls

- A `NavigationStack` in the editor captures every rendered screen's `NavigationStack`:
  their titles land in the editor's bar. The editor has no navigation container, and
  each screen gets its own `UIHostingController`.
- Any modifier on a `Section` turns it into one plain row inside `List`. Sections render
  bare; their rows and header are measured instead.
- Named coordinate spaces don't resolve inside `List` rows, which are UIKit-hosted
  cells. Nodes report window coordinates and the registry converts them with the screen's
  device frame, which also undoes canvas pan and zoom.
- Measure the device frame outside the hosting controller. Inside it, the root's frame
  is already inset by the safe area, which shifts every hit test by the status bar.
- SwiftUI environment size classes are not enough for UIKit-backed views. Set trait
  overrides and `overrideUserInterfaceStyle` on the hosting controller too.
- Never scale a hosted screen. Under a scale transform the navigation bar's large
  title lost its 16 pt margin and every node re-reported its frame on each pan frame.
- `drawHierarchy` only draws views that are in a window and not hidden. The renderers
  stay visible, covered by the opaque Metal view, instead of being hidden.
- Reassigning a hosting controller's `rootView` re-renders the whole screen. Compare
  first; SwiftUI calls `updateUIViewController` far more often than content changes.
- sRGB render targets take clear colors in linear light; convert UIKit colors first.
- The editor doesn't use `DocumentGroup`. Its autosave only fires on `UndoManager`
  changes, which would put comments into undo history. A small file store does the
  saving and watching instead.
- An atomic write replaces the file, so a watch on the old file descriptor stops
  firing. Re-watch after every write and every external rename.
- Files from the document picker on iOS are readable only inside a security scope,
  and the last file is remembered as a bookmark, not a path.
- Canvas items must not size the canvas. Put them in an overlay with `fixedSize()`,
  or the editor toolbar is pushed off screen and rows get the wrong proposed width.
- `ImageRenderer` draws placeholders for UIKit-backed views such as `List` and
  `NavigationStack`. Screenshots draw the live hosting view with `drawHierarchy`;
  only components, which are plain SwiftUI, use `ImageRenderer`.
- The MCP server holds its host weakly, because the editor owns the server. A host
  that nothing else retains disappears and every tool answers "not running".
- MCP edit requests use document node IDs, while reads return resolved instance
  paths. `set_property` maps a path back to an override; `apply_edits` doesn't.
- `Document` and `Operation` clash with SwiftUI and Foundation types in app code; the
  model uses `CanvasDocument` and `Edit`.

## Open questions

- Fidelity on the Mac. The editor runs "scaled to match iPad" and sets the phone idiom
  as a trait override on each screen. This is verified on the iOS simulator only; it
  still needs a side-by-side check against the simulator under Catalyst.
- Measured frames of deleted nodes stay in the registry until the screen re-renders
  them away. Lookups go through resolved IDs, so they are never returned, but the
  registry should prune on resolve.
- Texture levels stop at 4 px per point: a 402×874 screen is ~22 MB with mipmaps at that
  level. Deep zoom on a large file needs tiles instead of whole-screen textures.
