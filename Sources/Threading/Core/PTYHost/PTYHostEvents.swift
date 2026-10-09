import Foundation

struct PTYHostMayHaveDrained: AppEvent {
    static let name = Notification.Name("ptyHostMayHaveDrained")
}
