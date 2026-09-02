import ThreadingDomain

/// Names the design system uses unqualified, supplied without editing the shared sources.
///
/// The application declares these beside its own models; the kit takes them from the package that
/// already owns the rule. A module-scope alias is what lets a symlinked file keep saying
/// `StoredPathComponent` without an import line the application does not need.
typealias StoredPathComponent = ThreadingDomain.StoredPathComponent
