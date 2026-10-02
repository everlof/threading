import AppKit

/// Only the two visual constants `GeneratedProjectIcon` needs from the production
/// `ProjectIconDefaults` in ProjectIconStore.swift. The diagnostic host does not import the
/// Mac icon store, which also owns filesystem and image-discovery policy. These values match
/// the production 16-point tile and 4-point corner used by ProjectRowView.
enum ProjectIconDefaults {
    static let displayPointSize: CGFloat = 16
    static let displayCornerRadius: CGFloat = 4
}
