#pragma once
#include <stdint.h>
typedef struct TWWindow TWWindow;
// 1 repaint/resize, 2 project click (action=1 for AT-SPI select),
// 3/4 project navigation, 5 window quit.
// Terminal kinds 15/16/17 carry button (key 0/1/2, action 1 press/3 release), wheel (signed
// key, one notch per unit), and held-left-button motion. Coordinates are terminal-local pixels;
// the host maps them to grid cells. Kind 18 requests copying the current local selection.
// Kind 19 is uncommitted IME text. textCursor/textSelectionLength are Unicode character
// positions in that preedit, not bytes. It must never be sent to the PTY. A TEXTINPUT event
// (kind 6) with action=1 is the subsequent commit; ordinary text uses action=0.
// Kind 24 changes workspace focus: action=1 sidebar, action=0 terminal. Pointer presses also
// focus their destination but retain kind 2/15. Sidebar click coordinates remain window pixels.
typedef struct {
    int kind, x, y, width, height;
    char text[1024];
    int key, modifiers, action, textCursor, textSelectionLength;
} TWEvent;
TWWindow *tw_open(const char *title, int width, int height);
const char *tw_error(void);
int tw_next(TWWindow *, TWEvent *);
int tw_present(TWWindow *, const uint8_t *rgba, int width, int height);
// Persistent workspace: 320-pixel sidebar, terminal up to 1280 pixels, total up to 1600x900.
// sidebarWidth must be 320 or zero (restore standalone presentation). No child is resized here.
void tw_workspace_mode(TWWindow *, int sidebarWidth, int sidebarFocused);
void tw_workspace_focus(TWWindow *, int sidebarFocused);
// Explicit runtime activation invalidates the previous terminal image and mouse gesture owner.
// Repaints the retained sidebar over an empty terminal ground; returns 0 on success.
int tw_workspace_reset_terminal(TWWindow *);
// Replace one bounded pane texture, then compose both. The pixels use pane-local coordinates.
int tw_present_pane(TWWindow *, const uint8_t *rgba, int width, int height, int sidebar);
void tw_title(TWWindow *, const char *);
int tw_resize(TWWindow *, int width, int height);
void tw_close(TWWindow *);

// Terminal mode keeps Escape/arrows as input. Timed waits let the UI present coalesced frames.
void tw_terminal_mode(TWWindow *);
// Optional host navigation: kind 8 activates/returns, 9 requests a fresh terminal,
// 10/11 drill in/back, 12 is keyboard cancel, 13 requests fresh Codex,
// 20 chooses a Codex account, 21 requests fresh Claude, 22 chooses a Claude account,
// 23 opens the native project folder picker from the project list.
// In terminal mode, kind 14 requests a clipboard paste. The caller reads a bounded UTF-8
// payload only after this event; the bridge never puts unbounded clipboard text in TWEvent.
void tw_project_navigation(TWWindow *, int enabled);
void tw_project_mode(TWWindow *);
// The diagnostic host publishes only currently mounted rows. A row action re-enters the
// ordinary SDL click/Enter route; accessibility never mutates project or session state.
void tw_accessibility_begin_list(TWWindow *, const char *name, int first, int total, int canOpen,
                                 int x, int y, int width, int height);
int tw_accessibility_add_row(TWWindow *, const char *id, const char *name, int selected,
                             int x, int y, int width, int height);
void tw_accessibility_end_list(TWWindow *);
void tw_accessibility_show_terminal(TWWindow *, const char *name);
// SDL window focus is the source of truth; the bridge focuses the mounted selected row or terminal.
void tw_accessibility_window_focus(TWWindow *, int focused);
// The accessibility projection uses the rendered cell positions, including wide and combined
// graphemes. Each run covers one displayed cell (or a zero-width newline) in Unicode scalars.
typedef struct { int offset, characters, column, row, cells; } TWTextRun;
// Publish only the visible terminal grid. NULL clears text when a terminal starts or fails.
// Content is capped at 64 KiB and at the 128x40 visible-cell grid.
void tw_accessibility_terminal_text(TWWindow *, const char *utf8, int length, int caret,
                                    const TWTextRun *runs, int runCount);
// Candidate windows follow the current terminal cursor. Coordinates are window pixels.
void tw_text_input_rect(TWWindow *, int x, int y, int width, int height);
int tw_next_timeout(TWWindow *, TWEvent *, int milliseconds);
const char *tw_event_text(const TWEvent *);
// Returns byte count, -1 for content over capacity, -2 for a clipboard error.
int tw_clipboard_read(uint8_t *destination, int capacity);
// Copies at most 1 MiB of UTF-8 to the native clipboard. Returns 0 on success.
int tw_clipboard_write(const uint8_t *source, int length);
typedef struct { int offset, length, width; uint32_t foreground, background; int bold, underline; } TWCell;
enum { TW_TERMINAL_CELL_WIDTH = 10, TW_TERMINAL_CELL_HEIGHT = 22 };
// Worker-only Pango/Cairo renderer. Output is RGBA, in fixed-size terminal cells.
int tw_render_terminal(uint8_t *rgba, int width, int height, const TWCell *, int columns, int rows,
                       const char *text, int textLength, int cursorColumn, int cursorRow,
                       const char *preedit, int preeditLength, int preeditCursor, int preeditSelectionLength);
// Navigator text is a bounded, shaped platform leaf for the title and mounted rows. Rectangles
// use window pixels, and each offset/length points into the shared UTF-8 byte buffer. Backgrounds
// and row marks are already present in the opaque RGBA frame; this function draws only text.
typedef struct { int x, y, width, height, inset, offset, length, selected; } TWNavigatorLabel;
int tw_draw_navigator_labels(uint8_t *rgba, int width, int height,
                             const uint8_t *utf8, int byteCount,
                             const TWNavigatorLabel *labels, int labelCount);

// Worker-only fixed-provider PNG decoder: <=64 KiB compressed, <=64x64 pixels. Produces
// top-row-first straight RGBA; rejects oversized/malformed input before pixel allocation.
// Returns 0 on success and -1 on refusal; width/height are written only on success.
int tw_decode_provider_png(const uint8_t *png, int length, uint8_t *rgba, int capacity,
                           int *width, int *height);

int tw_repaint(TWWindow *);

// Functional keys are semantic events (kind 7), never platform-authored escape sequences.
// action: 1 press, 2 repeat, 3 release. Modifier bits: shift, alt, ctrl, super, caps, num.
enum { TW_KEY_ESCAPE = 1, TW_KEY_ENTER, TW_KEY_TAB, TW_KEY_BACKSPACE, TW_KEY_DELETE,
       TW_KEY_UP, TW_KEY_DOWN, TW_KEY_LEFT, TW_KEY_RIGHT, TW_KEY_HOME, TW_KEY_END,
       TW_KEY_PAGE_UP, TW_KEY_PAGE_DOWN, TW_KEY_F1, TW_KEY_F2, TW_KEY_F3, TW_KEY_F4,
       TW_KEY_F5, TW_KEY_F6, TW_KEY_F7, TW_KEY_F8, TW_KEY_F9, TW_KEY_F10, TW_KEY_F11, TW_KEY_F12 };
