"""Keyboard access to the existing project catalogs through the production Actions menu."""


def open_saved_agents(key):
    _open_catalog(key, 7)


def open_saved_terminals(key):
    _open_catalog(key, 8)


def _open_catalog(key, row):
    # The project menu has a fixed host-command order: Saved agents/terminals are its last
    # two commands. Use the same visible menu as a user, not the outline's Left/Right keys.
    for stroke in ['Shift+F10'] + ['Down'] * row + ['Return']:
        result = key(stroke)
        assert getattr(result, 'returncode', 0) == 0, ('catalog menu key failed', stroke, result)


def selected_outline_row(process_id, identity):
    """Find a real selected runtime row in the ordinary, viewport-bounded AT-SPI tree."""
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
    Atspi.init()
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() != process_id or app.get_name() != 'Threading Linux':
            continue
        frame = app.get_child_at_index(0)
        for child in range(frame.get_child_count()):
            listed = frame.get_child_at_index(child)
            if listed.get_role_name() != 'list' or listed.get_name() != 'Projects':
                continue
            assert listed.get_child_count() <= 32, 'navigator exceeded TW_NAVIGATOR_MAX_ROWS'
            for row_index in range(listed.get_child_count()):
                row = listed.get_child_at_index(row_index)
                if row.get_accessible_id() == identity and row.get_state_set().contains(Atspi.StateType.SELECTED):
                    return row
    return None
