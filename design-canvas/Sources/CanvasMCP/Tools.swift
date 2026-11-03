extension CanvasMCPServer {
    static let instructions = """
        design-canvas holds iOS screens as SwiftUI view trees. Node kinds are SwiftUI views \
        (navigationStack, list, section, vstack, hstack, text, image, toggle...) and props are \
        modifiers applied in a fixed order: font, foreground, padding, width/height, background, \
        cornerRadius, opacity. Screens and components sit on one page; list_items shows them.

        IDs: get_tree returns resolved IDs. Nodes inside a component instance use \
        "instance/node" paths and carry `source` (the component node) and `instance`. \
        Values are plain JSON, {"token": "color.accent"} for a design token, or \
        {"color": "#RRGGBB"}. Tokens are the design system: always use one when it fits, and \
        check `unbound` in inspect_node for literals that should be tokens. Reuse components \
        (insert an instance) instead of rebuilding their views.

        Frames come from the canvas's layout engine, which follows SwiftUI's layout rules \
        and iOS 26's system metrics, in screen points from the device's \
        top-left corner. The designer can undo every edit you make. When implementing a \
        screen in code, map kinds and props one-to-one and use the token names.

        Comments are the designer's requests. list_comments shows open threads with the \
        node each is pinned to; after acting on one, resolve_comment with a short reply \
        saying what changed.
        """

    static let tools: [JSON] = [
        tool(
            "list_items",
            "List the screens and components on the canvas with their root node IDs.",
            properties: [:]
        ),
        tool(
            "get_tree",
            "Get the resolved view tree of a screen, a component or any node: kinds, props, token references and measured frames.",
            properties: [
                "node_id": ["type": "string", "description": "A screen or component ID from list_items, or a resolved node ID."],
                "depth": ["type": "integer", "description": "Levels of children to include. Omit for the whole subtree."],
                "appearance": appearanceSchema,
            ],
            required: ["node_id"]
        ),
        tool(
            "inspect_node",
            "Inspect one node like a designer would: props, tokens resolved per mode, literal props that should use a token (unbound, with candidates), "
                + "the component it belongs to and its overrides, measured frame and spacing (per side the distance to the nearest enclosing edge and which node it is, gaps to neighbours, "
                + "from the layout, so system insets count), ancestors and how edits to it apply.",
            properties: [
                "node_id": ["type": "string", "description": "A resolved node ID from get_tree or get_selection."],
                "appearance": appearanceSchema,
            ],
            required: ["node_id"]
        ),
        tool(
            "get_selection",
            "Get the node the designer has selected on the canvas, inspected. Use it when they say \"this\".",
            properties: [:]
        ),
        tool(
            "get_tokens",
            "List the design tokens with their value in every mode.",
            properties: [:]
        ),
        tool(
            "screenshot",
            "Render a screen or component as a PNG, exactly as it appears on the canvas: iOS 26's look drawn with SF Pro and SF Symbols. With renderer native, a screen is rendered by real SwiftUI instead, to compare with the canvas.",
            properties: [
                "screen_id": ["type": "string", "description": "A screen or component ID from list_items."],
                "appearance": appearanceSchema,
                "renderer": ["type": "string", "enum": ["canvas", "native"], "description": "canvas (default) or native SwiftUI."],
            ],
            required: ["screen_id"]
        ),
        tool(
            "set_property",
            "Set or clear one property of a node. On a node inside an instance this writes an override on that instance.",
            properties: [
                "node_id": ["type": "string", "description": "A resolved node ID."],
                "prop": ["type": "string", "description": "Property name, for example text, foreground, padding, spacing."],
                "value": ["description": "A string, number or bool, {\"token\": id}, {\"color\": \"#RRGGBB\"}, or null to clear."],
            ],
            required: ["node_id", "prop"]
        ),
        tool(
            "apply_edits",
            "Apply several edits as one undoable step. Later edits see earlier ones. Uses document node IDs, not instance paths.",
            properties: [
                "edits": [
                    "type": "array",
                    "description": """
                        Each edit has an op: \
                        {"op":"insert","kind":"text","parent":"<id>","index":0,"id":"<optional>","props":{...},"overrides":{...}}, \
                        {"op":"set","node":"<id>","prop":"text","value":...}, \
                        {"op":"override","instance":"<id>","target":"<component node id>","prop":"text","value":...}, \
                        {"op":"move","node":"<id>","parent":"<id>","index":0}, \
                        {"op":"delete","node":"<id>"}. \
                        An instance is {"op":"insert","kind":"instance","props":{"component":"<component id>"}}.
                        """,
                    "items": ["type": "object"],
                ],
            ],
            required: ["edits"]
        ),
        tool(
            "list_comments",
            "List comment threads on the canvas, oldest first, with the node each is pinned to.",
            properties: [
                "include_resolved": ["type": "boolean", "description": "Include resolved threads. Defaults to false."],
            ]
        ),
        tool(
            "add_comment",
            "Start a comment thread pinned to a node or a page point, or reply to a thread.",
            properties: [
                "body": ["type": "string"],
                "thread_id": ["type": "string", "description": "Reply to this thread instead of starting one."],
                "node_id": ["type": "string", "description": "A resolved node ID to pin the new thread to."],
                "appearance": appearanceSchema,
                "x": ["type": "number", "description": "Page x for a thread not pinned to a node."],
                "y": ["type": "number", "description": "Page y for a thread not pinned to a node."],
            ],
            required: ["body"]
        ),
        tool(
            "resolve_comment",
            "Resolve or reopen a thread, optionally replying first.",
            properties: [
                "thread_id": ["type": "string"],
                "resolved": ["type": "boolean", "description": "Defaults to true."],
                "reply": ["type": "string", "description": "A reply to post before resolving."],
            ],
            required: ["thread_id"]
        ),
    ]

    private static let appearanceSchema: JSON = [
        "type": "string", "enum": ["light", "dark"], "description": "Which rendered copy to measure. Defaults to light.",
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: JSON], required: [String] = []) -> JSON {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map(JSON.string)),
            ],
        ]
    }
}
