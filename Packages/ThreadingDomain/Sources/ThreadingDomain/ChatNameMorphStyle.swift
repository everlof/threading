/// The character transition used when the visible name of the active chat changes.
///
/// Raw values mirror LabelMorph's presets, but remain available to hosts without that renderer.
public enum ChatNameMorphStyle: String, CaseIterable, Sendable {
    case automatic
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
}
