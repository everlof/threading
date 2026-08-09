import Foundation
import ThreadingExtensionKit
import Darwin

@main
struct ThreadingComponentCatalogGenerator {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let check = arguments.contains("--check")
        let positional = arguments.filter { $0 != "--check" }

        guard positional.count == 1 else {
            FileHandle.standardError.write(
                Data("usage: ThreadingComponentCatalogGenerator [--check] OUTPUT_DIRECTORY\n".utf8)
            )
            Darwin.exit(64)
        }

        let outputDirectory = URL(
            fileURLWithPath: positional[0],
            isDirectory: true
        ).standardizedFileURL
        let schemaDirectory = outputDirectory.appendingPathComponent(
            "schemas",
            isDirectory: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        var outputs: [URL: Data] = [
            outputDirectory.appendingPathComponent("component-catalog.json"):
                try encoder.encode(ThreadingComponentCatalog.document),
            outputDirectory.appendingPathComponent("component-catalog.md"):
                Data(ThreadingComponentCatalog.documentationMarkdown().utf8)
        ]

        for description in ThreadingComponentCatalog.document.components {
            let contract = description.entry.contract
            let filename = "\(contract.id.rawValue)-v\(contract.version).schema.json"
            outputs[schemaDirectory.appendingPathComponent(filename)] =
                try encoder.encode(description.patchSchema)
        }

        if check {
            let changed = outputs.keys.sorted { $0.path < $1.path }.filter { url in
                (try? Data(contentsOf: url)) != outputs[url]
            }
            guard changed.isEmpty else {
                for url in changed {
                    FileHandle.standardError.write(
                        Data("generated component catalogue is stale: \(url.path)\n".utf8)
                    )
                }
                Darwin.exit(1)
            }
            print("Component catalogue is up to date.")
            return
        }

        try FileManager.default.createDirectory(
            at: schemaDirectory,
            withIntermediateDirectories: true
        )
        for (url, data) in outputs {
            try data.write(to: url, options: .atomic)
        }
        print("Generated \(outputs.count) component catalogue files in \(outputDirectory.path)")
    }
}
