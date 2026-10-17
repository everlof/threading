"""Native GTK drag source used to exercise SDL's desktop file-drop transport."""
from pathlib import Path
import os
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

window = Gtk.Window(title='Threading folder drop source')
window.set_default_size(180, 80)
source = Gtk.EventBox()
source.add(Gtk.Label(label='Drag folder'))
source.drag_source_set(Gdk.ModifierType.BUTTON1_MASK,
                       [Gtk.TargetEntry.new('text/uri-list', 0, 0)], Gdk.DragAction.COPY)
def send_uri(widget, context, selection, info, stamp):
    selection.set_uris([Path(sys.argv[1]).as_uri()])
    print(f'DRAG_DATA {os.getpid()}', flush=True)


source.connect('drag-data-get', send_uri)
source.connect('drag-end', lambda widget, context: print(f'DRAG_END {os.getpid()}', flush=True))
window.add(source)
window.connect('destroy', Gtk.main_quit)
window.show_all()
GLib.idle_add(lambda: print(f'DRAG_READY {os.getpid()}', flush=True))
Gtk.main()
