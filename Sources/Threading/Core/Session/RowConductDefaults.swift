import Foundation

enum RowConductDefaults {

    /// The Session Options fold's own mark, so the icon and the menu that sets it read as one
    /// thing rather than as two unrelated pieces of vocabulary.
    static let symbol = "slider.horizontal.3"

    static let sessionIdentifier = "sidebar.session.conduct"
    static let projectIdentifier = "sidebar.project.conduct"

    /// Not localized: it is punctuation between clauses, and the surrounding surfaces already
    /// join their readings with it.
    static let separator = " · "
}
