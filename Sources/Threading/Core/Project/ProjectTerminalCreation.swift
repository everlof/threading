import Foundation

extension ProjectTerminal {
  init(
    currentDirectory: String,
    id: TerminalID = TerminalID(),
    title: String = "Terminal"
  ) {
    self.id = id
    self.title = title
    self.customTitle = nil
    self.currentDirectory = currentDirectory
    self.branch = GitInfo.currentBranch(for: currentDirectory)
    self.themeID = nil
    self.soundOverrides = nil
    self.createdAt = Date()
  }
}
