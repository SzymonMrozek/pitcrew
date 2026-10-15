import SwiftSyntax

extension Inspector {
    func checkAttribute(_ node: AttributeSyntax) {
        let name = node.attributeName.trimmedDescription
        if name == "Injected", !path.contains("Modules/Utilities/DependencyInjection/") {
            emit(.noDirectInjected, node)
        }
        if
            name == "Dependency", let arguments = node.arguments?.as(LabeledExprListSyntax.self),
            arguments.contains(where: { argument in
                argument.label?.text == "resolve"
                    && argument.expression.as(MemberAccessExprSyntax.self)?.base == nil
                    && argument.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "eager"
            }) {
            emit(.noEagerDependency, node)
        }
        if name == "Test", firstTest == nil { firstTest = line(node) }
        if name == "MainActor" { checkMainActor(node) }
    }

    func checkMainActor(_ node: AttributeSyntax) {
        let name = node.attributeName.trimmedDescription
        if
            name == "MainActor", path.hasPrefix("Modules/"), !path.contains("Generated/"),
            let declaration = node.parent?.parent,
            declaration.is(ClassDeclSyntax.self) || declaration.is(StructDeclSyntax.self)
            || declaration.is(EnumDeclSyntax.self) || declaration.is(ActorDeclSyntax.self)
            || declaration.is(FunctionDeclSyntax.self) || declaration.is(VariableDeclSyntax.self)
            || declaration.is(ExtensionDeclSyntax.self) {
            // Preserve the existing rule's exemptions for explicit access/static modifiers.
            let modifiers = declaration.asProtocol(WithModifiersSyntax.self)?.modifiers
            if modifiers?.contains(where: { $0.name.text != "final" }) == true { return }
            let sendable = declaration.as(ClassDeclSyntax.self)
                .map { line($0.classKeyword) > line(node) } == true && declaration.as(ClassDeclSyntax.self)?
                .inheritanceClause?.inheritedTypes.contains {
                    $0.type.tokens(viewMode: .sourceAccurate).contains { $0.text == "Sendable" }
                } == true
            if !sendable, !nearby("lint:allow-main-actor:", line: line(node), above: 1) {
                emit(.redundantMainActor, node)
            }
        }
    }

    func checkVariable(_ node: VariableDeclSyntax) {
        let member = node.parent?.is(MemberBlockItemSyntax.self) == true
        let attributes = node.attributes.compactMap { $0.as(AttributeSyntax.self) }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = identifier.identifier.text
            if binding.typeAnnotation != nil { checkSymbolLabel(identifier.identifier) }
            checkCoordinatorBinding(node, binding: binding)
            if designTokens, let initializer = binding.initializer?.value {
                checkNumericDeclaration(identifier.identifier, value: initializer)
            }
            if
                member, !path.contains("Modules/Utilities/DependencyInjection/"),
                attributes.contains(where: { $0.attributeName.trimmedDescription == "Dependency" }),
                node.modifiers.contains(where: { ["private", "fileprivate"].contains($0.name.text) }),
                let type = ancestor(node, matching: { typeName($0) != nil }).flatMap(typeName) {
                dependencies.append((node, name, type))
            }
            if
                path.hasSuffix(".swift"), node.modifiers.isEmpty,
                attributes.contains(where: { $0.attributeName.trimmedDescription == "Bindable" }),
                let view = ancestor(node, matching: { current in
                    guard let structure = current.as(StructDeclSyntax.self) else { return false }
                    return structure.inheritanceClause?.inheritedTypes
                        .contains { $0.type.tokens(viewMode: .sourceAccurate).contains { $0.text == "View" } } == true
                }) {
                bindables.append((node, name, view.id))
            }
        }
    }

    func checkCoordinatorBinding(_ node: VariableDeclSyntax, binding: PatternBindingSyntax) {
        guard let type = binding.typeAnnotation?.type else { return }
        func coordinator(_ type: TypeSyntax) -> Bool {
            if let value = type.as(SomeOrAnyTypeSyntax.self) { return coordinator(value.constraint) }
            if let value = type.as(OptionalTypeSyntax.self) { return coordinator(value.wrappedType) }
            if let value = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return coordinator(value.wrappedType) }
            return type.as(IdentifierTypeSyntax.self)?.name.text.hasSuffix("Coordinator") == true
        }
        guard coordinator(type) else { return }
        if path.hasPrefix("Modules/"), path.hasSuffix("ViewModel.swift") {
            emit(.noCoordinatorInViewModel, node.bindingSpecifier)
        }
        let prefix = rows[line(node) - 1]
            .prefix(locations.location(for: node.positionAfterSkippingLeadingTrivia).column - 1)
        if
            path.hasPrefix("Modules/"), path.hasSuffix("Interactor.swift"), prefix.allSatisfy(\.isWhitespace),
            node.bindingSpecifier.text == "var" || type.tokens(viewMode: .sourceAccurate)
                .contains(where: { $0.text == "?" }) {
            emit(.interactorCoordinatorOwnership, node)
        }
    }

    func finishProperties() {
        for (node, name, type) in dependencies {
            guard
                let attribute = node.attributes.compactMap({ $0.as(AttributeSyntax.self) })
                    .first(where: { $0.attributeName.trimmedDescription == "Dependency" }) else { continue }
            let first = line(attribute)
            if nearby("lint:allow-member-dependency", line: first) { continue }
            let uses = (references[name] ?? []).filter { $0.type == type && $0.owner != node.id }
            let storage = (references["_" + name] ?? []) + (references["$" + name] ?? [])
            if storage.contains(where: { $0.type == type }) { continue }
            guard
                !uses.isEmpty, uses.allSatisfy({ $0.movable && $0.owner != nil }),
                Set(uses.compactMap(\.owner)).count == 1 else { continue }
            let affected = Set(first ... line(node.endPositionBeforeTrailingTrivia)).union(uses.map(\.line))
            emit(.singleUseDependency, first: first, affected: affected)
        }
        for (node, name, view) in bindables {
            if references["$" + name]?.contains(where: { $0.view == view }) == true { continue }
            guard
                let attribute = node.attributes.compactMap({ $0.as(AttributeSyntax.self) })
                    .first(where: { $0.attributeName.trimmedDescription == "Bindable" }) else { continue }
            let first = line(attribute)
            let uses = (references[name] ?? []).filter { $0.view == view }.map(\.line)
            emit(.unusedBindable, first: first, affected: Set(uses).union([first, line(node.bindingSpecifier)]))
        }
    }
}
