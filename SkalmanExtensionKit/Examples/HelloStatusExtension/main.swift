import Foundation
import SkalmanExtensionKit

let manifest = ExtensionManifest(
    identifier: "se.mjukis.hello-status",
    name: "Hello Status",
    version: "0.1.0",
    executable: "bin/hello-status",
    capabilities: [.commands, .panels]
)

let registration = ExtensionRegistration(
    commands: [
        ExtensionCommand(
            id: "refresh",
            title: "Refresh status",
            description: "Refresh the example extension's project status."
        )
    ],
    panels: [
        ExtensionPanel(
            id: "status",
            title: "Status",
            root: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .text("Example extension", role: .heading),
                    .status("Ready", role: .positive),
                    .button(
                        id: "refresh",
                        title: "Refresh",
                        role: .standard,
                        isEnabled: true
                    )
                ]
            )
        )
    ]
)

try manifest.validate()
try registration.validate(for: manifest)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let output = try encoder.encode(registration)
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data("\n".utf8))
