"""Tiny Xdnd source for the real SDL file-drop journey."""
from pathlib import Path
import sys

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gdk, Gtk

path = Path(sys.argv[1]).resolve()
window = Gtk.Window(title='Attachment Drag Source')
window.set_default_size(100, 100)
label = Gtk.Label(label='Drag file')
source = Gtk.EventBox()
source.add(label)
window.add(source)
source.drag_source_set(Gdk.ModifierType.BUTTON1_MASK,
                       [Gtk.TargetEntry.new('text/uri-list', 0, 0)], Gdk.DragAction.COPY)
source.connect('drag-begin', lambda *_: print('DRAG_BEGIN', flush=True))
source.connect('drag-end', lambda *_: print('DRAG_END', flush=True))
source.connect('drag-data-get', lambda _widget, _context, selection, _info, _time:
               (print('DRAG_DATA', flush=True), selection.set_uris([path.as_uri()])))
window.connect('destroy', Gtk.main_quit)
window.show_all()
Gtk.main()
