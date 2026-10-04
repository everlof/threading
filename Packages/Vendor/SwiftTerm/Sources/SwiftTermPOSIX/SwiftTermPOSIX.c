#include "SwiftTermPOSIX.h"

#ifndef _WIN32
#include <sys/mman.h>

int swiftterm_shm_open(const char *name, int flags, unsigned int mode) {
    return shm_open(name, flags, (mode_t)mode);
}
#else
int swiftterm_shm_open(const char *name, int flags, unsigned int mode) {
    return -1;
}
#endif
