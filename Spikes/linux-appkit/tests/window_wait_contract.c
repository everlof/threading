// Real SDL/AT-SPI wait contract. Compile with Window.c + Accessibility.c and pkg-config
// --cflags --libs sdl2 atk-bridge-2.0 atk gobject-2.0, then run under xvfb-run -a dbus-run-session.
#include "LinuxWindowBridge.h"
#include "AccessibilityInternal.h"
#include <SDL2/SDL.h>
#include <glib.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static Uint32 ignored_event(Uint32 interval, void *unused) {
    (void)interval; (void)unused;
    SDL_Event event = {.type = SDL_USEREVENT + 1000};
    assert(SDL_PushEvent(&event) == 1);
    return 0;
}

static gboolean accessibility_dispatch(gpointer data) {
    *(int *)data = 1;
    SDL_Event event = {.type = SDL_QUIT};
    assert(SDL_PushEvent(&event) == 1);
    return G_SOURCE_REMOVE;
}

static void settle(void) {
    const Uint64 until = SDL_GetTicks64() + 100;
    do {
        tw_accessibility_poll();
        SDL_PumpEvents();
        SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);
        SDL_Delay(10);
    } while (SDL_GetTicks64() < until);
}

int main(int argc, char **argv) {
    const char *only = argc > 1 ? argv[1] : "all";
    TWWindow *window = tw_open("Wait contract", 320, 180);
    assert(window && SDL_InitSubSystem(SDL_INIT_TIMER) == 0);
    assert(tw_accessibility_event_type() != UINT32_MAX);
    TWEvent event;
    Uint64 started, elapsed;
    if (!strcmp(only, "all") || !strcmp(only, "deadline")) {
        settle();
        SDL_TimerID timer = SDL_AddTimer(70, ignored_event, NULL);
        assert(timer);
        started = SDL_GetTicks64();
        assert(tw_next_timeout(window, &event, 200) == 0);
        elapsed = SDL_GetTicks64() - started;
        SDL_RemoveTimer(timer);
        printf("deadline elapsedMs=%llu\n", (unsigned long long)elapsed); fflush(stdout);
        assert(elapsed >= 180 && elapsed < 1000);
    }
    if (!strcmp(only, "all") || !strcmp(only, "immediate")) {
        settle();
        SDL_Event quit = {.type = SDL_QUIT};
        assert(SDL_PushEvent(&quit) == 1);
        started = SDL_GetTicks64();
        assert(tw_next_timeout(window, &event, 2000) == 1 && event.kind == 5);
        elapsed = SDL_GetTicks64() - started;
        printf("immediate elapsedMs=%llu\n", (unsigned long long)elapsed); fflush(stdout);
        assert(elapsed < 1000);
    }
    if (!strcmp(only, "all") || !strcmp(only, "accessibility")) {
        settle();
        int dispatched = 0;
        guint source = g_timeout_add(70, accessibility_dispatch, &dispatched);
        started = SDL_GetTicks64();
        int received = tw_next_timeout(window, &event, 2000);
        elapsed = SDL_GetTicks64() - started;
        if (!dispatched) g_source_remove(source);
        printf("accessibility elapsedMs=%llu dispatched=%d\n",
               (unsigned long long)elapsed, dispatched); fflush(stdout);
        assert(dispatched && received == 1 && event.kind == 5 && elapsed < 1000);
    }
    tw_close(window);
    puts("PASS native total deadline, immediate SDL event and responsive accessibility dispatch");
    return 0;
}
