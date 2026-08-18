import AppKit

/// Several toolbar actions carried as **one** toolbar item.
///
/// `NSToolbar` spaces its items for a bordered, labelled toolbar, which is generous next to
/// controls this compact: three icon buttons arrived as three items and read as three unrelated
/// things floating in the title bar rather than as the pane controls they are. A group is the one
/// way to choose that spacing, because the gap between items belongs to the toolbar and the gap
/// inside an item belongs to us.
///
/// It draws nothing itself — the buttons are already `BackdropThemedControl`s and ink themselves.
/// The shared grouping and row-adoption behavior lives in `ControlButtonGroupView`; this type
/// preserves the toolbar's semantic boundary and the toolbar item's existing API.
final class ToolbarButtonGroupView: ControlButtonGroupView {}
