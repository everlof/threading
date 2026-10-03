# Linux outline shim fixture

`./run.sh` builds the AppKit shim on Ubuntu and exercises the view-based
`NSOutlineView` inside `NSScrollView`. The source contains 5,100 project roots
and one expanded branch with 1,024 children. It checks first, middle, last,
child and resized viewports, scrolling through the wheel route, stable item
selection across expansion, and an O(visible) cell and reuse-pool bound. It also checks
cached 28/30/32pt per-item heights over the full tree, row gaps, scrolling, hit
testing, expansion, and refreshing changed heights on reload.

This is a focused AppKit subset. Rows have one full-width view. It does not implement
multiple columns, editing, drag and drop, sorting, animated disclosure, native accessibility projection,
or every AppKit delegate notification. The Linux host still owns its AT-SPI
bridge and interaction policy.
