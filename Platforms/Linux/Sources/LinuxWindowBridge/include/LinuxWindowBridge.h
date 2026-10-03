#pragma once
#include <stdint.h>
typedef struct TWWindow TWWindow;
// 1 repaint/resize, 2 project click (action=1 for AT-SPI select, key=validated visible slot),
// 3/4 project navigation, 5 window quit. For 3/4, action=0 is an arrow key and action=1
// is a sidebar wheel turn; keep those origins distinct when routing through responders.
// Terminal kinds 15/16/17 carry button (key 0/1/2, action 1 press/3 release), wheel (signed
// key, one notch per unit), and held-left-button motion. Coordinates are terminal-local pixels;
// the host maps them to grid cells. Kind 18 requests copying the current local selection.
// Kind 19 is uncommitted IME text. textCursor/textSelectionLength are Unicode character
// positions in that preedit, not bytes. It must never be sent to the PTY. A TEXTINPUT event
// (kind 6) with action=1 is the subsequent commit; ordinary text uses action=0.
// Kind 24 changes workspace focus: action=1 sidebar, action=0 terminal. Pointer presses also
// focus their destination but retain kind 2/15. Sidebar click coordinates remain window pixels.
// Kind25 toggles the Actions picker; action is prior pane (0 terminal,1 sidebar).
// Kind26 redraws the Actions button; action is 0 normal,1 hover,2 pressed.
// Kind27 is opt-in navigator pointer delivery. Coordinates are window pixels; action is
// 0 motion, 1 left down, 2 left drag, 3 left up, 4 leave/cancel, 5 right down.
// Action6 is one motion crossing from the idle pane: cancel idle hover, then deliver the
// navigator motion in the same host turn, before a following click can overtake it.
// A left press begun in the navigator owns drag/up even outside its pane. key is 0 for
// left or 2 for right; terminal-owned gestures never enter this route.
// Kind28 activates a mounted project's inline Actions child through AT-SPI. key is its
// visible row slot and text is its bounded exact project ID; the host validates both.
// Kind29 requests Actions for the selected project on Shift+F10/Menu while the navigator
// is focused. The host resolves that selection itself, so this works without an AT-SPI bus.
// Kind30 opens Add Project's menu from the header's accessible button. The Swift host
// admits each chosen operation through the same command gate as its shortcut.
// Kind33 opens the mounted project's inline `+` choices through AT-SPI. key is its
// visible row slot and text is the exact project ID, revalidated by the Swift host.
// Kind36 toggles the selected project's inline saved-runtime disclosure on Space.
// Kind37 delivers pointer motion/down/drag/up/cancel to the terminal pane's AppKit header.
// Coordinates are terminal-pane-local x and window-local y; action matches kind27.
// Kind38 presses the mounted page title through its production AppKit accessibility action.
// Kind39 delivers idle right-pane pointer motion/down/drag/up/cancel to the placeholder view.
// Coordinates are right-pane-local x and window-local y; action matches kind27.
// Kind40 presses the mounted idle placeholder's action button through AT-SPI or keyboard.
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
// Reserve the top of the workspace's right pane for its AppKit header. Terminal input and
// accessibility geometry use the remaining content rectangle; standalone mode has no inset.
void tw_workspace_terminal_top_inset(TWWindow *, int pixels);
int tw_workspace_terminal_top_inset_value(TWWindow *);
// Explicit idle right-pane state; entering discards retained terminal/header pixels, clears
// terminal accessibility text and input gestures, and keeps the navigator mounted.
void tw_workspace_placeholder_mode(TWWindow *, int enabled);
// Retain the production placeholder's full right-pane bitmap; only valid in placeholder mode.
int tw_present_placeholder(TWWindow *, const uint8_t *rgba, int width, int height);
// Explicit runtime activation invalidates the previous terminal image and mouse gesture owner.
// Repaints the retained sidebar over an empty terminal ground; returns 0 on success.
int tw_workspace_reset_terminal(TWWindow *);
// Replace one bounded pane texture, then compose both. The pixels use pane-local coordinates.
int tw_present_pane(TWWindow *, const uint8_t *rgba, int width, int height, int sidebar);
// The production pane header is a separate retained texture above the terminal grid.
int tw_present_terminal_header(TWWindow *, const uint8_t *rgba, int width, int height);
// App-only header button. Height0 hides; disabled buttons remain visible but cannot activate.
void tw_actions_button(TWWindow *, const char *label, int enabled,
                       int x, int y, int width, int height);
// Frame-level Add project button. Height0 hides it. Pointer input still comes through the
// opt-in navigator view tree; this publishes only its matching accessible action and bounds.
void tw_add_project_button(TWWindow *, int enabled, int x, int y, int width, int height);
// Default-off input route for an AppKit-shim navigator. While enabled, its mounted view tree
// receives raw pointer events instead of the bridge's legacy Actions pointer handling.
// Keyboard/AT-SPI Actions activation and terminal input retain their existing routes.
void tw_navigator_pointer_route(TWWindow *, int enabled);
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
// A mounted project row exposes the production `+` and `⋯` controls in visual order.
// Both 20-point targets lie within the row; all geometry is in window pixels.
int tw_accessibility_add_project_row(TWWindow *, const char *id, const char *name, int selected,
                                     int x, int y, int width, int height,
                                     int createX, int createY, int createWidth, int createHeight,
                                     int actionsX, int actionsY, int actionsWidth, int actionsHeight,
                                     int controlsEnabled);
// Disabled command rows remain selectable, but expose no open action or enabled state.
int tw_accessibility_add_action_row(TWWindow *, const char *id, const char *name, int selected,
                                    int enabled, int x, int y, int width, int height);
void tw_accessibility_end_list(TWWindow *);
void tw_accessibility_show_terminal(TWWindow *, const char *name);
// One mounted title button in the workspace header. The identity invalidates queued presses
// when pages switch; height0 unmounts it. Bounds are window pixels and must fit the header.
void tw_accessibility_page_title(TWWindow *, const char *identity, const char *name,
                                 int x, int y, int width, int height);
// A bounded idle panel with title/detail labels and one optional action button. NULL title
// unmounts it; NULL actionLabel omits the button. Button bounds are window pixels.
void tw_accessibility_placeholder(TWWindow *, const char *title, const char *detail,
                                   const char *actionLabel, int x, int y, int width, int height);
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
// At most three shaped text runs per mounted navigator row, plus title and Actions. The AppKit
// NSTextField shim paints those runs; this bound is the host's visible fragment budget.
enum { TW_NAVIGATOR_MAX_ROWS = 32, TW_NAVIGATOR_MAX_LABELS = TW_NAVIGATOR_MAX_ROWS * 3 + 2 };

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
