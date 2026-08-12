import Foundation

// MARK: - Code Stats

/// What a project's code is made of, as counted by `scc`.
///
/// One record per language, in scc's own vocabulary — code, comment and blank lines are
/// counted apart, so "how big is this" can be answered with the number that means it
/// (`code`) rather than the one that flatters it (`lines`).
struct CodeStats: Codable, Equatable, Sendable {

    /// One language's share of the project.
    struct Language: Codable, Equatable, Sendable {
        let name: String
        let files: Int
        let code: Int
        let comments: Int
        let blanks: Int
        let complexity: Int
        let bytes: Int

        var lines: Int { code + comments + blanks }
    }

    /// Sorted by code lines, largest first, so every consumer agrees on what "the top
    /// language" is without re-sorting.
    let languages: [Language]

    var totalCode: Int { languages.reduce(0) { $0 + $1.code } }
    var totalFiles: Int { languages.reduce(0) { $0 + $1.files } }
    var totalLines: Int { languages.reduce(0) { $0 + $1.lines } }

    var isEmpty: Bool { languages.isEmpty }
}

// MARK: - Parsing

extension CodeStats {

    /// scc's `--format json` element, keys as scc spells them.
    private struct SCCLanguage: Decodable {
        let Name: String
        let Count: Int
        let Code: Int
        let Comment: Int
        let Blank: Int
        let Complexity: Int
        let Bytes: Int
    }

    /// Reads scc's `--format json` output — a bare array of language summaries.
    ///
    /// An empty folder is `[]`, which parses to an empty reading rather than an error:
    /// "nothing here" is an answer, not a failure.
    static func parse(sccJSON data: Data) throws -> CodeStats {
        let decoded = try JSONDecoder().decode([SCCLanguage].self, from: data)

        let languages = decoded
            .map {
                Language(
                    name: $0.Name,
                    files: $0.Count,
                    code: $0.Code,
                    comments: $0.Comment,
                    blanks: $0.Blank,
                    complexity: $0.Complexity,
                    bytes: $0.Bytes
                )
            }
            .sorted { $0.code != $1.code ? $0.code > $1.code : $0.name < $1.name }

        return CodeStats(languages: languages)
    }
}
