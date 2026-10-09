#pragma once
#include <stdint.h>
int threading_spawn_addchdir(void *actions, const char *path);
// Targets must be sorted and distinct. Applied after dup2 actions, this closes every
// descriptor the child was not explicitly given, including holes below its highest target.
int threading_spawn_close_unmapped(void *actions, const int32_t *targets, int count);
int threading_child_pidfd(int32_t pid);
uint64_t threading_native_thread_id(void);
// Blocking worker-only write. Returns an errno value; SIGPIPE policy and the calling thread's
// previous mask/pending signal are preserved. A closed reader returns EPIPE.
int threading_pipe_write_no_signal(int32_t descriptor, const uint8_t *bytes, int32_t length);
int threading_pipe_write_some_no_signal(int32_t descriptor, const uint8_t *bytes,
                                        int32_t length, int32_t *written);
