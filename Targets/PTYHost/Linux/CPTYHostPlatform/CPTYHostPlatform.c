// Linux only. Darwin reaches every one of these directly, and has no <pty.h> to include.
#ifdef __linux__

#define _GNU_SOURCE
#include "CPTYHostPlatform.h"

#include <fcntl.h>
#include <pty.h>
#include <sys/syscall.h>
#include <unistd.h>

// Linux gives every architecture the same number for the new unified syscalls. Stated for a libc
// whose headers predate the call; the kernel still answers ENOSYS when it is too old.
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

pid_t threading_forkpty(int *master, struct winsize *size) {
    return forkpty(master, NULL, NULL, size);
}

int threading_pipe_cloexec(int descriptors[2]) {
    return pipe2(descriptors, O_CLOEXEC);
}

int threading_set_window_size(int master, const struct winsize *size) {
    return ioctl(master, TIOCSWINSZ, size);
}

int threading_pidfd_open(pid_t pid) {
    return (int)syscall(SYS_pidfd_open, pid, 0);
}

long threading_clock_ticks_per_second(void) {
    return sysconf(_SC_CLK_TCK);
}

#endif
