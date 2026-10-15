import Foundation
@testable import RepositoryLint
import Testing

@Test func existingRuleExamples() throws {
    let failures = try checkExamples()
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
}

@Test func designSystemExceptionsStayScoped() {
    var configuration = LintConfiguration()
    configuration.designSystemModulePattern = "^Design(?!Charts$).+"
    #expect(!usesDesignTokens("Modules/UIComponents/DesignTypography/Sources/DesignTypography.swift", configuration: configuration))
    #expect(!usesDesignTokens("Modules/UIComponents/DesignToolbarCloseButton/Sources/Button.swift", configuration: configuration))
    #expect(usesDesignTokens("Modules/UIComponents/DesignCharts/Sources/Chart.swift", configuration: configuration))
    #expect(!usesDesignTokens("Modules/UIComponents/DesignNewControl/Sources/Control.swift", configuration: configuration))
    #expect(usesDesignTokens("Modules/UIComponents/OtherDesignControl/Sources/Control.swift", configuration: configuration))
    #expect(usesDesignTokens("Modules/Scenes/Home/Implementation/Sources/HomeView.swift", configuration: configuration))
}

@Test func taskEarlierInModifierChainIsNotOnAppearWork() {
    let source = """
    Text("Hello")
        .task { Task { await load() } }
        .onAppear { prepare() }
    """
    #expect(!inspect(path: "View.swift", source: source).findings.contains { $0.rule == .onAppearTask })
}

@Test func existingDeclarationExemptionsRemainAvailable() {
    let source = """
    @MainActor
    private func helper() {}
    struct ExampleView: View {
        @Bindable private var model: Model
        var body: some View { Text(model.title) }
    }
    """
    let findings = inspect(path: "Modules/Scenes/Example/Sources/ExampleView.swift", source: source).findings
    #expect(!findings.contains { $0.rule == .redundantMainActor || $0.rule == .unusedBindable })
}

@Test func rawStringsAndNestedCommentsDoNotTriggerRules() {
    let source = ##"""
    let example = #"Image(systemName: "xmark")"#
    /* outer /* Image(systemName: "xmark") */ comment */
    """##
    #expect(inspect(path: "Example.swift", source: source).findings.isEmpty)
}

@Test func declarationLabelsAndDefaultsPreserveLegacyChecks() {
    let source = """
    func layout(spacing: CGFloat = 12, cornerRadius: CGFloat = 6, systemName: String) {}
    var systemImage: String
    """
    let findings = inspect(path: "Modules/Scenes/Example/Sources/ExampleView.swift", source: source).findings
    #expect(findings.filter { $0.rule == .noSfSymbols }.map(\.line) == [1, 2])
    #expect(findings.filter { $0.rule == .designSystemSpacing }.map(\.line) == [1])
    #expect(findings.filter { $0.rule == .designSystemRadius }.map(\.line) == [1])
}

@Test func optionalSelfReferencesCountAsDependencyUses() {
    let source = """
    final class ExampleInteractor {
        @Dependency private var service: Service
        func load() { Task { [weak self] in self?.service.load() } }
    }
    """
    let findings = inspect(path: "ExampleInteractor.swift", source: source).findings
    #expect(findings.filter { $0.rule == .singleUseDependency }.map(\.line) == [2])
}

@Test func legacyExamplesPreserveWhitespaceAndLineFiltering() throws {
    for example in try ruleExamples() {
        let variants = [
            (example.source.replacingOccurrences(of: "\n", with: "\r\n"), 0),
            ("\n" + example.source, 1),
            (
                example.source.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
                    .joined(separator: "\n"),
                0
            ),
        ]
        for (source, shift) in variants {
            let findings = inspect(path: example.path, source: source).findings.filter { $0.rule == example.rule }
            #expect(
                findings.map(\.line).sorted() == example.lines.map { $0 + shift }.sorted(),
                "\(example.rule)/\(example.name)"
            )
            for (first, affected) in zip(example.lines, example.affected ?? []) {
                #expect(
                    findings
                        .contains {
                            $0.line == first + shift && Set(affected.map { $0 + shift }).isSubset(of: $0.affected)
                        },
                    "\(example.rule)/\(example.name): affected lines"
                )
            }
        }
    }
}

@Test func repositoryNamingAndExemptionsAreConfigurable() throws {
    var configuration = LintConfiguration()
    configuration.designSystemPrefix = "Brand"
    configuration.colorFactory = "brand"
    configuration.designSystemModulePattern = "^Brand(?!Chart$).+"
    let source = """
    let color = BrandColor.Text.primary.opacity(0.5)
    let custom = Color.brand(hex: 0xffffff)
    """
    let path = "Modules/Scenes/Example/Sources/View.swift"
    let findings = inspect(path: path, source: source, configuration: configuration).findings
    #expect(findings.filter { $0.rule == .designSystemColor }.map(\.line) == [1, 2])
    #expect(inspect(
        path: "Modules/UIComponents/BrandColor/Sources/Color.swift",
        source: source,
        configuration: configuration
    ).findings.isEmpty)
    #expect(usesDesignTokens("Modules/UIComponents/BrandChart/Sources/Chart.swift", configuration: configuration))
    #expect(Rule.designSystemColor.message(configuration: configuration).contains("BrandColor"))
    #expect(
        try JSONDecoder().decode(LintConfiguration.self, from: JSONEncoder().encode(configuration))
            .designSystemModulePattern == configuration.designSystemModulePattern
    )
}
