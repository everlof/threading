// Test-only Weston 13 module. Send input through the compositor's seat, not SDL's
// queue, so the installed application's real Wayland client receives it.
#include <errno.h>
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <libweston/libweston.h>

// Ubuntu's libweston-13-dev does not install backend.h. These declarations
// match Weston 13.0.0's libweston/backend.h and input.c, whose
// implementations are exported by the installed libweston-13.so.
void weston_seat_init(struct weston_seat *, struct weston_compositor *, const char *);
void weston_seat_release(struct weston_seat *);
void weston_seat_init_pointer(struct weston_seat *);
int weston_seat_init_keyboard(struct weston_seat *, struct xkb_keymap *);
void notify_motion_absolute(struct weston_seat *, const struct timespec *,
                            struct weston_coord_global);
void notify_button(struct weston_seat *, const struct timespec *, int32_t,
                   enum wl_pointer_button_state);
void notify_key(struct weston_seat *, const struct timespec *, uint32_t,
                enum wl_keyboard_key_state, enum weston_key_state_update);

struct input_module {
    struct weston_compositor *compositor;
    struct weston_seat seat;
    struct wl_listener destroy_listener;
    struct wl_event_source *source;
    int socket_fd;
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
};

static void destroy_module(struct wl_listener *listener, void *unused) {
    (void)unused;
    struct input_module *module = wl_container_of(listener, module, destroy_listener);
    wl_event_source_remove(module->source);
    close(module->socket_fd);
    unlink(module->socket_path);
    weston_seat_release(&module->seat);
    free(module);
}

static int receive_command(int fd, uint32_t mask, void *data) {
    (void)mask;
    struct input_module *module = data;
    struct sockaddr_un peer = {0};
    socklen_t peer_length = sizeof(peer);
    char command[80] = {0};
    ssize_t length = recvfrom(fd, command, sizeof(command) - 1, 0,
                              (struct sockaddr *)&peer, &peer_length);
    if (length <= 0) return 0;
    command[length] = '\0';
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int x, y, key;
    char state[16];
    const char *reply = "ERR";
    char detail[128];
    if (strcmp(command, "origin") == 0) {
        struct weston_view *view;
        wl_list_for_each(view, &module->compositor->view_list, link) {
            if (view->is_mapped && view->surface->width == 800 &&
                view->surface->height == 480) {
                snprintf(detail, sizeof(detail), "ORIGIN %.0f %.0f",
                         view->geometry.pos_offset.x, view->geometry.pos_offset.y);
                reply = detail;
                break;
            }
        }
    } else if (sscanf(command, "move %d %d", &x, &y) == 2 && x >= 0 && y >= 0) {
        struct weston_coord_global point = {.c = weston_coord(x, y)};
        notify_motion_absolute(&module->seat, &now, point);
        reply = "OK";
    } else if (sscanf(command, "button %15s", state) == 1 &&
               (strcmp(state, "down") == 0 || strcmp(state, "up") == 0 ||
                strcmp(state, "right-down") == 0 || strcmp(state, "right-up") == 0)) {
        const int right = strncmp(state, "right-", 6) == 0;
        const int down = strcmp(state, "down") == 0 || strcmp(state, "right-down") == 0;
        notify_button(&module->seat, &now, right ? BTN_RIGHT : BTN_LEFT,
                      down ? WL_POINTER_BUTTON_STATE_PRESSED
                           : WL_POINTER_BUTTON_STATE_RELEASED);
        reply = "OK";
    } else if (sscanf(command, "key %d %7s", &key, state) == 2 &&
               key >= 0 && key <= KEY_MAX &&
               (strcmp(state, "down") == 0 || strcmp(state, "up") == 0)) {
        notify_key(&module->seat, &now, (uint32_t)key,
                   strcmp(state, "down") == 0 ? WL_KEYBOARD_KEY_STATE_PRESSED
                                                : WL_KEYBOARD_KEY_STATE_RELEASED,
                   STATE_UPDATE_AUTOMATIC);
        reply = "OK";
    }
    sendto(fd, reply, strlen(reply), 0, (struct sockaddr *)&peer, peer_length);
    return 0;
}

__attribute__((visibility("default")))
int wet_module_init(struct weston_compositor *compositor, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    const char *path = getenv("THREADING_WESTON_INPUT_SOCKET");
    if (!path || !*path || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path))
        return -1;
    struct input_module *module = calloc(1, sizeof(*module));
    if (!module) return -1;
    module->compositor = compositor;
    module->socket_fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (module->socket_fd < 0) goto fail;
    strcpy(module->socket_path, path);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strcpy(address.sun_path, path);
    unlink(path);
    if (bind(module->socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0)
        goto fail;
    weston_seat_init(&module->seat, compositor, "threading-test-input");
    weston_seat_init_pointer(&module->seat);
    if (weston_seat_init_keyboard(&module->seat, NULL) < 0) {
        weston_seat_release(&module->seat);
        goto fail;
    }
    module->source = wl_event_loop_add_fd(wl_display_get_event_loop(compositor->wl_display),
                                          module->socket_fd, WL_EVENT_READABLE,
                                          receive_command, module);
    if (!module->source) {
        weston_seat_release(&module->seat);
        goto fail;
    }
    module->destroy_listener.notify = destroy_module;
    wl_signal_add(&compositor->destroy_signal, &module->destroy_listener);
    return 0;
fail:
    if (module->socket_fd >= 0) close(module->socket_fd);
    unlink(path);
    free(module);
    return -1;
}
