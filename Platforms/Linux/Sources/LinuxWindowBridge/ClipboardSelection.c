#define _GNU_SOURCE
#include "LinuxWindowBridge.h"
#ifdef __linux__
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <stdint.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

enum { CLIPBOARD_LIMIT = 32 * 1024 * 1024, CLIPBOARD_TIMEOUT_MS = 1200 };
static int xlib_threads_ready;

void tw_clipboard_prepare(void) { xlib_threads_ready = XInitThreads() != 0; }

static int64_t milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int next_selection_event(Display *display, Window requestor, Atom property,
                                int64_t deadline, XEvent *event) {
    for (;;) {
        while (XPending(display)) {
            XNextEvent(display, event);
            if (event->type == SelectionNotify && event->xselection.requestor == requestor)
                return 1;
            if (event->type == PropertyNotify && event->xproperty.window == requestor
                && event->xproperty.atom == property && event->xproperty.state == PropertyNewValue)
                return 1;
        }
        int64_t remaining = deadline - milliseconds();
        if (remaining <= 0) return 0;
        struct pollfd socket = { .fd = ConnectionNumber(display), .events = POLLIN };
        if (poll(&socket, 1, remaining > 100 ? 100 : (int)remaining) < 0) return 0;
    }
}

static int append_bytes(uint8_t **buffer, size_t *length, size_t *capacity,
                        const unsigned char *bytes, size_t count) {
    if (count > CLIPBOARD_LIMIT - *length) return -1;
    if (*length + count > *capacity) {
        size_t next = *capacity ? *capacity : 65536;
        while (next < *length + count) next *= 2;
        if (next > CLIPBOARD_LIMIT) next = CLIPBOARD_LIMIT;
        uint8_t *larger = realloc(*buffer, next);
        if (!larger) return -1;
        *buffer = larger;
        *capacity = next;
    }
    if (count) memcpy(*buffer + *length, bytes, count);
    *length += count;
    return 0;
}

// Read one property in 64 KiB pieces so no single X server reply can exhaust memory.
static int read_property(Display *display, Window requestor, Atom property, Atom incr,
                         uint8_t **buffer, size_t *length, size_t *capacity,
                         int *incremental, int *finished) {
    unsigned long offset = 0, remaining = 0;
    *finished = 0;
    do {
        Atom type = None;
        int format = 0;
        unsigned long items = 0;
        unsigned char *value = NULL;
        int status = XGetWindowProperty(display, requestor, property, (long)offset, 16384,
                                        False, AnyPropertyType, &type, &format, &items,
                                        &remaining, &value);
        if (status != Success) { if (value) XFree(value); return -1; }
        if (type == incr && !*incremental && offset == 0) {
            if (value) XFree(value);
            *incremental = 1;
            XDeleteProperty(display, requestor, property);
            XFlush(display);
            return 0;
        }
        if (type == None || format != 8 || (size_t)items > CLIPBOARD_LIMIT - *length
            || append_bytes(buffer, length, capacity, value, items) != 0) {
            if (value) XFree(value);
            return -1;
        }
        if (value) XFree(value);
        offset += (items + 3) / 4;
        if (remaining && !items) return -1;
        if (!remaining && !items) *finished = 1;
    } while (remaining);
    XDeleteProperty(display, requestor, property);
    XFlush(display);
    return 0;
}

int tw_clipboard_read_target(const char *target, uint8_t **bytes, int *length) {
    if (!xlib_threads_ready || !target || !bytes || !length || (strcmp(target, "image/png") != 0
        && strcmp(target, "image/tiff") != 0
        && strcmp(target, "text/uri-list") != 0)) return -2;
    *bytes = NULL;
    *length = 0;
    Display *display = XOpenDisplay(NULL);
    if (!display) return -1; // A Wayland-only session has no X11 selection.
    Window requestor = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                            0, 0, 1, 1, 0, 0, 0);
    Atom selection = XInternAtom(display, "CLIPBOARD", False);
    Atom requested = XInternAtom(display, target, False);
    Atom property = XInternAtom(display, "THREADING_CLIPBOARD_REPLY", False);
    Atom incr = XInternAtom(display, "INCR", False);
    XSelectInput(display, requestor, PropertyChangeMask);
    XConvertSelection(display, selection, requested, property, requestor, CurrentTime);
    XFlush(display);

    int result = -2, incremental = 0, finished = 0;
    size_t count = 0, capacity = 0;
    uint8_t *buffer = NULL;
    int64_t deadline = milliseconds() + CLIPBOARD_TIMEOUT_MS;
    XEvent event;
    while (next_selection_event(display, requestor, property, deadline, &event)) {
        if (event.type == SelectionNotify) {
            if (event.xselection.property == None) { result = -1; break; }
        } else if (!incremental) {
            continue;
        }
        if (read_property(display, requestor, property, incr, &buffer, &count, &capacity,
                          &incremental, &finished) != 0) break;
        if (!incremental || finished) {
            if (count > 0) { *bytes = buffer; *length = (int)count; buffer = NULL; result = 0; }
            else result = -1;
            break;
        }
    }
    free(buffer);
    XDestroyWindow(display, requestor);
    XCloseDisplay(display);
    return result;
}

void tw_clipboard_free(void *bytes) { free(bytes); }

int tw_clipboard_read_wayland_target(const char *target, uint8_t **bytes, int *length) {
    if (!target || !bytes || !length || (strcmp(target, "image/png") != 0
        && strcmp(target, "image/tiff") != 0
        && strcmp(target, "text/uri-list") != 0)) return -2;
    *bytes = NULL;
    *length = 0;
    int output[2];
    if (pipe2(output, O_CLOEXEC) != 0) return -2;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, output[0]);
    posix_spawn_file_actions_addclose(&actions, output[1]);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclosefrom_np(&actions, 3);
    char *arguments[] = {"wl-paste", "--no-newline", "--type", (char *)target, NULL};
    pid_t child = -1;
    int started = posix_spawn(&child, "/usr/bin/wl-paste", &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(output[1]);
    if (started != 0) { close(output[0]); return -2; }

    uint8_t *buffer = NULL;
    size_t count = 0, capacity = 0;
    int64_t deadline = milliseconds() + CLIPBOARD_TIMEOUT_MS;
    int complete = 0;
    while (milliseconds() < deadline) {
        int remaining = (int)(deadline - milliseconds());
        struct pollfd source = {.fd = output[0], .events = POLLIN | POLLHUP};
        int ready = poll(&source, 1, remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) break;
        uint8_t chunk[65536];
        ssize_t size = read(output[0], chunk, sizeof(chunk));
        if (size < 0 && errno == EINTR) continue;
        if (size < 0 || (size > 0 && append_bytes(&buffer, &count, &capacity,
                                                 chunk, (size_t)size) != 0)) break;
        if (size == 0) { complete = 1; break; }
    }
    close(output[0]);
    int status = 0;
    pid_t reaped = 0;
    while (milliseconds() < deadline) {
        reaped = waitpid(child, &status, WNOHANG);
        if (reaped == child || (reaped < 0 && errno != EINTR)) break;
        struct timespec interval = {.tv_sec = 0, .tv_nsec = 5000000};
        nanosleep(&interval, NULL);
    }
    if (reaped != child) {
        kill(child, SIGKILL);
        do { reaped = waitpid(child, &status, 0); }
        while (reaped < 0 && errno == EINTR);
    }
    if (reaped == child && complete && WIFEXITED(status)
        && WEXITSTATUS(status) == 0 && count > 0) {
        *bytes = buffer;
        *length = (int)count;
        return 0;
    }
    free(buffer);
    return complete ? -1 : -2;
}
#endif
