#ifndef SWIFTTERM_POSIX_H
#define SWIFTTERM_POSIX_H

// Darwin's shm_open is variadic; call it through a fixed C signature so its mode
// argument uses the platform's C varargs ABI rather than Swift's calling convention.
int swiftterm_shm_open(const char *name, int flags, unsigned int mode);

#endif
