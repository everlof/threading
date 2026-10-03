# Linux outline shim fixture

`./run.sh` builds the AppKit shim on Ubuntu and exercises the view-based
`NSOutlineView` inside `NSScrollView`. The source contains 5,100 project roots
and one expanded branch with 1,024 children. It checks first, middle, last,
child and resized viewports, scrolling through the wheel route, stable item
selection across expansion, and an O(visible) cell and reuse-pool bound.

This is a focused AppKit subset. Rows have one fixed height and one full-width
view. It does not implement variable row heights, multiple columns, editing,
drag and drop, sorting, animated disclosure, native accessibility projection,
or every AppKit delegate notification. The Linux host still owns its AT-SPI
bridge and interaction policy.
