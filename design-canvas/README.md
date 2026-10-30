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
- `App/`: a Mac Catalyst and iOS editor. Screens in light and dark side by side, a
  components area, tap to select any node (inside instances too), and an inspector that
  edits properties or writes overrides.

Not built yet: the Metal canvas, comments, multiplayer sync, the MCP server for coding
agents, and code export. [ARCHITECTURE.md](ARCHITECTURE.md) covers the plan for each.

## Run it

```bash
swift test --package-path design-canvas
```

```bash
cd design-canvas/App && mise x xcodegen@latest -- xcodegen generate && open CanvasEditor.xcodeproj
```

Pick the *My Mac (Mac Catalyst)* or an iPhone simulator destination and run. The project
is generated from [App/project.yml](App/project.yml) and not checked in.

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
