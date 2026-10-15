import SwiftSyntax

extension Inspector {
    func checkCall(_ node: FunctionCallExprSyntax) {
        checkDesignCall(node)
        let name = callName(node)
        if testStem != nil { constructors.insert(name) }
        checkNestedCall(Syntax(node))
        checkCollectionCall(node)
        checkTaskCall(node)
        if
            name == testStem,
            let test = ancestor(node, matching: { current in
                current.as(FunctionDeclSyntax.self)?.attributes.contains {
                    $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Test"
                } == true
            })?.as(FunctionDeclSyntax.self),
            let attribute = test.attributes.compactMap({ $0.as(AttributeSyntax.self) })
                .first(where: { $0.attributeName.trimmedDescription == "Test" }),
            !nearby("lint:ignore-test-context:", line: line(attribute), above: 2, reason: true) {
            directSetup.append(line(node))
        }
        if currency, name == "currency", node.arguments.first?.label?.text == "code", let point = callPoint(node) {
            emit(
                .sharedCurrencyFormat,
                point,
                through: node.arguments.first?.colon?.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-currency-format:",
                merge: true
            )
        }
    }

    func checkNestedCall(_ node: Syntax) {
        if let opening = nestedCallOpening(node, locations: locations), let (_, closing, _) = parentheses(node) {
            breaks.append(opening.endPositionBeforeTrailingTrivia.utf8Offset)
            emit(.nestedCallArguments, opening, through: closing.endPositionBeforeTrailingTrivia)
        }
    }

    func checkCollectionCall(_ node: FunctionCallExprSyntax) {
        guard path.hasSuffix(".swift") else { return }
        let name = callName(node)
        if
            name == "ForEach", let argument = node.arguments.first,
            let indices = argument.expression.as(MemberAccessExprSyntax.self),
            indices.declName.baseName.text == "indices",
            indices.base?.trimmedDescription != "subviews",
            let identity = node.arguments.first(where: { $0.label?.text == "id" }),
            identity.expression.is(KeyPathExprSyntax.self),
            identity.expression.trimmedDescription.replacingOccurrences(of: " ", with: "").hasPrefix("\\.self") {
            emit(
                .unstableForeachIdentity,
                node.calledExpression,
                through: identity.expression.endPositionBeforeTrailingTrivia
            )
        }
        if
            hasForEach, let collection = ancestor(node, matching: { current in
                guard let call = current.as(FunctionCallExprSyntax.self) else { return false }
                return callName(call) == "ForEach" && call.trailingClosure != nil
            })?.as(FunctionCallExprSyntax.self), let closure = collection.trailingClosure,
            node.position >= closure.position {
            rowCalls.append((name, line(node)))
        }
    }

    func checkTaskCall(_ node: FunctionCallExprSyntax) {
        guard path.hasSuffix(".swift") else { return }
        let name = callName(node)
        if
            name == "Task", node.trailingClosure != nil,
            let appearance = ancestor(node, matching: { current in
                guard let call = current.as(FunctionCallExprSyntax.self) else { return false }
                guard callName(call) == "onAppear", let closure = call.trailingClosure else { return false }
                return node.position >= closure.position && node.endPosition <= closure.endPosition
            })?.as(FunctionCallExprSyntax.self) {
            let first = callPoint(appearance).map(line) ?? line(appearance)
            if !nearby("lint:allow-on-appear-task:", line: first, above: 2, reason: true) {
                emit(.onAppearTask, node, affected: Set(first ... line(node)))
            }
        }
    }

    func checkMember(_ node: MemberAccessExprSyntax) {
        let name = node.declName.baseName.text
        let base = nominalName(node.base)
        if customColorEnabled, ["Color", "UIColor", "NSColor"].contains(base), namedColor(name) {
            emit(
                .designSystemColor,
                node.base?.lastToken(viewMode: .sourceAccurate) ?? node.declName.baseName,
                through: node.declName.baseName.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-custom-color:",
                merge: true
            )
        }
        if
            designTokens, base == "UIFont",
            name.contains("systemFont") || name.contains("SystemFont") || name == "preferredFont" {
            emit(
                .designSystemTypography,
                node.base!.lastToken(viewMode: .sourceAccurate)!,
                through: node.declName.baseName.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-custom-typography:",
                merge: true
            )
        }
        if
            designTokens, [
                "sheet",
                "presentationDetents",
                "presentationDragIndicator",
                "presentationCornerRadius",
                "presentationBackground",
                "presentationSizing",
                "confirmationDialog",
                "actionSheet",
            ].contains(name), let next = node.nextToken(viewMode: .sourceAccurate), next.text == "(" {
            emit(
                .designSystemSheet,
                node.period,
                through: next.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-custom-sheet:",
                merge: true
            )
        }
        if
            currency, name == "Currency", node.base?.trimmedDescription.contains("FormatStyle") == true,
            line(node.period) == node.base.map({ line($0.endPositionBeforeTrailingTrivia) }) {
            emit(.sharedCurrencyFormat, node, exception: "lint:allow-currency-format:", merge: true)
        }
        if
            percentage, name == "Percent", node.base?.trimmedDescription.contains("FormatStyle") == true,
            line(node.period) == node.base.map({ line($0.endPositionBeforeTrailingTrivia) }) {
            emit(.sharedPercentageFormat, node, exception: "lint:allow-percentage-format:", merge: true)
        }
        checkPercentMember(node)
    }

    func checkPercentMember(_ node: MemberAccessExprSyntax) {
        let name = node.declName.baseName.text
        if percentage, name == "percent", node.base == nil {
            var forbidden = false
            if let parent = node.parent?.as(MemberAccessExprSyntax.self) {
                forbidden = [
                    "precision",
                    "locale",
                    "sign",
                    "rounded",
                    "grouping",
                    "notation",
                    "scale",
                    "decimalSeparator",
                ].contains(parent.declName.baseName.text)
            }
            if let argument = node.parent?.as(LabeledExprSyntax.self) {
                forbidden = argument.label?.text == "format"
                    || argument.parent?.parent?.as(FunctionCallExprSyntax.self)
                    .map { callName($0) == "formatted" } == true
            }
            if forbidden {
                var start = node.period
                var end = node.declName.baseName.endPositionBeforeTrailingTrivia
                if let parent = node.parent?.as(MemberAccessExprSyntax.self) {
                    end = parent.declName.baseName.endPositionBeforeTrailingTrivia
                }
                if let argument = node.parent?.as(LabeledExprSyntax.self) {
                    if let label = argument.label {
                        start = label
                    } else if
                        let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
                        let point = callPoint(call) { start = point }
                }
                emit(
                    .sharedPercentageFormat,
                    start,
                    through: end,
                    exception: "lint:allow-percentage-format:",
                    merge: true
                )
            }
        }
    }

    func checkString(_ node: StringLiteralExprSyntax) {
        let segments = Array(node.segments)
        if
            currency, segments.count > 1, let first = segments.first?.as(StringSegmentSyntax.self),
            ["$", "+$", "-$", "−$"].contains(first.content.text), segments[1].is(ExpressionSegmentSyntax.self) {
            emit(.sharedCurrencyFormat, node, exception: "lint:allow-currency-format:", merge: true)
        }
        if percentage {
            for index in segments.indices where index > 0 {
                if
                    let segment = segments[index].as(StringSegmentSyntax.self), segment.content.text.hasPrefix("%"),
                    let interpolation = segments[index - 1].as(ExpressionSegmentSyntax.self) {
                    emit(
                        .sharedPercentageFormat,
                        interpolation.backslash,
                        exception: "lint:allow-percentage-format:",
                        merge: true
                    )
                }
            }
            if
                let argument = node.parent?.as(LabeledExprSyntax.self), argument.label?.text == "format",
                let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self), callName(call) == "String",
                segments.contains(where: { $0.as(StringSegmentSyntax.self)?.content.text.contains("%%") == true }) {
                emit(.sharedPercentageFormat, call, exception: "lint:allow-percentage-format:", merge: true)
            }
        }
        if let sequence = node.parent?.as(SequenceExprSyntax.self) ?? node.parent?.parent?.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            guard
                let index = elements.firstIndex(where: { $0.id == node.id }), segments.count == 1,
                let text = segments.first?.as(StringSegmentSyntax.self)?.content.text else { return }
            if
                currency, ["$", "+$", "-$", "−$"].contains(text), index + 1 < elements.count,
                elements[index + 1].as(BinaryOperatorExprSyntax.self)?.operator.text == "+" {
                emit(.sharedCurrencyFormat, node, exception: "lint:allow-currency-format:", merge: true)
            }
            if
                percentage, text == "%", index > 0,
                let plus = elements[index - 1].as(BinaryOperatorExprSyntax.self), plus.operator.text == "+" {
                emit(
                    .sharedPercentageFormat,
                    plus,
                    through: node.endPositionBeforeTrailingTrivia,
                    exception: "lint:allow-percentage-format:",
                    merge: true
                )
            }
        }
    }

    func checkAssignment(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)
        guard
            elements.count >= 3, let property = elements[0].as(MemberAccessExprSyntax.self),
            property.declName.baseName.text == "numberStyle", elements[1].is(AssignmentExprSyntax.self),
            let value = elements[2].as(MemberAccessExprSyntax.self), value.base == nil else { return }
        if currency, value.declName.baseName.text.hasPrefix("currency") {
            emit(
                .sharedCurrencyFormat,
                property.period,
                through: value.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-currency-format:",
                merge: true
            )
        }
        if percentage, value.declName.baseName.text == "percent" {
            emit(
                .sharedPercentageFormat,
                property.period,
                through: value.endPositionBeforeTrailingTrivia,
                exception: "lint:allow-percentage-format:",
                merge: true
            )
        }
    }
}
