// Threading log tap.
//
// Copies stdout and stderr into the unified log while still writing them through to the original
// descriptors, so `print()` becomes readable from the Mac without swallowing the console.
//
// Linked with `-Wl,-force_load` (device, and any project whose targets set OTHER_LDFLAGS without
// $(inherited)) or injected with DYLD_INSERT_LIBRARIES (simulator, macOS). See
// docs/feature-drafts/device-and-simulator-logs.md.
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

#define TAP_MARKER "THREADING_LOG_TAP_INSTALLED"

static os_log_t tap_log;

typedef struct { int source; int passthrough; } tap_channel;

static void *tap_pump(void *ctx) {
    tap_channel *channel = (tap_channel *)ctx;
    char buf[4096];
    size_t used = 0;
    for (;;) {
        ssize_t n = read(channel->source, buf + used, sizeof(buf) - used - 1);
        if (n <= 0) break;
        // Write through first: a tap that swallows the console makes Xcode worse, not better.
        (void)write(channel->passthrough, buf + used, (size_t)n);
        used += (size_t)n;
        buf[used] = '\0';
        char *start = buf, *nl;
        while ((nl = memchr(start, '\n', used - (size_t)(start - buf)))) {
            *nl = '\0';
            if (*start) os_log(tap_log, "[stdio] %{public}s", start);
            start = nl + 1;
        }
        used -= (size_t)(start - buf);
        memmove(buf, start, used);
        // One pathological line must not become unbounded memory.
        if (used == sizeof(buf) - 1) used = 0;
    }
    free(channel);
    return NULL;
}

static void tap_capture(int target_fd) {
    int original = dup(target_fd);
    if (original < 0) return;
    int p[2];
    if (pipe(p) != 0) { close(original); return; }
    dup2(p[1], target_fd);
    close(p[1]);
    tap_channel *channel = malloc(sizeof(tap_channel));
    if (!channel) { close(original); close(p[0]); return; }
    channel->source = p[0];
    channel->passthrough = original;
    pthread_t thread;
    if (pthread_create(&thread, NULL, tap_pump, channel) != 0) { free(channel); return; }
    pthread_detach(thread);
}

__attribute__((constructor))
static void threading_log_tap_init(void) {
    // A command-line OTHER_LDFLAGS applies to every target in the build, so this archive can be
    // force-loaded into the app *and* into frameworks it embeds. Each copy has its own statics,
    // so the guard has to be process-global: a second tap would dup2 over the first one's pipe
    // and read its own output back.
    if (getenv(TAP_MARKER) != NULL) return;
    setenv(TAP_MARKER, "1", 1);

    tap_log = os_log_create("codes.threading.logtap", "tap");
    tap_capture(STDOUT_FILENO);
    tap_capture(STDERR_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
    os_log(tap_log, "[tap] installed in pid %{public}d", getpid());
}
