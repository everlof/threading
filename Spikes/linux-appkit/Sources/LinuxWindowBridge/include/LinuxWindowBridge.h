#pragma once
#include <stdint.h>
typedef struct TWWindow TWWindow;
// 1 repaint/resize, 2 project click, 3/4 project navigation, 5 window quit.
// Terminal kinds 15/16/17 carry button (key 0/1/2, action 1 press/3 release), wheel (signed
// key, one notch per unit), and held-left-button motion. Coordinates are window pixels;
// the host maps them to grid cells. Kind 18 requests copying the current local selection.
typedef struct { int kind, x, y, width, height; char text[32]; int key, modifiers, action; } TWEvent;
TWWindow *tw_open(const char *title, int width, int height);
const char *tw_error(void);
int tw_next(TWWindow *, TWEvent *);
int tw_present(TWWindow *, const uint8_t *rgba, int width, int height);
void tw_title(TWWindow *, const char *);
int tw_resize(TWWindow *, int width, int height);
void tw_close(TWWindow *);

// Terminal mode keeps Escape/arrows as input. Timed waits let the UI present coalesced frames.
void tw_terminal_mode(TWWindow *);
// Optional host navigation: kind 8 activates/returns, 9 requests a fresh terminal,
// 10/11 drill in/back, 12 is keyboard cancel, 13 requests a fresh managed agent.
// In terminal mode, kind 14 requests a clipboard paste. The caller reads a bounded UTF-8
// payload only after this event; the bridge never puts unbounded clipboard text in TWEvent.
void tw_project_navigation(TWWindow *, int enabled);
void tw_project_mode(TWWindow *);
int tw_next_timeout(TWWindow *, TWEvent *, int milliseconds);
const char *tw_event_text(const TWEvent *);
// Returns byte count, -1 for content over capacity, -2 for a clipboard error.
int tw_clipboard_read(uint8_t *destination, int capacity);
// Copies at most 1 MiB of UTF-8 to the native clipboard. Returns 0 on success.
int tw_clipboard_write(const uint8_t *source, int length);
typedef struct { int offset, length, width; uint32_t foreground, background; int bold, underline; } TWCell;
// Worker-only Pango/Cairo renderer. Output is RGBA, in fixed 10x22 pixel terminal cells.
int tw_render_terminal(uint8_t *rgba, int width, int height, const TWCell *, int columns, int rows,
                       const char *text, int textLength, int cursorColumn, int cursorRow);

int tw_repaint(TWWindow *);

// Functional keys are semantic events (kind 7), never platform-authored escape sequences.
// action: 1 press, 2 repeat, 3 release. Modifier bits: shift, alt, ctrl, super, caps, num.
enum { TW_KEY_ESCAPE = 1, TW_KEY_ENTER, TW_KEY_TAB, TW_KEY_BACKSPACE, TW_KEY_DELETE,
       TW_KEY_UP, TW_KEY_DOWN, TW_KEY_LEFT, TW_KEY_RIGHT, TW_KEY_HOME, TW_KEY_END,
       TW_KEY_PAGE_UP, TW_KEY_PAGE_DOWN, TW_KEY_F1, TW_KEY_F2, TW_KEY_F3, TW_KEY_F4,
       TW_KEY_F5, TW_KEY_F6, TW_KEY_F7, TW_KEY_F8, TW_KEY_F9, TW_KEY_F10, TW_KEY_F11, TW_KEY_F12 };
