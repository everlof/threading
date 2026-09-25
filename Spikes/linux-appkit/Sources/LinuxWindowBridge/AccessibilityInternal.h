#ifndef THREADING_LINUX_ACCESSIBILITY_INTERNAL_H
#define THREADING_LINUX_ACCESSIBILITY_INTERNAL_H
#include <stdint.h>

void tw_accessibility_open(void);
void tw_accessibility_close(void);
void tw_accessibility_poll(void);
void tw_accessibility_title(const char *title);
uint32_t tw_accessibility_event_type(void);
int tw_accessibility_event_is_current(uint32_t generation);

#endif
