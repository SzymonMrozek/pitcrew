import Foundation

public enum Rule: String, CaseIterable, Codable, Sendable {
    case designSystemColor = "design_system_color"
    case designSystemRadius = "design_system_radius"
    case designSystemSheet = "design_system_sheet"
    case designSystemSpacing = "design_system_spacing"
    case designSystemTypography = "design_system_typography"
    case interactorCoordinatorOwnership = "interactor_coordinator_ownership"
    case manualTestDouble = "manual_test_double"
    case noCoordinatorInViewModel = "no_coordinator_in_view_model"
    case noDirectInjected = "no_direct_injected"
    case noDirectInjectedImport = "no_direct_injected_import"
    case noEagerDependency = "no_eager_dependency"
    case noSfSymbols = "no_sf_symbols"
    case nestedCallArguments = "nested_call_arguments"
    case onAppearTask = "on_appear_task"
    case redundantMainActor = "redundant_main_actor"
    case sharedCurrencyFormat = "shared_currency_format"
    case sharedPercentageFormat = "shared_percentage_format"
    case singleUseDependency = "single_use_dependency"
    case testContextSetup = "test_context_setup"
    case unstableForeachIdentity = "unstable_foreach_identity"
    case unusedBindable = "unused_bindable"
    case viewHelperInForeach = "view_helper_in_foreach"

    public var message: String {
        switch self {
        case .designSystemColor:
            "Use DesignColor tokens as defined, without system colors, literals, or opacity tweaks; "
                + "document a required exception with lint:allow-custom-color: reason, or a "
                + "pre-design-system file with lint:allow-custom-color-file: reason."
        case .designSystemRadius:
            "Use DesignRadius tokens for corner radii; document a required exception with "
                + "lint:allow-custom-radius: reason."
        case .designSystemSheet:
            "Present sheets with designSheet, DesignConfirmationSheet, or designSelectionSheet; document a "
                + "required exception with lint:allow-custom-sheet: reason."
        case .designSystemSpacing:
            "Use DesignSpacing tokens for padding, stack spacing, and insets; document a required "
                + "exception with lint:allow-custom-spacing: reason."
        case .designSystemTypography:
            "Use DesignText or DesignTypography.Style fonts, tracking, and line spacing; document a "
                + "required exception with lint:allow-custom-typography: reason."
        case .interactorCoordinatorOwnership:
            "Keep the coordinator as a strong, nonoptional let property in an interactor."
        case .manualTestDouble:
            "Use Spyable/Stubable, or explain the unsupported case immediately above the double."
        case .noCoordinatorInViewModel:
            "Route navigation through the interactor; do not store a coordinator in a view model."
        case .noDirectInjected:
            "Use @Dependency instead of @Injected outside the DependencyInjection module."
        case .noDirectInjectedImport:
            "Import DependencyInjection instead of Injected outside the wrapper module."
        case .noEagerDependency:
            "Use the default lazy @Dependency resolution instead of resolve: .eager."
        case .noSfSymbols:
            "Export the exact Figma asset to DesignAssets and use its public API."
        case .nestedCallArguments:
            "Put outer call arguments on new lines when an argument contains a multiline call."
        case .onAppearTask:
            "Use .task or .task(id:) for view-owned async work; document work that must outlive the "
                + "view."
        case .redundantMainActor:
            "Default MainActor isolation applies; document a required exception with "
                + "lint:allow-main-actor: reason."
        case .sharedCurrencyFormat:
            "Format money with CurrencyFormatting (`.currency(...)`); document a required exception "
                + "with lint:allow-currency-format: reason."
        case .sharedPercentageFormat:
            "Format percentages with PercentageFormatting (`.percentage(...)`); document a required "
                + "exception with lint:allow-percentage-format: reason."
        case .singleUseDependency:
            "This @Dependency is used by only one function; declare it as a local `@Dependency var` "
                + "inside that function instead of a type property, or mark an intentional exception with "
                + "`// lint:allow-member-dependency: reason`."
        case .testContextSetup:
            "Use a TestContext for SUT setup; annotate a justified exception with "
                + "lint:ignore-test-context: reason."
        case .unstableForeachIdentity:
            "Use stable element IDs instead of collection indices in SwiftUI ForEach rows."
        case .unusedBindable:
            "Store this injected model as let; use @Bindable only when the View reads a $model "
                + "binding."
        case .viewHelperInForeach:
            "Extract the row helper into a focused View and construct it directly in ForEach."
        }
    }
}

public func usesDesignTokens(_ path: String, configuration: LintConfiguration = .init()) -> Bool {
    let parts = path.split(separator: "/")
    return path.hasPrefix("Modules/") && path.hasSuffix(".swift")
        && !path.hasPrefix("Modules/Scenes/DevMenu/")
        && !(
            parts.count > 2 && parts[1] == "UIComponents"
                && String(parts[2]).range(of: configuration.designSystemModulePattern, options: .regularExpression) != nil
        )
        && !path.hasSuffix(".tests.swift") && !path.contains("Generated/")
}

public extension Rule {
    func message(configuration: LintConfiguration) -> String {
        message.replacingOccurrences(of: "Design", with: configuration.designSystemPrefix)
            .replacingOccurrences(of: "designSheet", with: configuration.colorFactory + "Sheet")
            .replacingOccurrences(of: "designSelectionSheet", with: configuration.colorFactory + "SelectionSheet")
    }
}
