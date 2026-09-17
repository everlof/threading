// The Linux calls `threading-ptyd` cannot make portably from Swift.
//
// glibc and musl disagree about where `forkpty` is declared and linked, `pidfd_open` has no libc
// wrapper on musl or on older glibc, `pipe2` is hidden behind `_GNU_SOURCE`, which the Swift Glibc
// module is not built with, and `ioctl` is variadic, which Swift cannot call. Each is a
// one-line forward here and nothing more: every decision about what to call and when stays in
// `PTYHostPlatform.swift`. It also carries the build's generation, which Darwin reads from an
// embedded Info.plist a Linux binary does not have. Only the Linux build compiles this; Darwin
// reaches the same calls directly.
#ifndef CPTYHOSTPLATFORM_H
#define CPTYHOSTPLATFORM_H

#include <sys/ioctl.h>
#include <sys/types.h>

/// `forkpty(3)` with no name and no termios, under a window of `size`.
pid_t threading_forkpty(int *master, struct winsize *size);

/// `pipe2(descriptors, O_CLOEXEC)`: both ends close-on-exec atomically. Zero, or -1 with `errno`.
int threading_pipe_cloexec(int descriptors[2]);

/// `ioctl(master, TIOCSWINSZ, size)`. Zero on success, -1 with `errno` otherwise.
int threading_set_window_size(int master, const struct winsize *size);

/// `pidfd_open(pid, 0)` through `syscall(2)`. The descriptor is always close-on-exec.
/// -1 with `errno` (`ENOSYS` before Linux 5.3) otherwise.
int threading_pidfd_open(pid_t pid);

/// `sysconf(_SC_CLK_TCK)`: the unit of `/proc/<pid>/stat` field 22.
long threading_clock_ticks_per_second(void);

/// The three build values a Darwin helper reads from its embedded `Info.plist`, which a Linux
/// binary does not have. Each is the string the build defined with `-Xcc -D<name>="<value>"`
/// (`THREADING_PTYD_SHORT_VERSION`, `THREADING_PTYD_BUNDLE_VERSION`,
/// `THREADING_PTYD_SOURCE_REVISION`), or NULL when the build named none.
const char *threading_build_short_version(void);
const char *threading_build_bundle_version(void);
const char *threading_build_source_revision(void);

#endif
