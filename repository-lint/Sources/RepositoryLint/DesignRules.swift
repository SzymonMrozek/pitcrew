import SwiftSyntax

extension Inspector {
    func callName(_ node: FunctionCallExprSyntax) -> String {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
    }

    func callPoint(_ node: FunctionCallExprSyntax) -> TokenSyntax? {
        node.calledExpression.as(MemberAccessExprSyntax.self)?.period
    }

    func hasNumber(_ node: some SyntaxProtocol) -> Bool {
        if let number = node.as(IntegerLiteralExprSyntax.self) {
            let value = number.literal.text.replacingOccurrences(of: "_", with: "")
            return value.contains { $0 != "0" }
        }
        if let number = node.as(FloatLiteralExprSyntax.self) {
            return Double(number.literal.text.replacingOccurrences(of: "_", with: "")) != 0
        }
        return node.children(viewMode: .sourceAccurate).contains { hasNumber($0) }
    }

    func numeric(_ rule: Rule, _ node: some SyntaxProtocol, value: some SyntaxProtocol, exception: String) {
        if hasNumber(value) {
            let end = value.as(LabeledExprListSyntax.self)?.parent?.as(FunctionCallExprSyntax.self)?.rightParen?
                .endPositionBeforeTrailingTrivia ?? value.endPositionBeforeTrailingTrivia
            emit(rule, node, through: end, exception: exception, merge: true)
        }
    }

    func checkArgument(_ node: LabeledExprSyntax) {
        guard let label = node.label else { return }
        let name = label.text
        checkSymbolLabel(label)
        guard designTokens else { return }
        if
            [
                "cornerRadius",
                "cornerSize",
                "topLeadingRadius",
                "topTrailingRadius",
                "bottomLeadingRadius",
                "bottomTrailingRadius",
            ].contains(name) {
            numeric(.designSystemRadius, label, value: node.expression, exception: "lint:allow-custom-radius:")
        }
        if ["spacing", "horizontalSpacing", "verticalSpacing"].contains(name) {
            numeric(.designSystemSpacing, label, value: node.expression, exception: "lint:allow-custom-spacing:")
        }
        if ["color", "colors", "tint"].contains(name), customColorEnabled {
            let value = node.expression.as(ArrayExprSyntax.self)?.elements.first?.expression ?? node.expression
            if
                let member = value.as(MemberAccessExprSyntax.self), member.base == nil,
                namedColor(member.declName.baseName.text) {
                emit(.designSystemColor, label, exception: "lint:allow-custom-color:", merge: true)
            } else if
                let call = value.as(FunctionCallExprSyntax.self),
                let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(MemberAccessExprSyntax.self),
                base.base == nil, namedColor(base.declName.baseName.text) {
                emit(.designSystemColor, label, exception: "lint:allow-custom-color:", merge: true)
            }
        }
    }

    func checkSymbolLabel(_ label: TokenSyntax) {
        if
            path.hasSuffix(".swift"), !path.hasPrefix("Modules/Scenes/DevMenu/"),
            label.text == "systemName" || label.text == "systemImage" {
            emit(.noSfSymbols, label)
        }
    }

    func checkNumericDeclaration(_ name: TokenSyntax, value: ExprSyntax) {
        let radii = [
            "cornerRadius",
            "cornerSize",
            "topLeadingRadius",
            "topTrailingRadius",
            "bottomLeadingRadius",
            "bottomTrailingRadius",
        ]
        if radii.contains(name.text) {
            numeric(.designSystemRadius, name, value: value, exception: "lint:allow-custom-radius:")
        }
        if ["spacing", "horizontalSpacing", "verticalSpacing"].contains(name.text) {
            numeric(.designSystemSpacing, name, value: value, exception: "lint:allow-custom-spacing:")
        }
    }

    func namedColor(_ name: String) -> Bool {
        [
            "red",
            "green",
            "blue",
            "black",
            "white",
            "gray",
            "orange",
            "yellow",
            "purple",
            "pink",
            "mint",
            "teal",
            "cyan",
            "indigo",
            "brown",
            "primary",
            "secondary",
            "tertiary",
            "quaternary",
            "accentColor",
            "separator",
        ].contains(name)
            || name.hasPrefix("system") || name.hasSuffix("label") || name.hasSuffix("Label")
    }

    func checkDesignCall(_ node: FunctionCallExprSyntax) {
        guard designTokens else { return }
        checkSheetAndRadiusCall(node)
        checkSpacingCall(node)
        checkTypographyCall(node)
        checkColorCall(node)
    }

    func checkSheetAndRadiusCall(_ node: FunctionCallExprSyntax) {
        let name = callName(node)
        let point = callPoint(node)
        if
            [
                "sheet",
                "presentationDetents",
                "presentationDragIndicator",
                "presentationCornerRadius",
                "presentationBackground",
                "presentationSizing",
                "confirmationDialog",
                "actionSheet",
            ].contains(name), let point {
            emit(
                .designSystemSheet,
                point,
                through: node.leftParen?.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-custom-sheet:",
                merge: true
            )
        }
        if ["cornerRadius"].contains(name), let point {
            numeric(.designSystemRadius, point, value: node.arguments, exception: "lint:allow-custom-radius:")
        }
    }

    func checkSpacingCall(_ node: FunctionCallExprSyntax) {
        let name = callName(node)
        let point = callPoint(node)
        if
            [
                "padding",
                "safeAreaPadding",
                "contentMargins",
                "EdgeInsets",
                "UIEdgeInsets",
                "NSEdgeInsets",
                "NSDirectionalEdgeInsets",
                "UIDirectionalEdgeInsets",
            ].contains(name) {
            if let point {
                numeric(.designSystemSpacing, point, value: node.arguments, exception: "lint:allow-custom-spacing:")
            } else {
                numeric(
                    .designSystemSpacing,
                    node.calledExpression,
                    value: node.arguments,
                    exception: "lint:allow-custom-spacing:"
                )
            }
            if name == "padding" || name == "safeAreaPadding", let point {
                let argument = node.arguments.first?.expression
                let member = argument?.as(MemberAccessExprSyntax.self)
                if
                    node.arguments.isEmpty || (
                        node.arguments.count == 1 &&
                            ((member?.base == nil && member != nil && member?.declName.baseName.text != "zero") ||
                                argument?
                                .is(ArrayExprSyntax.self) == true)
                    ) {
                    emit(.designSystemSpacing, point, exception: "lint:allow-custom-spacing:", merge: true)
                }
            }
        }
    }

    func checkTypographyCall(_ node: FunctionCallExprSyntax) {
        let name = callName(node)
        let point = callPoint(node)
        if ["tracking", "kerning", "lineSpacing", "baselineOffset"].contains(name), let point {
            numeric(.designSystemTypography, point, value: node.arguments, exception: "lint:allow-custom-typography:")
        }
        var typography = ["fontWeight", "fontDesign", "fontWidth", "bold", "italic", "monospaced", "monospacedDigit"]
            .contains(name) && point != nil
        if name == "font", let argument = node.arguments.first?.expression {
            if let member = argument.as(MemberAccessExprSyntax.self) {
                typography = member.base == nil || nominalName(member.base) == "Font"
            } else if
                let call = argument.as(FunctionCallExprSyntax.self),
                let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                typography = member.base == nil || nominalName(member.base) == "Font"
            }
        }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let base = nominalName(member.base)
            typography = typography || (base == "Font" && ["system", "custom"].contains(name))
                ||
                (base == "UIFont" &&
                    (name.contains("systemFont") || name.contains("SystemFont") || name == "preferredFont"))
                || (member.base?.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "font" && [
                    "weight",
                    "width",
                    "bold",
                    "italic",
                    "leading",
                    "monospaced",
                    "monospacedDigit",
                    "smallCaps",
                    "lowercaseSmallCaps",
                    "uppercaseSmallCaps",
                ].contains(name))
        }
        if
            name == "UIFont", let label = node.arguments.first?.label?.text,
            ["name", "descriptor"].contains(label) { typography = true }
        if name == "font", let argument = node.arguments.first?.expression, rootName(argument) == nil {
            func implicit(_ expression: ExprSyntax) -> Bool {
                if let member = expression.as(MemberAccessExprSyntax.self) { return member.base.map(implicit) ?? true }
                if let call = expression.as(FunctionCallExprSyntax.self) { return implicit(call.calledExpression) }
                return false
            }
            typography = typography || implicit(argument)
        }
        if typography {
            // Type constructors report their type token; modifiers report their dot.
            if
                let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                ["Font", "UIFont"].contains(nominalName(member.base)) {
                emit(
                    .designSystemTypography,
                    member.base!.lastToken(viewMode: .sourceAccurate)!,
                    through: member.declName.baseName.endPositionBeforeTrailingTrivia,
                    exception: "lint:allow-custom-typography:",
                    merge: true
                )
            } else if let point {
                let font = node.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(MemberAccessExprSyntax.self)
                emit(
                    .designSystemTypography,
                    font?.declName.baseName.text == "font" ? font!.period : point,
                    through: name == "font" ? node.arguments.first?.positionAfterSkippingLeadingTrivia : node.leftParen?
                        .endPositionBeforeTrailingTrivia,
                    exception: "lint:allow-custom-typography:",
                    merge: true
                )
            } else {
                emit(.designSystemTypography, node, exception: "lint:allow-custom-typography:", merge: true)
            }
        }
    }

    func checkColorCall(_ node: FunctionCallExprSyntax) {
        let name = callName(node)
        let point = callPoint(node)
        guard customColorEnabled else { return }
        var color = false
        if ["Color", "UIColor", "NSColor"].contains(name), let first = node.arguments.first {
            color = first.expression.is(StringLiteralExprSyntax.self)
                || (first.expression.as(MemberAccessExprSyntax.self).map { $0.base == nil } == true)
                || ["red", "white", "hue", "displayP3Red", "named", "hex"].contains(first.label?.text ?? "")
            if
                ["uiColor", "nsColor", "cgColor"].contains(first.label?.text ?? ""),
                first.expression.is(MemberAccessExprSyntax.self) { color = true }
        }
        if name == configuration.colorFactory, ["hex", "light"].contains(node.arguments.first?.label?.text ?? "") { color = true }
        if
            [
                "foregroundStyle",
                "foregroundColor",
                "background",
                "tint",
                "fill",
                "stroke",
                "strokeBorder",
                "border",
                "overlay",
            ].contains(name),
            let argument = node.arguments.first?.expression {
            if
                let member = argument.as(MemberAccessExprSyntax.self),
                member.base == nil { color = namedColor(member.declName.baseName.text) }
            if
                let call = argument.as(FunctionCallExprSyntax.self),
                let member = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(
                    MemberAccessExprSyntax.self
                ),
                member.base == nil {
                color = namedColor(member.declName.baseName.text)
            }
        }
        if color {
            if let point, !["Color", "UIColor", "NSColor"].contains(name) { emit(
                .designSystemColor,
                point,
                exception: "lint:allow-custom-color:",
                merge: true
            ) } else { emit(
                .designSystemColor,
                node.calledExpression,
                through: node.arguments.first?.positionAfterSkippingLeadingTrivia,
                exception: "lint:allow-custom-color:",
                merge: true
            ) }
        }
        if
            name == "opacity", let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            isColorToken(member.base) {
            numeric(.designSystemColor, member.base!, value: node.arguments, exception: "lint:allow-custom-color:")
        }
    }

    func isColorToken(_ expression: ExprSyntax?) -> Bool {
        if nominalName(expression) == configuration.designSystemPrefix + "Color" { return true }
        return expression?.as(MemberAccessExprSyntax.self).map { isColorToken($0.base) } ?? false
    }

    func nominalName(_ expression: ExprSyntax?) -> String {
        if let member = expression?.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return expression?.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
    }

    func rootName(_ expression: ExprSyntax?) -> String? {
        guard let expression else { return nil }
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let member = expression.as(MemberAccessExprSyntax.self) { return rootName(member.base) }
        return nil
    }
}
