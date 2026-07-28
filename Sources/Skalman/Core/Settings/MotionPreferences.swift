/// Which dotted animation represents an in-flight conversation turn.
///
/// Raw values intentionally match `ThinkingOrbs.OrbState` for the fixed
/// choices, without making the settings model depend on the drawing package.
enum WorkingOrbStyle: String, CaseIterable {
    case random
    case working
    case searching
    case solving
    case listening
    case composing
    case shaping

    var displayName: String {
        switch self {
        case .random: return L10n.string("Random")
        case .working: return L10n.string("Working")
        case .searching: return L10n.string("Searching")
        case .solving: return L10n.string("Solving")
        case .listening: return L10n.string("Listening")
        case .composing: return L10n.string("Composing")
        case .shaping: return L10n.string("Shaping")
        }
    }
}

/// The character transition used when the visible name of the active chat changes.
///
/// Raw values mirror `LabelMorph.MorphPreset`; the adapter at the UI boundary
/// owns the package mapping and the fixed intensity/timing.
enum ChatNameMorphStyle: String, CaseIterable {
    case shapeMorph
    case crossfade
    case slideUp
    case slideDown
    case scale
    case bounce
    case drop
    case flip
    case blur
    case scramble
    case typewriter

    var displayName: String {
        switch self {
        case .shapeMorph: return L10n.string("Shape Morph")
        case .crossfade: return L10n.string("Crossfade")
        case .slideUp: return L10n.string("Slide Up")
        case .slideDown: return L10n.string("Slide Down")
        case .scale: return L10n.string("Scale")
        case .bounce: return L10n.string("Bounce")
        case .drop: return L10n.string("Drop")
        case .flip: return L10n.string("Flip")
        case .blur: return L10n.string("Blur")
        case .scramble: return L10n.string("Scramble")
        case .typewriter: return L10n.string("Typewriter")
        }
    }
}

enum MotionPreferencesDefaults {
    static let workingOrbStyle = WorkingOrbStyle.random
    static let chatNameMorphStyle = ChatNameMorphStyle.shapeMorph
}
