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
- Tokens resolve per mode at render time. Apple semantic colors stay platform colors,
  so they keep adapting to appearance, contrast and the platform's own palette.

## Boundaries

`CanvasCore` owns the model, edits, history, token and instance resolution. It has no UI
dependency, so the future MCP server and sync server can link it. `CanvasRender` owns the
SwiftUI interpreter, per-screen hosting and frame measurement. The app owns the canvas,
selection, inspector and commands.

## Next steps

1. **Metal canvas.** Composite cached screen textures in a tiled Metal layer with its own
   pan, zoom and trackpad gestures. Keep a live hosted view only for the screen being
   edited; snapshot the others and redraw them when an edit touches their resolved
   tree. Selection, guides, cursors and comment pins draw in an overlay above.
2. **Comments.** Pins anchored to a resolved node path plus an offset, or to a page
   point, kept in their own stream so they never conflict with document edits.
3. **Sync.** A Phoenix server with one process per document: clients send edits, the
   server assigns order and broadcasts, clients rebase pending local edits on top.
   Postgres keeps the edit log, snapshots go to object storage.
4. **MCP server.** Tools to read the tree, inspect a node with measured frames and
   resolved tokens, render a screenshot, list and resolve comments, and write edits.
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
- Canvas items must not size the canvas. Put them in an overlay with `fixedSize()`,
  or the editor toolbar is pushed off screen and rows get the wrong proposed width.
- `Document` and `Operation` clash with SwiftUI and Foundation types in app code; the
  model uses `CanvasDocument` and `Edit`.

## Open questions

- Fidelity on the Mac. The editor runs "scaled to match iPad" and sets the phone idiom
  as a trait override on each screen. This is verified on the iOS simulator only; it
  still needs a side-by-side check against the simulator under Catalyst.
- The large title sits at the screen's left edge instead of the 16 pt margin. Likely
  layout margins from the hosting controller; not investigated yet.
- Every node reports its window frame on every pan and zoom frame. Fine for a prototype;
  the Metal canvas removes it, because pan and zoom stop moving the live views.
