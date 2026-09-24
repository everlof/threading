#pragma once
#include <stdint.h>
typedef struct TWWindow TWWindow;
// 1 repaint/resize, 2 click, 3 up, 4 down, 5 window quit. Coordinates are window pixels.
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
// 10/11 drill in/back, and 12 is keyboard cancel.
void tw_project_navigation(TWWindow *, int enabled);
void tw_project_mode(TWWindow *);
int tw_next_timeout(TWWindow *, TWEvent *, int milliseconds);
const char *tw_event_text(const TWEvent *);
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
