#ifndef THREADING_LINUX_ACCESSIBILITY_INTERNAL_H
#define THREADING_LINUX_ACCESSIBILITY_INTERNAL_H
#include <stdint.h>

enum { TW_MAX_NAVIGATION_TRACE_RECORDS = 64 };

void tw_accessibility_open(TWWindow *window);
void tw_accessibility_close(void);
void tw_accessibility_poll(void);
void tw_accessibility_title(const char *title);
uint32_t tw_accessibility_event_type(void);
int tw_accessibility_event_is_current(uint32_t generation);
int tw_accessibility_row_center(int row, int *x, int *y);
int tw_accessibility_row_can_open(int row);
void tw_accessibility_actions_button(TWWindow *, const char *label, int enabled,
                                     int x, int y, int width, int height);
void tw_window_geometry(TWWindow *window, int *x, int *y, int *width, int *height);
int tw_workspace_sidebar_width(TWWindow *window);
int tw_workspace_sidebar_focused(TWWindow *window);
void tw_accessibility_workspace_changed(TWWindow *window);

#endif
