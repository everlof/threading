#define _GNU_SOURCE
#include "CNativeAgentProcess.h"
#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <pthread.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

int threading_spawn_addchdir(void *actions, const char *path) {
    return posix_spawn_file_actions_addchdir_np(actions, path);
}

int threading_spawn_close_unmapped(void *actions, const int32_t *targets, int count) {
    if (!actions || count < 0 || (count && !targets)) return EINVAL;
    int maximum = count ? targets[count - 1] : 2;
    if (maximum < 0 || maximum == INT_MAX) return EBADF;
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return errno;
    if ((rlim_t)maximum >= limit.rlim_cur) return EBADF;
    int target = 0;
    for (int descriptor = 0; descriptor <= maximum; descriptor++) {
        if (target < count && targets[target] == descriptor) { target++; continue; }
        int result = posix_spawn_file_actions_addclose(actions, descriptor);
        if (result) return result;
    }
    return posix_spawn_file_actions_addclosefrom_np(actions, maximum + 1);
}

int threading_child_pidfd(int32_t pid) {
    return syscall(SYS_pidfd_open, pid, 0);
}
uint64_t threading_native_thread_id(void) { return (uint64_t)syscall(SYS_gettid); }

static int pipe_write(int32_t descriptor, const uint8_t *bytes, int32_t length,
                      int complete, int32_t *count) {
    if (descriptor < 0 || length < 0 || (length && !bytes)) return EINVAL;
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int result = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (result) return result;
    int previously_pending = 0;
    if (sigpending(&pending) != 0) { result = errno; goto restore; }
    previously_pending = sigismember(&pending, SIGPIPE);
    int offset = 0;
    while (offset < length) {
        ssize_t written = write(descriptor, bytes + offset, (size_t)(length - offset));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { result = written < 0 ? errno : EIO; break; }
        offset += (int)written;
        if (!complete) break;
    }
    if (count) *count = offset;
    if (result == EPIPE && !previously_pending) {
        const struct timespec immediate = {0, 0};
        while (sigtimedwait(&blocked, NULL, &immediate) < 0 && errno == EINTR) {}
    }
restore:
    {
        int restored = pthread_sigmask(SIG_SETMASK, &previous, NULL);
        return result ? result : restored;
    }
}

int threading_pipe_write_no_signal(int32_t descriptor, const uint8_t *bytes, int32_t length) {
    return pipe_write(descriptor, bytes, length, 1, NULL);
}

int threading_pipe_write_some_no_signal(int32_t descriptor, const uint8_t *bytes,
                                        int32_t length, int32_t *written) {
    if (!written) return EINVAL;
    *written = 0;
    return pipe_write(descriptor, bytes, length, 0, written);
}
