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
        case .random: return "Random"
        case .working: return "Working"
        case .searching: return "Searching"
        case .solving: return "Solving"
        case .listening: return "Listening"
        case .composing: return "Composing"
        case .shaping: return "Shaping"
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
        case .shapeMorph: return "Shape Morph"
        case .crossfade: return "Crossfade"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .scale: return "Scale"
        case .bounce: return "Bounce"
        case .drop: return "Drop"
        case .flip: return "Flip"
        case .blur: return "Blur"
        case .scramble: return "Scramble"
        case .typewriter: return "Typewriter"
        }
    }
}

enum MotionPreferencesDefaults {
    static let workingOrbStyle = WorkingOrbStyle.random
    static let chatNameMorphStyle = ChatNameMorphStyle.shapeMorph
}
