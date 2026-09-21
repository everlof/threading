import ThreadingDomain

// Keep the wire kit's public names source-compatible. These persisted preference values belong
// to the domain so local storage does not need the remote kit's TLS and certificate adapters.
public typealias AccountAppearance = ThreadingDomain.AccountAppearance
public typealias AccountAppearanceSurface = ThreadingDomain.AccountAppearanceSurface
public typealias AccountAppearancePreferences = ThreadingDomain.AccountAppearancePreferences
