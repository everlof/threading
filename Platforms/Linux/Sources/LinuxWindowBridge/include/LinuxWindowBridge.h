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
// Kind41 owns an open right-pane session menu: actions 0 motion, 1 down, 2 drag, 3 up,
// 4 outside press/dismiss, 6 Escape, 7 Up, 8 Down, 9 Enter. Pointer coordinates are
// menu-local pixels and never enter the terminal. Kind42 is its header Actions button's
// AT-SPI press. Kind43 is an AT-SPI menu-row press: key is the bounded visible slot and
// text is the exact page identity, which the host must revalidate before executing.
// Kind45 reports native window focus (action=1 gained, 0 lost). A focus loss that also
// cancels an active gesture retains that gesture's event kind; query tw_window_has_focus
// after every event so the host sees both changes in the same turn.
// Editor input is opt-in only while the split workspace shows its right-pane placeholder.
// Kind46 is committed SDL_TEXTINPUT (action=1 following a preedit, otherwise 0).
// Kind47 is uncommitted SDL_TEXTEDITING(_EXT); cursor/selection are Unicode characters.
// Kind48 is an editor key: action=1 press, 2 repeat, 3 release; modifiers use the same
// bits as kind7. key is TW_KEY_* for functional keys or lowercase ASCII for a modified
// letter/digit. Ordinary printable characters arrive only in kind46; non-IME CR/LF/Tab/
// Backspace/Delete text events are dropped because kind48 already carries those keys.
// All three kinds
// are editor-owned and must never be sent to the terminal PTY or sidebar navigation.
// Kind49 announces a queued AT-SPI composer edit; key is its opaque native serial.
// Read it exactly once with tw_accessibility_take_composer_edit. The event carries no text.
// Kind50 presses a mounted composer ChipView: action is 1 project or 2 provider and text is
// the exact composer token. Kind51 presses a mounted choice row: action is the same kind,
// key is its absolute option index and text is its exact host ID. The Swift host validates
// these against the active composer and current options before changing a choice.
typedef struct {
    int kind, x, y, width, height;
    char text[1024];
    int key, modifiers, action, textCursor, textSelectionLength;
} TWEvent;
TWWindow *tw_open(const char *title, int width, int height);
const char *tw_error(void);
int tw_next(TWWindow *, TWEvent *);
int tw_window_has_focus(TWWindow *);
int tw_present(TWWindow *, const uint8_t *rgba, int width, int height);
// Persistent workspace: 320-pixel sidebar, terminal up to 1280 pixels, total up to 1600x900.
// sidebarWidth must be 320 or zero (restore standalone presentation). No child is resized here.
void tw_workspace_mode(TWWindow *, int sidebarWidth, int sidebarFocused);
void tw_workspace_focus(TWWindow *, int sidebarFocused);
// Opt in to SDL text input for an editable right-pane view. Enabling requires split
// placeholder mode and moves focus from the sidebar; disabling leaves pane focus intact.
// A sidebar focus or pane-mode change clears this editor focus. Returns 0 on success,
// -1 when the requested editor is unavailable. No editor input is active by default.
int tw_workspace_editor_focus(TWWindow *, int focused);
int tw_workspace_editor_focused(TWWindow *);
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
// A retained, bounded right-pane overlay is composed after the terminal and header. Its
// origin is right-pane-local; hiding also unmounts its accessibility menu.
int tw_present_session_menu(TWWindow *, const uint8_t *rgba, int width, int height, int x, int y);
void tw_hide_session_menu(TWWindow *);
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
void tw_accessibility_page_actions(TWWindow *, const char *identity, const char *label,
                                   int x, int y, int width, int height);
void tw_accessibility_session_menu_begin(TWWindow *, const char *identity,
                                         int x, int y, int width, int height);
int tw_accessibility_session_menu_add_row(TWWindow *, const char *id, const char *name,
                                          int selected, int enabled,
                                          int x, int y, int width, int height);
void tw_accessibility_session_menu_end(TWWindow *);
// A bounded idle panel with title/detail labels and one optional action button. NULL title
// unmounts it; NULL actionLabel omits the button. Button bounds are window pixels.
void tw_accessibility_placeholder(TWWindow *, const char *title, const char *detail,
                                   const char *actionLabel, int actionEnabled,
                                   int x, int y, int width, int height);
// Publish the mounted composer's editable text to AT-SPI. NULL utf8 unmounts the editor;
// otherwise length is 0...65536 bytes of valid UTF-8, with no embedded NUL. Selection
// bounds are ordered Unicode scalar offsets (not UTF-16 indices); the end is the caret.
// Bounds are window pixels inside the right pane. Invalid updates leave the previous
// projection intact. Text changes emit only the changed span, not the whole draft.
// The native keyboard route performs editing. AT-SPI EditableText mutations are queued
// (at most 16, each at most 64 KiB) for the host and never alter this projection inside an
// accessibility callback. Invalid scalar offsets and full queues are refused on entry.
// identity is a fresh, <=127-byte UTF-8 token for each composer opening; NULL utf8 unmounts.
void tw_accessibility_composer_editor(TWWindow *, const char *identity,
                                      const char *utf8, int length,
                                      int selectionStart, int selectionEnd, int focused,
                                      int x, int y, int width, int height);
// Publish the two mounted production ChipView choices. kind is 1 for project or 2 for
// provider. identity is the current composer-opening token and must match the editor.
// label/value form the accessible name; NULL label unmounts that chip. Bounds are
// window pixels inside the right pane. AT-SPI presses are queued for host validation.
void tw_accessibility_composer_chip(TWWindow *, const char *identity, int kind,
                                    const char *label, const char *value,
                                    int x, int y, int width, int height);
// Publish only the currently visible choice rows (at most six). A NULL identity or
// zero rows unmounts the menu. optionIndex is the absolute choice index; id is its
// exact host identity. AT-SPI actions never mutate the choice directly.
void tw_accessibility_composer_menu_begin(TWWindow *, const char *identity, int kind,
                                          int x, int y, int width, int height);
int tw_accessibility_composer_menu_add_row(TWWindow *, int optionIndex,
                                           const char *id, const char *name,
                                           int selected, int enabled,
                                           int x, int y, int width, int height);
void tw_accessibility_composer_menu_end(TWWindow *);
// Returns a queued edit's UTF-8 byte count (0...65536), or -1 if stale/absent.
// Buffers must hold at least 128 and 65537 bytes respectively. Offsets are Unicode scalars.
// Operations: 1 replace [start,end) with payload; 2 select [start,end);
// 3 copy [start,end); 4 cut [start,end); 5 paste clipboard at start.
// The host must revalidate identity against its active composer before applying an edit.
int tw_accessibility_take_composer_edit(TWWindow *, int serial, int *operation,
                                        int *start, int *end, char *identity,
                                        int identityCapacity, char *utf8, int textCapacity);
// SDL window focus is the source of truth; the bridge focuses the mounted selected row or terminal.
void tw_accessibility_window_focus(TWWindow *, int focused);
// The accessibility projection uses the rendered cell positions, including wide and combined
// graphemes. Each run covers one displayed cell (or a zero-width newline) in Unicode scalars.
typedef struct { int offset, characters, column, row, cells; } TWTextRun;
// Publish only the visible terminal grid. NULL clears text when a terminal starts or fails.
// Content is capped at 64 KiB and at the 128x40 visible-cell grid.
void tw_accessibility_terminal_text(TWWindow *, const char *utf8, int length, int caret,
                                    const TWTextRun *runs, int runCount);
// Candidate windows follow the current terminal or focused editor caret. Coordinates are
// window pixels; calls without an active text-input owner are ignored.
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
