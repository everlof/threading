import Foundation
import XCTest
@testable import ThreadingExtensionKit

/// Setting-bound surface inputs: a shader input that reads one of the extension's own settings
/// fields, and the `appliedBy` declaration that lets a render-only extension own settings it
/// never answers requests for.
final class ExtensionSettingBindingContractTests: XCTestCase {

    // MARK: - Fixtures

    private let comets = ExtensionSettingField(
        id: "perimeter-comets",
        title: "Perimeter comets",
        control: .toggle(defaultValue: true),
        appliedBy: .host
    )

    private let density = ExtensionSettingField(
        id: "density",
        title: "Density",
        control: .choice(
            defaultValue: "normal",
            options: [
                .init(id: "sparse", title: "Sparse", value: 0.25),
                .init(id: "normal", title: "Normal", value: 0.5),
                .init(id: "storm", title: "Storm", value: 1)
            ]
        ),
        appliedBy: .host
    )

    private let speed = ExtensionSettingField(
        id: "speed",
        title: "Speed",
        control: .integer(defaultValue: 50, minimum: 0, maximum: 100, step: 5),
        appliedBy: .host
    )

    private let caption = ExtensionSettingField(
        id: "caption",
        title: "Caption",
        control: .text(defaultValue: "", placeholder: nil, maximumLength: 40)
    )

    private var settings: ExtensionSettingsContribution {
        ExtensionSettingsContribution(sections: [
            .init(id: "rain", page: .themes, title: "Rain", fields: [comets, density, speed, caption])
        ])
    }

    private func surface(_ inputs: [ExtensionSurfaceInputBinding]) -> ExtensionMetalSurface {
        ExtensionMetalSurface(
            shaderResource: "Resources/rain.metal",
            preferredFramesPerSecond: 24,
            inputs: inputs
        )
    }

    private func backdrop(_ inputs: [ExtensionSurfaceInputBinding]) -> ExtensionComponentPatch {
        ExtensionComponentPatch(
            id: "rain",
            target: .sidebarBackdrop(),
            hook: .overlay(
                base: .customSurface(.metal(surface(inputs)), accessibilityLabel: nil),
                overlay: .proceed
            )
        )
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Coding

    func testASettingInputRoundTripsAndDefaultsItsMappingToIdentity() throws {
        let mapping = ExtensionScalarMapping(inputMaximum: 100, outputMaximum: 2, curve: .easeIn)
        let scalar = ExtensionSurfaceScalar.setting("speed", mapping: mapping)
        let encoded = try json(scalar)
        XCTAssertEqual(encoded["type"] as? String, "setting")
        XCTAssertEqual(encoded["setting"] as? String, "speed")
        XCTAssertNotNil(encoded["mapping"])
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionSurfaceScalar.self, from: JSONEncoder().encode(scalar)),
            scalar
        )

        let bare = Data(#"{"type":"setting","setting":"perimeter-comets"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionSurfaceScalar.self, from: bare),
            .setting("perimeter-comets", mapping: .identity)
        )
        XCTAssertEqual(scalar.settingID, "speed")
        XCTAssertNil(ExtensionSurfaceScalar.constant(1).settingID)
    }

    func testAppliedByIsAbsentForTheDefaultAndRoundTripsForTheHost() throws {
        let processField = ExtensionSettingField(
            id: "show-status",
            title: "Show status",
            control: .toggle(defaultValue: true)
        )
        XCTAssertNil(try json(processField)["appliedBy"], "a default field encodes as it always did")
        XCTAssertEqual(try json(comets)["appliedBy"] as? String, "host")
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionSettingField.self, from: JSONEncoder().encode(comets)),
            comets
        )

        let legacy = Data(#"{"id":"show-status","title":"Show status","control":{"type":"toggle","defaultValue":true}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionSettingField.self, from: legacy).appliedBy, .process)
    }

    func testAChoiceOptionValueIsOptionalAndRoundTrips() throws {
        let plain = ExtensionSettingOption(id: "normal", title: "Normal")
        XCTAssertNil(try json(plain)["value"])
        let valued = ExtensionSettingOption(id: "storm", title: "Storm", value: 0.75)
        XCTAssertEqual(try json(valued)["value"] as? Double, 0.75)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionSettingOption.self, from: JSONEncoder().encode(valued)),
            valued
        )
    }

    // MARK: - Readings

    func testEachNumericControlReadsTheNumberItsDocumentationPromises() {
        XCTAssertEqual(comets.control.surfaceReading(.bool(true)), 1)
        XCTAssertEqual(comets.control.surfaceReading(.bool(false)), 0)
        XCTAssertEqual(density.control.surfaceReading(.string("sparse")), 0.25)
        XCTAssertEqual(density.control.surfaceReading(.string("storm")), 1)
        XCTAssertEqual(speed.control.surfaceReading(.integer(35)), 35)

        let indexed = ExtensionSettingControl.choice(
            defaultValue: "b",
            options: [.init(id: "a", title: "A"), .init(id: "b", title: "B"), .init(id: "c", title: "C")]
        )
        XCTAssertEqual(indexed.surfaceReading(.string("a")), 0)
        XCTAssertEqual(indexed.surfaceReading(.string("c")), 2)

        XCTAssertNil(caption.control.surfaceReading(.string("hello")), "text has no number")
        XCTAssertNil(speed.control.surfaceReading(.integer(37)), "off-step values are not accepted")
        XCTAssertNil(density.control.surfaceReading(.string("unknown")))
        XCTAssertNil(comets.control.surfaceReading(.integer(1)), "a mismatched kind is no reading")
        XCTAssertTrue(comets.control.isSurfaceReadable)
        XCTAssertFalse(caption.control.isSurfaceReadable)
    }

    func testTheMappingShapesAReadingAndFallsBackWithoutOne() {
        XCTAssertEqual(ExtensionScalarMapping.identity.output(for: 0.4), 0.4)
        XCTAssertEqual(ExtensionScalarMapping.identity.output(for: 35), 1, "identity clamps to 0…1")
        let percent = ExtensionScalarMapping(inputMaximum: 100, fallback: 0.3)
        XCTAssertEqual(percent.output(for: 35), 0.35, accuracy: 1e-9)
        XCTAssertEqual(percent.output(for: nil), 0.3)
        XCTAssertEqual(percent.output(for: .nan), 0.3)
        let eased = ExtensionScalarMapping(curve: .easeIn)
        XCTAssertEqual(eased.output(for: 0.5), 0.25, accuracy: 1e-9)
    }

    func testOnlyProcessAppliedValuesReachAnUpdateRequest() {
        let mixed = ExtensionSettingsContribution(sections: [
            .init(id: "mixed", page: .general, fields: [
                comets,
                .init(id: "refresh", title: "Refresh", control: .toggle(defaultValue: false))
            ])
        ])
        let filtered = mixed.processAppliedValues([
            "perimeter-comets": .bool(false),
            "refresh": .bool(true),
            "undeclared": .bool(true)
        ])
        XCTAssertEqual(Set(filtered.keys), ["refresh", "undeclared"])
    }

    // MARK: - Validation

    func testAHostAppliedTextFieldIsRefusedAtInspection() {
        let invalid = ExtensionSettingsContribution(sections: [
            .init(id: "words", page: .general, fields: [
                .init(
                    id: "caption",
                    title: "Caption",
                    control: .text(defaultValue: "", placeholder: nil, maximumLength: 40),
                    appliedBy: .host
                )
            ])
        ])
        XCTAssertTrue(invalid.validationIssues().contains {
            $0.path.hasSuffix("fields[0].appliedBy")
        })
        XCTAssertTrue(settings.validationIssues().isEmpty, "\(settings.validationIssues())")
    }

    func testChoiceValuesAreAllOrNoneAndFinite() {
        func issues(_ options: [ExtensionSettingOption]) -> [ExtensionValidationIssue] {
            ExtensionSettingValidator.controlIssues(
                .choice(defaultValue: options[0].id, options: options),
                path: "control"
            )
        }
        XCTAssertTrue(issues([.init(id: "a", title: "A"), .init(id: "b", title: "B")]).isEmpty)
        XCTAssertTrue(issues([.init(id: "a", title: "A", value: 2), .init(id: "b", title: "B", value: -1)]).isEmpty)
        XCTAssertTrue(issues([.init(id: "a", title: "A", value: 2), .init(id: "b", title: "B")]).contains {
            $0.path == "control.options" && $0.message.contains("every option or on none")
        })
        XCTAssertTrue(issues([.init(id: "a", title: "A", value: .infinity)]).contains {
            $0.path == "control.options[0].value"
        })
    }

    func testASettingInputNeedsAnIdentifierAndAValidMappingAndStaysWithinEightInputs() {
        XCTAssertTrue(surface([.init(name: "comets", value: .setting("perimeter-comets", mapping: .identity))]).isValid)
        XCTAssertFalse(surface([.init(name: "comets", value: .setting("Not An ID", mapping: .identity))]).isValid)
        XCTAssertFalse(surface([.init(
            name: "comets",
            value: .setting("perimeter-comets", mapping: .init(inputMinimum: 1, inputMaximum: 1))
        )]).isValid)
        let nine = (0..<9).map { ExtensionSurfaceInputBinding(name: "v\($0)", value: .setting("speed", mapping: .identity)) }
        XCTAssertFalse(surface(nine).isValid, "setting inputs share the eight-input budget")
    }

    func testBindingsResolveOnlyAgainstTheExtensionsOwnNumericFields() throws {
        let good = backdrop([
            .init(name: "comets", value: .setting("perimeter-comets", mapping: .identity)),
            .init(name: "density", value: .setting("density", mapping: .identity)),
            .init(name: "speed", value: .setting("speed", mapping: .init(inputMaximum: 100))),
            .init(name: "dark", value: .signal(.themeDark, mapping: .identity))
        ])
        XCTAssertNoThrow(try good.validateSettingBindings(against: settings))
        XCTAssertNoThrow(try ThreadingComponentCatalog.sidebarBackdrop.validate(good))
        XCTAssertEqual(
            good.metalSurfaces.first?.surface.boundSettingIDs,
            ["perimeter-comets", "density", "speed"]
        )

        let unknown = backdrop([.init(name: "x", value: .setting("missing", mapping: .identity))])
        XCTAssertThrowsError(try unknown.validateSettingBindings(against: settings)) { error in
            let issue = (error as? ExtensionValidationError)?.issues.first
            XCTAssertEqual(issue?.path, "hook.base.inputs[0].value.setting")
            XCTAssertTrue(issue?.message.contains("do not declare") == true)
        }
        XCTAssertThrowsError(try unknown.validateSettingBindings(against: .init()))

        let text = backdrop([.init(name: "x", value: .setting("caption", mapping: .identity))])
        XCTAssertThrowsError(try text.validateSettingBindings(against: settings)) { error in
            XCTAssertTrue(
                (error as? ExtensionValidationError)?.issues.first?.message.contains("text field") == true
            )
        }

        let publication = ExtensionComponentPatchPublication(patches: [good, text])
        XCTAssertThrowsError(try publication.validateSettingBindings(against: settings)) { error in
            XCTAssertEqual(
                (error as? ExtensionValidationError)?.issues.map(\.path),
                ["patches[1].hook.base.inputs[0].value.setting"]
            )
        }
    }

    func testSurfacesAreFoundInSlotsStacksAndDisclosures() {
        let bound = ExtensionNode.customSurface(
            .metal(surface([.init(name: "x", value: .setting("missing", mapping: .identity))])),
            accessibilityLabel: nil
        )
        let tree = ExtensionNode.stack(axis: .vertical, spacing: .none, children: [
            .text("a", role: .body),
            .disclosure(id: "d", summary: .text("s", role: .body), detail: [bound])
        ])
        XCTAssertEqual(tree.metalSurfaces().map(\.path), ["node.children[1].detail[0]"])
    }
}
