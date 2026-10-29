import Foundation

/// The user-owned Scratchpad's location, seed files and preference key on both desktop hosts.
enum ScratchpadDefaults {
    static let containerName = "Threading"
    static let folderName = "Scratchpad"
    static let readmeName = "README.md"
    static let gitignoreName = ".gitignore"
    static let ignoredEntries = [".DS_Store"]
    static let folderPathKey = "scratchpadFolderPath"

    static var readmeContents: String {
        "# " + L10n.string("Scratchpad") + "\n\n" + L10n.string(
            "Threading created this folder to hold chats that are not about any project. "
                + "It is an ordinary git repository, so nothing you write here is lost — and "
                + "nothing outside it belongs to Threading. You can move it, or point "
                + "Threading somewhere else, in Settings."
        ) + "\n"
    }
}
