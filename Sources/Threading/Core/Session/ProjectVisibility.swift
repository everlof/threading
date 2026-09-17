import Foundation

/// Filter before constructing sidebar nodes, so hidden chats incur no row or view work.
enum ProjectVisibility {
    static func visible(_ projects: [Project], showHidden: Bool) -> [Project] {
        showHidden ? projects : projects.filter { !$0.isHidden }
    }
}
