# design-canvas

A design canvas for Apple platforms where every screen is real SwiftUI.

Figma draws pictures of an iOS app and leaves code to guess what they meant. Here the
document is a tree of SwiftUI views, tokens and components, so a screen renders with the
framework that ships it, the inspector reads layout SwiftUI actually computed, and an
agent reading the file gets the same structure the code will have.

Status: early prototype. What works today:

- `CanvasCore`: the document model (SwiftUI-shaped nodes, tokens with modes and aliases,
  components with instances and overrides) and edits with exact inverses for undo.
- `CanvasRender`: renders a resolved node tree with real SwiftUI, each screen in its own
  hosting controller with iPhone traits, and reports every node's measured frame.
- `CanvasMCP`: an MCP server for coding agents, embedded in the editor. Agents read the
  live document, the designer's selection, measured frames and native screenshots, and
  write edits the designer can undo.
- `App/`: a Mac Catalyst and iOS editor on a Metal canvas: trackpad pan, pinch and
  ⌘-scroll zoom around the pointer, ⇧1 to fit, sharp at any zoom. Screens in light and
  dark side by side, a components area, tap to select any node (inside instances too),
  an inspector that edits properties or writes overrides, and comments: press C, tap
  anywhere, and the pin sticks to the node under it as layout changes.

Not built yet: multiplayer sync and code export. [ARCHITECTURE.md](ARCHITECTURE.md) covers the plan for each.

## Run it

```bash
swift test --package-path design-canvas
```

```bash
cd design-canvas/App && mise x xcodegen@latest -- xcodegen generate && open CanvasEditor.xcodeproj
```

Pick the *My Mac (Mac Catalyst)* or an iPhone simulator destination and run. The project
is generated from [App/project.yml](App/project.yml) and not checked in.

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
| `inspect_node` | One node with tokens resolved per mode, its frame, ancestors and how edits apply. |
| `get_selection` | The node the designer selected, inspected. ⇧⌘C copies its ID too. |
| `get_tokens` | Every token in every mode. |
| `screenshot` | A PNG drawn from the live SwiftUI render, light or dark. |
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
