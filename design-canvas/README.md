# design-canvas

A design canvas for Apple platforms where every screen is a structured SwiftUI tree,
drawn with iOS's own look.

Figma draws pictures of an iOS app and leaves code to guess what they meant. Here the
document is a tree of SwiftUI views, tokens and components, so an agent reading the file
gets the same structure the code will have. The canvas draws it with its own engine:
SwiftUI's layout rules, iOS 26's type ramp, colors and component metrics, SF Pro and SF
Symbols, matched against native renders to within half a point, and sharp at any zoom.

Status: early prototype. What works today:

- `CanvasCore`: the document model (SwiftUI-shaped nodes, tokens with modes and aliases,
  components with instances and overrides) and edits with exact inverses for undo.
- `CanvasEngine`: lays out a resolved tree like SwiftUI on iOS and draws it: stacks,
  text, symbols, modifiers, the navigation stack's large title, inset grouped lists,
  toggles, buttons and the status bar. Custom designs get flexible frames
  (`maxWidth: infinity`), padding per axis, alignment, fixed font sizes, borders and
  shadows. Runs on macOS too.
- A sample with the stock Settings screen and three custom ones (a reading list, an
  audio player, a welcome screen) on a brand design system of tokens and five
  components.
- `CanvasRender`: the Metal canvas. Map-style tiles drawn from the engine's display
  lists on worker threads, at the resolution the zoom needs.
- `CanvasMCP`: an MCP server for coding agents, embedded in the editor. Agents read the
  live document, the designer's selection, frames, spacing and screenshots, and write
  edits the designer can undo.
- `App/`: a Mac (Catalyst, Mac idiom) and iOS editor: trackpad pan, pinch and ⌘-scroll
  zoom around the pointer (scrolling up zooms in, as in Figma), ⇧1 to fit, vector-sharp
  at any zoom. A theme menu shows screens in light, dark, or both side by side, and a
  screen height menu cuts them at the device's screen or draws them as tall as their
  content. Comments: press C, a pin follows the pointer, tap anywhere, and the pin sticks
  to the node under it as layout changes; Escape leaves the comment tool.
- Pages, as in Figma: a file's items sit on pages (say, app flows and components),
  listed in the layers panel, above its scrolling layer tree, and the toolbar, added with + and renamed by double click.
  A last Tokens page draws every token group as a card, built from the tokens and never
  stored. Comments stay on their page; agents see every page.
- Inspection like Figma's. A click selects the outermost element (a component instance,
  a toggle, a button), a double click goes one level in, ⌘-click goes straight to the
  innermost one; hover shows what a click would pick. The selection shows its component
  and size; hold ⌥, or turn on the ruler, to see its padding and gaps, system insets
  included. Padding measures to the parent, as in Figma, and a list row's content to
  its row; with ⌥, point at another element for the distance to it. The inspector groups properties into content,
  layout, typography and colors, shows each token with what it resolves to (`text.row
  → body → SF Pro 17 pt Regular`), marks literals that should be tokens, and lists an
  instance's overrides with a reset for each.
- Preview (▶, ⌥⌘↩): the selected screen rendered by real SwiftUI on iOS, live as you
  edit, light or dark, alone or beside the canvas's drawing to compare. On the Mac it
  runs in the iOS Simulator and the preview window streams it: click, drag, scroll and
  type into the screen as on a device.
- A layers panel (⌥⌘L) with every screen's and component's view tree, instances
  expanded, sharing selection and hover with the canvas.
- Text and number fields apply as you type; one burst of typing is one undo step.
- A design system panel: components with their instance counts, inserted after the
  selection, and every token, grouped by its ID path (`color.text`), with its light and
  dark values and how often it's used.

Not built yet: multiplayer sync and code export. [ARCHITECTURE.md](ARCHITECTURE.md) covers the plan for each.

## Run it

Render a file's screens to PNGs without the editor, on any Mac:

```bash
swift run --package-path design-canvas canvas-render [file.canvas] out/ 3
```

`canvas-render --sample file.canvas` writes the sample document, to start a file from.

```bash
swift test --package-path design-canvas
```

```bash
cd design-canvas/App && mise x xcodegen@latest -- xcodegen generate && open CanvasEditor.xcodeproj
```

Pick the *My Mac (Mac Catalyst)* or an iPhone simulator destination and run. The project
is generated from [App/project.yml](App/project.yml) and not checked in.

### Preview on the Mac

SwiftUI on the Mac draws macOS's type and controls, so the Mac editor previews on the
iOS Simulator, like Xcode's previews. Give the preview a simulator of its own, since it
takes over the screen, and install the app there once (run the iPhone destination):

```bash
xcrun simctl create "Canvas Preview" "iPhone 18 Pro" && xcrun simctl boot "Canvas Preview"
```

Preview then relaunches the app there in preview mode, showing the selected screen, and
the preview window streams the simulator's screen: clicks and drags are touches,
trackpad scrolling drags the content, and keys type into it. Simulator.app isn't needed.
Streaming uses CoreSimulator and SimulatorKit, Xcode's private frameworks; when they
aren't there, the window shows the device's renders instead, and a click on a toggle
still switches it. To start the device by hand (a UDID instead of `booted` when several
simulators run):

```bash
xcrun simctl launch --terminate-running-process booted dev.pitcrew.canvas-editor -previewHost YES -previewPort 7341
```

The simulator polls the editor on `127.0.0.1` (`/preview/state` and `/preview/file`, next
to `/mcp`), shows the screen as its root view, and posts a render of every screen in
both appearances back after each change, for agents and the fallback. Switched toggles
live in the editor (`/preview/toggle`) until the next edit, so the canvas's Compare and
agents see them too.

## Files

The editor autosaves to one `.canvas` file, a JSON document with sorted keys, so it
can sit in your app's repository and diff cleanly in review. It reloads when the file
changes on disk, for example after `git pull` or when an agent edits the JSON.

```bash
CANVAS_FILE=~/Projects/MyApp/Design/App.canvas open "Canvas Editor.app"
```

Without `CANVAS_FILE` it reopens the last file, or starts `Untitled.canvas` in
Documents from the sample. ⌘O opens another file and ⇧⌘S saves a copy and switches
to it. Undo history isn't saved.

## Coding agents

The editor serves MCP over Streamable HTTP on `127.0.0.1:7341` while it runs (the
toolbar shows the status; `CANVAS_MCP_PORT` changes the port). Register it once:

```bash
claude mcp add --transport http design-canvas http://127.0.0.1:7341/mcp
```

| Tool | What it returns or does |
| --- | --- |
| `list_items` | Screens and components on the canvas. |
| `get_tree` | The resolved view tree: kinds, props, token references, measured frames. |
| `inspect_node` | One node with tokens resolved per mode, literals that should be tokens, its component and overrides, measured frame and spacing, ancestors and how edits apply. |
| `get_selection` | The node the designer selected, inspected. ⇧⌘C copies its ID too. |
| `get_tokens` | Every token in every mode, with its kind (color, number, text style). |
| `screenshot` | A PNG of a screen or component as the canvas draws it, light or dark. `renderer: native` returns the screen as SwiftUI renders it on iOS, from the preview. |
| `set_property` | Sets one prop; inside an instance it writes an override. |
| `apply_edits` | Inserts, sets, overrides, moves and deletes as one undo step. |
| `list_comments` | Open threads with the node each is pinned to. |
| `add_comment` | Starts a thread on a node or page point, or replies. |
| `resolve_comment` | Resolves or reopens a thread, optionally replying first. |

Comments work as a task list: a designer pins "make this semibold" on a row, the agent
reads it with `list_comments`, edits the node and resolves the thread with a reply.
Agent comments are signed with the client's name from `initialize` and show as purple
pins.

The server listens on loopback only and rejects requests with a non-local `Origin`.

## The document

A document is a flat map of nodes plus a token set. Each node has a kind, a parent, a
fractional order key, a property bag and, on instances, overrides:

```json
{
  "id": "settings.wifi",
  "kind": "instance",
  "parent": "settings.general",
  "order": "V",
  "props": { "component": { "string": "component.settingRow" } },
  "overrides": {
    "settingRow.title": { "text": { "string": "Wi-Fi" } },
    "settingRow.icon.symbol": { "symbol": { "string": "wifi" } }
  }
}
```

Values are `string`, `number`, `bool`, `color` (`#RRGGBB[AA]`) or `token`. Tokens hold a
value per mode (`light`, `dark`, ...): a hex color, an Apple semantic color such as
`label` or `systemBlue`, a number, a Dynamic Type text style, or an alias to another token.

Every change is an `Edit`: `insert`, `delete`, `set`, `move`, `override` or `batch`.
`CanvasDocument.apply` returns the inverse, which is what undo replays and what a sync
server will order.
