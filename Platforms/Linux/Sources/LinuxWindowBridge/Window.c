#include "LinuxWindowBridge.h"
#include "AccessibilityInternal.h"
#ifdef __linux__
#include <SDL2/SDL.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
struct TWWindow {
    SDL_Window *window;
    SDL_Renderer *renderer;
    SDL_Texture *texture;
    SDL_Texture *sidebarTexture, *terminalTexture;
    int sidebarTextureWidth, sidebarTextureHeight, terminalTextureWidth, terminalTextureHeight;
    int sidebarWidth, sidebarFocused;
    uint32_t terminalButtons;
    SDL_Rect actionsBounds;
    int actionsVisible, actionsEnabled, actionsTracking, actionsState;
    int navigatorPointerRoute, navigatorTracking, navigatorHovered, navigatorSuppressLeftUp;
    int width, height, terminal, projectNavigation, suppressActivation, explicitSurfaceUpdate;
    int composing;
    uint8_t suppressedKeyups[SDL_NUM_SCANCODES];
};
static int tw_modifiers(SDL_Keymod mods) {
    return ((mods & KMOD_SHIFT) ? 1 : 0) | ((mods & KMOD_ALT) ? 2 : 0)
        | ((mods & KMOD_CTRL) ? 4 : 0) | ((mods & KMOD_GUI) ? 8 : 0)
        | ((mods & KMOD_CAPS) ? 16 : 0) | ((mods & KMOD_NUM) ? 32 : 0);
}
const char *tw_error(void) { return SDL_GetError(); }
static double tw_startup_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec * 1000 + (double)now.tv_nsec / 1000000;
}
static void tw_startup_trace(int enabled, double started, const char *stage) {
    if (!enabled) return;
    fprintf(stderr, "STARTUP_TRACE scope=window stage=%s elapsedMs=%.3f\n",
            stage, tw_startup_milliseconds() - started);
    fflush(stderr);
}
static void tw_navigation_trace_dequeue(const SDL_Event *event, int current) {
    static int enabled = -1;
    static unsigned records;
    if (enabled < 0) {
        const char *value = getenv("THREADING_LINUX_NAVIGATION_TRACE");
        enabled = value && strcmp(value, "1") == 0;
    }
    if (!enabled || records >= TW_MAX_NAVIGATION_TRACE_RECORDS) return;
    records++;
    fprintf(stderr, "NAVIGATION_TRACE scope=window stage=dequeue monotonicMs=%.3f "
            "code=%d row=%d generation=%u current=%d\n",
            tw_startup_milliseconds(), event->user.code,
            (int)(intptr_t)event->user.data1, (uint32_t)(uintptr_t)event->user.data2, current);
    fflush(stderr);
}
void tw_close(TWWindow *w) {
    if (!w) return;
    tw_accessibility_close();
    SDL_DestroyTexture(w->texture);
    SDL_DestroyTexture(w->sidebarTexture);
    SDL_DestroyTexture(w->terminalTexture);
    SDL_DestroyRenderer(w->renderer);
    SDL_DestroyWindow(w->window);
    free(w);
    SDL_Quit();
}
TWWindow *tw_open(const char *title, int width, int height) {
    const char *traceValue = getenv("THREADING_LINUX_STARTUP_TRACE");
    const int trace = traceValue && strcmp(traceValue, "1") == 0;
    const double started = trace ? tw_startup_milliseconds() : 0;
    // The legacy 32-byte editing event silently truncates long compositions. SDL's extended
    // event keeps the whole preedit available for an explicit bounded projection below.
    SDL_SetHint(SDL_HINT_IME_SUPPORT_EXTENDED_TEXT, "1");
    tw_startup_trace(trace, started, "sdl-init.begin");
    const int initialized = SDL_Init(SDL_INIT_VIDEO);
    tw_startup_trace(trace, started, "sdl-init.end");
    if (initialized != 0) return NULL;
    TWWindow *w = calloc(1, sizeof(*w));
    if (!w) { SDL_Quit(); return NULL; }
    tw_startup_trace(trace, started, "create-window.begin");
    w->window = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                width, height, SDL_WINDOW_RESIZABLE);
    tw_startup_trace(trace, started, "create-window.end");
    if (!w->window) { tw_close(w); return NULL; }
    // Explicit experiment bounds keep the software rasterizer's allocation/work bounded.
    SDL_SetWindowMinimumSize(w->window, 320, 180);
    SDL_SetWindowMaximumSize(w->window, 1280, 900);
    tw_startup_trace(trace, started, "create-renderer.begin");
    w->renderer = SDL_CreateRenderer(w->window, -1, SDL_RENDERER_SOFTWARE);
    tw_startup_trace(trace, started, "create-renderer.end");
    if (!w->renderer) { tw_close(w); return NULL; }
    tw_startup_trace(trace, started, "accessibility-open.begin");
    tw_accessibility_open(w);
    tw_accessibility_window_focus(w, (SDL_GetWindowFlags(w->window) & SDL_WINDOW_INPUT_FOCUS) != 0);
    tw_startup_trace(trace, started, "accessibility-open.end");
    return w;
}
void tw_window_geometry(TWWindow *w, int *x, int *y, int *width, int *height) {
    SDL_GetWindowPosition(w->window, x, y);
    SDL_GetWindowSize(w->window, width, height);
}
int tw_present(TWWindow *w, const uint8_t *rgba, int width, int height) {
    if (!w || w->sidebarWidth || !rgba || width < 1 || width > 1280 || height < 1 || height > 900) return -1;
    if (!w->texture || w->width != width || w->height != height) {
        SDL_DestroyTexture(w->texture);
        w->texture = SDL_CreateTexture(w->renderer, SDL_PIXELFORMAT_RGBA32,
                                      SDL_TEXTUREACCESS_STREAMING, width, height);
        w->width = width; w->height = height;
    }
    if (!w->texture || SDL_UpdateTexture(w->texture, NULL, rgba, width * 4) != 0) return -1;
    if (SDL_RenderClear(w->renderer) != 0 || SDL_RenderCopy(w->renderer, w->texture, NULL, NULL) != 0) return -1;
    SDL_RenderPresent(w->renderer);
    // After a host-driven resize SDL's software renderer can leave the X11 drawable on its old
    // contents even though its surface has the new frame. Flush that owned surface explicitly.
    if (w->explicitSurfaceUpdate && SDL_UpdateWindowSurface(w->window) != 0) return -1;
    return 0;
}
int tw_repaint(TWWindow *w) {
    if (w->sidebarWidth) {
        int width, height;
        SDL_GetWindowSize(w->window, &width, &height);
        if (SDL_SetRenderDrawColor(w->renderer, 24, 24, 24, 255) != 0 ||
            SDL_RenderClear(w->renderer) != 0) return -1;
        // Never stretch cells or labels while a resize is awaiting a freshly sized frame.
        // Crop the retained pixels to the new pane and leave any exposed remainder as ground.
        SDL_Texture *textures[2] = {w->sidebarTexture, w->terminalTexture};
        int widths[2] = {w->sidebarTextureWidth, w->terminalTextureWidth};
        int heights[2] = {w->sidebarTextureHeight, w->terminalTextureHeight};
        for (int index = 0; index < 2; index++) {
            const int available = index == 0 ? w->sidebarWidth : width - w->sidebarWidth;
            const int drawnWidth = widths[index] < available ? widths[index] : available;
            const int drawnHeight = heights[index] < height ? heights[index] : height;
            if (!textures[index] || drawnWidth <= 0 || drawnHeight <= 0) continue;
            SDL_Rect source = {0, 0, drawnWidth, drawnHeight};
            SDL_Rect destination = {index == 0 ? 0 : w->sidebarWidth, 0, drawnWidth, drawnHeight};
            if (SDL_RenderCopy(w->renderer, textures[index], &source, &destination) != 0) return -1;
        }
        SDL_RenderPresent(w->renderer);
        return !w->explicitSurfaceUpdate || SDL_UpdateWindowSurface(w->window) == 0 ? 0 : -1;
    }
    if (!w->texture) return 0;
    if (SDL_RenderClear(w->renderer) != 0 || SDL_RenderCopy(w->renderer, w->texture, NULL, NULL) != 0) return -1;
    SDL_RenderPresent(w->renderer);
    return !w->explicitSurfaceUpdate || SDL_UpdateWindowSurface(w->window) == 0 ? 0 : -1;
}
int tw_present_pane(TWWindow *w, const uint8_t *rgba, int width, int height, int sidebar) {
    if (!w || !w->sidebarWidth || !rgba || width < 1 || height < 1 || height > 900 ||
        (sidebar != 0 && sidebar != 1) || width > (sidebar ? w->sidebarWidth : 1280)) return -1;
    SDL_Texture **texture = sidebar ? &w->sidebarTexture : &w->terminalTexture;
    int *oldWidth = sidebar ? &w->sidebarTextureWidth : &w->terminalTextureWidth;
    int *oldHeight = sidebar ? &w->sidebarTextureHeight : &w->terminalTextureHeight;
    if (!*texture || *oldWidth != width || *oldHeight != height) {
        SDL_DestroyTexture(*texture);
        *texture = SDL_CreateTexture(w->renderer, SDL_PIXELFORMAT_RGBA32,
                                    SDL_TEXTUREACCESS_STREAMING, width, height);
        *oldWidth = width; *oldHeight = height;
    }
    if (!*texture || SDL_UpdateTexture(*texture, NULL, rgba, width * 4) != 0) return -1;
    return tw_repaint(w);
}
void tw_actions_button(TWWindow *w, const char *label, int enabled,
                       int x, int y, int width, int height) {
    if (!w) return;
    int windowWidth, windowHeight;
    SDL_GetWindowSize(w->window, &windowWidth, &windowHeight);
    const int available = w->sidebarWidth ? w->sidebarWidth : windowWidth;
    if (height < 0 || (height > 0 && (x < 0 || y < 0 || width <= 0
        || x >= available || width > available - x || y >= windowHeight || height > windowHeight - y))) return;
    w->actionsVisible = height > 0;
    w->actionsEnabled = enabled != 0;
    w->actionsBounds = (SDL_Rect){x, y, width, height};
    if (!w->actionsVisible || !w->actionsEnabled) w->actionsState = 0;
    tw_accessibility_actions_button(w, label, enabled, x, y, width, height);
}
void tw_add_project_button(TWWindow *w, int enabled, int x, int y, int width, int height) {
    if (!w) return;
    int windowWidth, windowHeight;
    SDL_GetWindowSize(w->window, &windowWidth, &windowHeight);
    const int available = w->sidebarWidth ? w->sidebarWidth : windowWidth;
    if (height < 0 || (height > 0 && (x < 0 || y < 0 || width <= 0
        || x >= available || width > available - x || y >= windowHeight
        || height > windowHeight - y))) return;
    tw_accessibility_add_project_button(w, enabled, x, y, width, height);
}
static int actions_contains(TWWindow *w, int x, int y) {
    const SDL_Point point = {x, y};
    return w->actionsVisible && SDL_PointInRect(&point, &w->actionsBounds);
}
static int navigator_contains(TWWindow *w, const TWEvent *frame, int x, int y) {
    return x >= 0 && y >= 0 && y < frame->height &&
        (w->sidebarWidth ? x < w->sidebarWidth : !w->terminal && x < frame->width);
}
void tw_navigator_pointer_route(TWWindow *w, int enabled) {
    if (!w || w->navigatorPointerRoute == (enabled != 0)) return;
    w->navigatorPointerRoute = enabled != 0;
    if (w->actionsTracking || w->navigatorTracking) SDL_CaptureMouse(SDL_FALSE);
    if (w->actionsTracking || w->navigatorTracking) w->navigatorSuppressLeftUp = 1;
    w->actionsTracking = w->actionsState = 0;
    w->navigatorTracking = w->navigatorHovered = 0;
}
static void actions_activate(TWWindow *w, TWEvent *out) {
    if (w->actionsTracking || w->navigatorTracking) SDL_CaptureMouse(SDL_FALSE);
    if (w->navigatorTracking) w->navigatorSuppressLeftUp = 1;
    w->actionsTracking = w->navigatorTracking = w->navigatorHovered = 0;
    out->kind = 25;
    out->action = w->terminal ? 0 : 1;
    if (w->sidebarWidth) tw_workspace_focus(w, 1);
    w->actionsState = 0;
}
int tw_workspace_sidebar_width(TWWindow *w) { return w ? w->sidebarWidth : 0; }
int tw_workspace_sidebar_focused(TWWindow *w) { return w && w->sidebarWidth && w->sidebarFocused; }
int tw_workspace_reset_terminal(TWWindow *w) {
    if (!w || !w->sidebarWidth) return -1;
    w->terminalButtons = 0;
    SDL_DestroyTexture(w->terminalTexture);
    w->terminalTexture = NULL;
    w->terminalTextureWidth = w->terminalTextureHeight = 0;
    return tw_repaint(w);
}
void tw_workspace_focus(TWWindow *w, int sidebarFocused) {
    if (!w || !w->sidebarWidth) return;
    const int next = sidebarFocused != 0;
    if (w->sidebarFocused == next && w->terminal == !next) return;
    // A gesture belongs to the terminal that received its press. Once navigation takes focus,
    // a later release must not be delivered to a different session selected in that sidebar.
    if (next) w->terminalButtons = 0;
    w->sidebarFocused = next;
    w->terminal = !next;
    w->composing = 0;
    // Cancel the platform's composition before changing destinations; a later text event from
    // that cancelled composition must not become project navigation or terminal input.
    SDL_ClearComposition();
    SDL_StopTextInput();
    SDL_FlushEvent(SDL_TEXTINPUT);
    SDL_FlushEvent(SDL_TEXTEDITING);
    if (!next) SDL_StartTextInput();
    tw_accessibility_workspace_changed(w);
}
void tw_workspace_mode(TWWindow *w, int sidebarWidth, int sidebarFocused) {
    if (!w || (sidebarWidth != 0 && sidebarWidth != 320)) return;
    if (w->sidebarWidth == sidebarWidth) {
        if (sidebarWidth) tw_workspace_focus(w, sidebarFocused);
        return;
    }
    w->sidebarWidth = sidebarWidth;
    w->terminalButtons = 0;
    if (w->navigatorTracking) {
        SDL_CaptureMouse(SDL_FALSE);
        w->navigatorTracking = 0;
        w->navigatorSuppressLeftUp = 1;
    }
    w->navigatorHovered = 0;
    SDL_DestroyTexture(w->texture); w->texture = NULL;
    SDL_DestroyTexture(w->sidebarTexture); w->sidebarTexture = NULL;
    SDL_DestroyTexture(w->terminalTexture); w->terminalTexture = NULL;
    SDL_SetWindowMinimumSize(w->window, sidebarWidth ? 640 : 320, 180);
    SDL_SetWindowMaximumSize(w->window, sidebarWidth ? 1600 : 1280, 900);
    if (sidebarWidth) {
        // Force the first transition through the same input/focus lifecycle as later changes.
        w->sidebarFocused = !(sidebarFocused != 0);
        tw_workspace_focus(w, sidebarFocused);
    } else {
        tw_project_mode(w);
        tw_accessibility_workspace_changed(w);
    }
}
void tw_title(TWWindow *w, const char *title) {
    SDL_SetWindowTitle(w->window, title);
    tw_accessibility_title(title);
}
int tw_resize(TWWindow *w, int width, int height) {
    int oldWidth, oldHeight;
    SDL_GetWindowSize(w->window, &oldWidth, &oldHeight);
    if (oldWidth == width && oldHeight == height) return 0;
    SDL_SetWindowSize(w->window, width, height);
    w->explicitSurfaceUpdate = 1;
    return 0;
}
void tw_terminal_mode(TWWindow *w) {
    if (w->sidebarWidth) { tw_workspace_focus(w, 0); return; }
    if (w->navigatorTracking) {
        SDL_CaptureMouse(SDL_FALSE);
        w->navigatorTracking = 0;
        w->navigatorSuppressLeftUp = 1;
    }
    w->navigatorHovered = 0;
    w->terminal = 1;
    w->composing = 0;
    memset(w->suppressedKeyups, 0, sizeof(w->suppressedKeyups));
    SDL_Rect caret = {0, 0, 10, 22};
    SDL_SetTextInputRect(&caret);
    SDL_StartTextInput();
}
void tw_project_navigation(TWWindow *w, int enabled) { w->projectNavigation = enabled; }
void tw_project_mode(TWWindow *w) {
    if (w->sidebarWidth) { tw_workspace_focus(w, 1); return; }
    w->terminal = 0;
    w->composing = 0;
    memset(w->suppressedKeyups, 0, sizeof(w->suppressedKeyups));
    SDL_StopTextInput();
}
void tw_text_input_rect(TWWindow *w, int x, int y, int width, int height) {
    if (!w || !w->terminal) return;
    SDL_Rect caret = {x, y, width, height};
    SDL_SetTextInputRect(&caret);
}
const char *tw_event_text(const TWEvent *e) { return e->text; }
int tw_clipboard_read(uint8_t *destination, int capacity) {
    if (!destination || capacity < 1 || capacity > 65536) return -2;
    char *text = SDL_GetClipboardText();
    if (!text) return -2;
    size_t length = strnlen(text, (size_t)capacity + 1);
    if (length <= (size_t)capacity) memcpy(destination, text, length);
    SDL_free(text);
    return length > (size_t)capacity ? -1 : (int)length;
}
int tw_clipboard_write(const uint8_t *source, int length) {
    if (!source || length < 1 || length > 1024 * 1024 || memchr(source, 0, (size_t)length)) return -1;
    char *text = malloc((size_t)length + 1);
    if (!text) return -1;
    memcpy(text, source, (size_t)length);
    text[length] = 0;
    int result = SDL_SetClipboardText(text);
    free(text);
    return result;
}
int tw_next(TWWindow *w, TWEvent *out) {
    if (tw_accessibility_event_type() == UINT32_MAX) return tw_next_timeout(w, out, -1);
    for (;;) {
        SDL_ClearError();
        int result = tw_next_timeout(w, out, 33);
        if (result || SDL_GetError()[0]) return result ? result : -1;
    }
}
int tw_next_timeout(TWWindow *w, TWEvent *out, int milliseconds) {
    SDL_Event e;
    const uint64_t deadline = milliseconds >= 0 ? SDL_GetTicks64() + (uint64_t)milliseconds : 0;
    int attempted = 0;
    for (;;) {
        int wait = milliseconds;
        if (milliseconds >= 0) {
            const uint64_t now = SDL_GetTicks64();
            if (attempted && now >= deadline) return 0;
            wait = now >= deadline ? 0 : (int)(deadline - now);
        }
        attempted = 1;
        // AT-SPI dispatch shares this thread. Long host deadlines must retain the same bridge
        // pump as tw_next, without waking the host loop until an event or the total deadline.
        tw_accessibility_poll();
        if (tw_accessibility_event_type() != UINT32_MAX && (wait < 0 || wait > 33)) wait = 33;
        SDL_ClearError();
        if (!SDL_WaitEventTimeout(&e, wait)) {
            if (SDL_GetError()[0]) return -1;
            if (milliseconds == 0 || (milliseconds < 0 && wait < 0)) return 0;
            continue;
        }
        if (!w->terminal && e.type == SDL_TEXTEDITING_EXT) {
            SDL_free(e.editExt.text);
            continue;
        }
        *out = (TWEvent){0};
        SDL_GetWindowSize(w->window, &out->width, &out->height);
        // Navigation-owned key releases remain navigation-owned even when their press opened
        // a terminal or moved focus. Never send the other pane a lone Enter/arrow/Tab release.
        if ((w->sidebarWidth || w->actionsVisible) && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) &&
            e.key.keysym.scancode >= 0 && e.key.keysym.scancode < SDL_NUM_SCANCODES) {
            if (e.type == SDL_KEYUP && w->suppressedKeyups[e.key.keysym.scancode]) {
                w->suppressedKeyups[e.key.keysym.scancode] = 0;
                if (w->suppressActivation == e.key.keysym.sym) w->suppressActivation = 0;
                continue;
            }
            if (!w->terminal && e.type == SDL_KEYDOWN)
                w->suppressedKeyups[e.key.keysym.scancode] = 1;
        }
        if (w->navigatorSuppressLeftUp && e.type == SDL_MOUSEBUTTONUP &&
            e.button.button == SDL_BUTTON_LEFT) {
            w->navigatorSuppressLeftUp = 0;
            continue;
        }
        if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT)
            w->navigatorSuppressLeftUp = 0;
        // The opt-in shim route owns only the navigator's visible pane. One tracked left press
        // keeps its owner through release, even if the pointer crosses into the terminal. The
        // bridge does constant work per motion and leaves terminal-owned drags untouched.
        if (w->navigatorPointerRoute && e.type == SDL_MOUSEBUTTONUP &&
            e.button.button == SDL_BUTTON_LEFT && w->navigatorTracking) {
            w->navigatorTracking = 0;
            w->navigatorHovered = navigator_contains(w, out, e.button.x, e.button.y);
            SDL_CaptureMouse(SDL_FALSE);
            out->kind = 27; out->action = 3; out->key = 0;
            out->x = e.button.x; out->y = e.button.y;
            out->modifiers = tw_modifiers(SDL_GetModState());
        } else if (w->navigatorPointerRoute && e.type == SDL_MOUSEMOTION &&
                   (w->navigatorTracking || (!w->terminalButtons &&
                    navigator_contains(w, out, e.motion.x, e.motion.y)))) {
            w->navigatorHovered = navigator_contains(w, out, e.motion.x, e.motion.y);
            out->kind = 27; out->action = w->navigatorTracking ? 2 : 0; out->key = 0;
            out->x = e.motion.x; out->y = e.motion.y;
            out->modifiers = tw_modifiers(SDL_GetModState());
        } else if (w->navigatorPointerRoute && e.type == SDL_MOUSEMOTION &&
                   w->navigatorHovered && !w->terminalButtons) {
            w->navigatorHovered = 0;
            out->kind = 27; out->action = 4; out->key = 0;
            out->x = e.motion.x; out->y = e.motion.y;
            out->modifiers = tw_modifiers(SDL_GetModState());
        } else if (w->navigatorPointerRoute && e.type == SDL_MOUSEBUTTONDOWN &&
                   (e.button.button == SDL_BUTTON_LEFT || e.button.button == SDL_BUTTON_RIGHT) &&
                   !w->terminalButtons && !w->navigatorTracking &&
                   navigator_contains(w, out, e.button.x, e.button.y)) {
            if (e.button.button == SDL_BUTTON_LEFT) {
                if (w->sidebarWidth) tw_workspace_focus(w, 1);
                w->navigatorTracking = 1;
                SDL_CaptureMouse(SDL_TRUE);
            }
            w->navigatorHovered = 1;
            out->kind = 27;
            out->action = e.button.button == SDL_BUTTON_LEFT ? 1 : 5;
            out->key = e.button.button == SDL_BUTTON_LEFT ? 0 : 2;
            out->x = e.button.x; out->y = e.button.y;
            out->modifiers = tw_modifiers(SDL_GetModState());
        } else if (w->navigatorPointerRoute && w->navigatorTracking &&
                   e.type == SDL_MOUSEBUTTONDOWN) {
            continue;
        } else if (w->navigatorPointerRoute && w->terminalButtons &&
                   e.type == SDL_MOUSEBUTTONDOWN && e.button.x < w->sidebarWidth) {
            // A terminal press remains terminal-owned until its release. A second button
            // pressed over the sidebar must not focus it or start a navigator gesture.
            continue;
        } else if (!w->navigatorPointerRoute && w->actionsTracking && e.type == SDL_MOUSEBUTTONUP && e.button.button == SDL_BUTTON_LEFT) {
            // Header gestures are button-owned through release, including a release outside.
            const int activate = w->actionsEnabled && actions_contains(w, e.button.x, e.button.y);
            w->actionsTracking = 0;
            SDL_CaptureMouse(SDL_FALSE);
            if (activate) actions_activate(w, out);
            else { w->actionsState = 0; out->kind = 26; out->action = 0; }
        } else if (!w->navigatorPointerRoute && !w->terminalButtons && w->actionsVisible &&
                   (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) &&
                   actions_contains(w, e.button.x, e.button.y)) {
            if (e.button.button != SDL_BUTTON_LEFT || e.type != SDL_MOUSEBUTTONDOWN || !w->actionsEnabled) continue;
            w->actionsTracking = 1; w->actionsState = 2;
            SDL_CaptureMouse(SDL_TRUE);
            out->kind = 26; out->action = 2;
        } else if (!w->navigatorPointerRoute && !w->terminalButtons && w->actionsVisible && e.type == SDL_MOUSEMOTION &&
                   (actions_contains(w, e.motion.x, e.motion.y) || w->actionsState || w->actionsTracking)) {
            const int state = w->actionsEnabled && actions_contains(w, e.motion.x, e.motion.y)
                ? (w->actionsTracking ? 2 : 1) : 0;
            if (state == w->actionsState) continue;
            w->actionsState = state; out->kind = 26; out->action = state;
        } else if (w->actionsVisible && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) &&
                   e.key.keysym.sym == SDLK_SPACE && (e.key.keysym.mod & KMOD_CTRL) &&
                   (e.key.keysym.mod & KMOD_SHIFT)) {
            if (e.type != SDL_KEYDOWN || e.key.repeat) continue;
            w->suppressActivation = SDLK_SPACE;
            if (e.key.keysym.scancode >= 0 && e.key.keysym.scancode < SDL_NUM_SCANCODES)
                w->suppressedKeyups[e.key.keysym.scancode] = 1;
            if (!w->actionsEnabled) continue;
            actions_activate(w, out);
        } else if (!w->terminal && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) &&
                   ((e.key.keysym.sym == SDLK_F10 && (e.key.keysym.mod & KMOD_SHIFT)) ||
                    e.key.keysym.sym == SDLK_APPLICATION)) {
            // Keyboard access cannot depend on an AT-SPI bus. The host owns the selected
            // project and validates whether Actions are available for that selection.
            if (e.type != SDL_KEYDOWN || e.key.repeat) continue;
            out->kind = 29; out->action = 1;
        } else if (e.type == SDL_QUIT) out->kind = 5;
        else if (e.type == tw_accessibility_event_type()) {
            const int current = tw_accessibility_event_is_current((uint32_t)(uintptr_t)e.user.data2);
            tw_navigation_trace_dequeue(&e, current);
            if (!current) continue;
            if (e.user.code == 1) {
                if (!tw_accessibility_row_center((int)(intptr_t)e.user.data1, &out->x, &out->y)) continue;
                if (w->sidebarWidth) tw_workspace_focus(w, 1);
                out->kind = 2;
                out->action = 1; // Accessibility selection precedes a separate open action.
            } else if (e.user.code == 2) {
                if (!tw_accessibility_row_can_open((int)(intptr_t)e.user.data1)) continue;
                out->kind = 8;
            } else if (e.user.code == 3 && w->actionsVisible && w->actionsEnabled) actions_activate(w, out);
            else if (e.user.code == 4) {
                const int row = (int)(intptr_t)e.user.data1;
                if (!tw_accessibility_project_action_identity(row, out->text, sizeof(out->text))) continue;
                out->kind = 28; out->key = row; out->action = 1;
            } else if (e.user.code == 5) out->kind = 30;
            else if (e.user.code == 6) {
                const int row = (int)(intptr_t)e.user.data1;
                if (!tw_accessibility_project_create_identity(row, out->text, sizeof(out->text))) continue;
                out->kind = 33; out->key = row; out->action = 1;
            }
        }
        else if (e.type == SDL_WINDOWEVENT) {
            if (e.window.event == SDL_WINDOWEVENT_CLOSE) out->kind = 5;
            else if (e.window.event == SDL_WINDOWEVENT_EXPOSED || e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) out->kind = 1;
            else if (e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED || e.window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
                tw_accessibility_window_focus(w, e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED);
                if (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST && w->navigatorPointerRoute &&
                    (w->navigatorTracking || w->navigatorHovered)) {
                    if (w->navigatorTracking) {
                        SDL_CaptureMouse(SDL_FALSE);
                        w->navigatorSuppressLeftUp = 1;
                    }
                    w->navigatorTracking = w->navigatorHovered = 0;
                    out->kind = 27; out->action = 4; out->key = 0;
                } else if (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST && (w->actionsTracking || w->actionsState)) {
                    w->actionsTracking = 0; w->actionsState = 0;
                    SDL_CaptureMouse(SDL_FALSE);
                    out->kind = 26; out->action = 0;
                }
            } else if (e.window.event == SDL_WINDOWEVENT_LEAVE && w->navigatorPointerRoute &&
                       w->navigatorHovered && !w->navigatorTracking) {
                w->navigatorHovered = 0;
                out->kind = 27; out->action = 4; out->key = 0;
            } else if (e.window.event == SDL_WINDOWEVENT_LEAVE && w->actionsState) {
                w->actionsState = 0; out->kind = 26; out->action = 0;
            }
        } else if (w->sidebarWidth && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) &&
                   ((e.key.keysym.sym == SDLK_p && (e.key.keysym.mod & KMOD_CTRL) &&
                     (e.key.keysym.mod & KMOD_SHIFT)) ||
                    (!w->terminal && e.key.keysym.sym == SDLK_TAB))) {
            if (e.type != SDL_KEYDOWN || e.key.repeat) continue;
            const int sidebar = e.key.keysym.sym == SDLK_p;
            tw_workspace_focus(w, sidebar);
            w->suppressActivation = e.key.keysym.sym;
            if (e.key.keysym.scancode >= 0 && e.key.keysym.scancode < SDL_NUM_SCANCODES)
                w->suppressedKeyups[e.key.keysym.scancode] = 1;
            out->kind = 24; out->action = sidebar;
        } else if (w->sidebarWidth && (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP)) {
            if (e.button.button == SDL_BUTTON_LEFT) out->key = 0;
            else if (e.button.button == SDL_BUTTON_MIDDLE) out->key = 1;
            else if (e.button.button == SDL_BUTTON_RIGHT) out->key = 2;
            else continue;
            const uint32_t button = SDL_BUTTON(e.button.button);
            if (e.type == SDL_MOUSEBUTTONDOWN && e.button.x < w->sidebarWidth) {
                // Unsupported sidebar buttons have no navigation action or focus transition.
                // Changing only native focus here would leave the workspace owner out of sync.
                if (e.button.button != SDL_BUTTON_LEFT) continue;
                tw_workspace_focus(w, 1);
                out->kind = 2; out->x = e.button.x; out->y = e.button.y;
            } else if (e.type == SDL_MOUSEBUTTONDOWN || (w->terminalButtons & button)) {
                if (e.type == SDL_MOUSEBUTTONDOWN) {
                    tw_workspace_focus(w, 0);
                    w->terminalButtons |= button;
                } else w->terminalButtons &= ~button;
                out->kind = 15;
                out->x = e.button.x < w->sidebarWidth ? 0 : e.button.x - w->sidebarWidth;
                out->y = e.button.y;
                out->action = e.type == SDL_MOUSEBUTTONUP ? 3 : 1;
                out->modifiers = tw_modifiers(SDL_GetModState());
            }
        } else if (w->sidebarWidth && e.type == SDL_MOUSEMOTION) {
            if (!(w->terminalButtons & SDL_BUTTON_LMASK)) continue;
            out->kind = 17;
            out->x = e.motion.x < w->sidebarWidth ? 0 : e.motion.x - w->sidebarWidth;
            out->y = e.motion.y;
        } else if (w->sidebarWidth && e.type == SDL_MOUSEWHEEL && e.wheel.y != 0) {
            int y = e.wheel.y;
            if (e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED) y = y == INT_MIN ? INT_MAX : -y;
            SDL_GetMouseState(&out->x, &out->y);
            if (out->x < w->sidebarWidth) { out->kind = y > 0 ? 3 : 4; out->action = 1; }
            else {
                out->kind = 16; out->key = y > 8 ? 8 : (y < -8 ? -8 : y);
                out->x -= w->sidebarWidth;
                out->modifiers = tw_modifiers(SDL_GetModState());
            }
        } else if (w->terminal && (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP)) {
            if (e.button.button == SDL_BUTTON_LEFT) out->key = 0;
            else if (e.button.button == SDL_BUTTON_MIDDLE) out->key = 1;
            else if (e.button.button == SDL_BUTTON_RIGHT) out->key = 2;
            else continue;
            out->kind = 15; out->x = e.button.x; out->y = e.button.y;
            out->action = e.type == SDL_MOUSEBUTTONUP ? 3 : 1;
            out->modifiers = tw_modifiers(SDL_GetModState());
        } else if (w->terminal && e.type == SDL_MOUSEMOTION && (e.motion.state & SDL_BUTTON_LMASK)) {
            out->kind = 17; out->x = e.motion.x; out->y = e.motion.y;
        } else if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT) {
            out->kind = 2; out->x = e.button.x; out->y = e.button.y;
        } else if (e.type == SDL_MOUSEWHEEL && e.wheel.y != 0) {
            int y = e.wheel.y;
            if (e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED) y = y == INT_MIN ? INT_MAX : -y;
            if (w->terminal) {
                out->kind = 16; out->key = y > 8 ? 8 : (y < -8 ? -8 : y);
                SDL_GetMouseState(&out->x, &out->y);
                out->modifiers = tw_modifiers(SDL_GetModState());
            } else { out->kind = y > 0 ? 3 : 4; out->action = 1; }
        } else if (w->suppressActivation && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP)
                   && e.key.keysym.sym == w->suppressActivation) {
            if (e.type == SDL_KEYUP) w->suppressActivation = 0;
        } else if (w->terminal && e.type == SDL_TEXTEDITING) {
            out->kind = 19;
            memcpy(out->text, e.edit.text, sizeof(e.edit.text));
            out->text[sizeof(e.edit.text) - 1] = 0;
            out->textCursor = e.edit.start;
            out->textSelectionLength = e.edit.length;
            w->composing = out->text[0] != 0;
        } else if (w->terminal && e.type == SDL_TEXTEDITING_EXT) {
            const size_t length = strnlen(e.editExt.text, sizeof(out->text));
            out->kind = 19;
            if (length == sizeof(out->text)) {
                // This is visible as an explicit preview refusal. Committed input still arrives
                // through the complete TEXTINPUT stream, never as a truncated prefix here.
                strcpy(out->text, "[composition exceeds 1 KiB]");
                out->textCursor = 0;
                out->textSelectionLength = 0;
            } else {
                memcpy(out->text, e.editExt.text, length + 1);
                out->textCursor = e.editExt.start;
                out->textSelectionLength = e.editExt.length;
            }
            w->composing = out->text[0] != 0;
            SDL_free(e.editExt.text);
        } else if (w->terminal && w->suppressActivation
                   && e.type == SDL_TEXTINPUT) {
            // A shortcut must not also type its printable key into the PTY.
        } else if (w->terminal && e.type == SDL_TEXTINPUT) {
            out->kind = 6;
            out->action = w->composing ? 1 : 0;
            w->composing = 0;
            memcpy(out->text, e.text.text, sizeof(e.text.text));
            out->text[sizeof(e.text.text) - 1] = 0;
        } else if (w->terminal && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP)
                   && (w->composing || (e.key.keysym.scancode >= 0 && e.key.keysym.scancode < SDL_NUM_SCANCODES
                                         && w->suppressedKeyups[e.key.keysym.scancode]))) {
            // Enter, Backspace and arrows are IME editing gestures until commit/cancel. Their
            // keyup must stay suppressed even if an empty EDIT or INPUT ended composition first.
            if (e.key.keysym.scancode >= 0 && e.key.keysym.scancode < SDL_NUM_SCANCODES) {
                w->suppressedKeyups[e.key.keysym.scancode] = e.type == SDL_KEYDOWN;
            }
        } else if (w->terminal && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP)) {
            if (e.key.keysym.sym == SDLK_v && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT)) {
                if (e.type == SDL_KEYDOWN && !e.key.repeat) {
                    out->kind = 14; w->suppressActivation = SDLK_v; return 1;
                }
                continue;
            }
            if (e.key.keysym.sym == SDLK_c && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT)) {
                if (e.type == SDL_KEYDOWN && !e.key.repeat) {
                    out->kind = 18; w->suppressActivation = SDLK_c; return 1;
                }
                continue;
            }
            if (w->projectNavigation && e.key.keysym.sym == SDLK_p
                && (e.key.keysym.mod & KMOD_CTRL) && (e.key.keysym.mod & KMOD_SHIFT)) {
                if (e.type == SDL_KEYDOWN && !e.key.repeat) { out->kind = 8; return 1; }
                continue;
            }
            if ((e.key.keysym.mod & KMOD_ALT) && e.key.keysym.sym == SDLK_F4) {
                if (e.type == SDL_KEYDOWN) { out->kind = 5; return 1; }
                continue;
            }
            out->action = e.type == SDL_KEYUP ? 3 : (e.key.repeat ? 2 : 1);
            out->modifiers = tw_modifiers(e.key.keysym.mod);
            switch (e.key.keysym.sym) {
            case SDLK_ESCAPE: out->key = TW_KEY_ESCAPE; break;
            case SDLK_RETURN: case SDLK_KP_ENTER: out->key = TW_KEY_ENTER; break;
            case SDLK_TAB: out->key = TW_KEY_TAB; break;
            case SDLK_BACKSPACE: out->key = TW_KEY_BACKSPACE; break;
            case SDLK_DELETE: out->key = TW_KEY_DELETE; break;
            case SDLK_UP: out->key = TW_KEY_UP; break;
            case SDLK_DOWN: out->key = TW_KEY_DOWN; break;
            case SDLK_LEFT: out->key = TW_KEY_LEFT; break;
            case SDLK_RIGHT: out->key = TW_KEY_RIGHT; break;
            case SDLK_HOME: out->key = TW_KEY_HOME; break;
            case SDLK_END: out->key = TW_KEY_END; break;
            case SDLK_PAGEUP: out->key = TW_KEY_PAGE_UP; break;
            case SDLK_PAGEDOWN: out->key = TW_KEY_PAGE_DOWN; break;
            case SDLK_F1: out->key = TW_KEY_F1; break;
            case SDLK_F2: out->key = TW_KEY_F2; break;
            case SDLK_F3: out->key = TW_KEY_F3; break;
            case SDLK_F4: out->key = TW_KEY_F4; break;
            case SDLK_F5: out->key = TW_KEY_F5; break;
            case SDLK_F6: out->key = TW_KEY_F6; break;
            case SDLK_F7: out->key = TW_KEY_F7; break;
            case SDLK_F8: out->key = TW_KEY_F8; break;
            case SDLK_F9: out->key = TW_KEY_F9; break;
            case SDLK_F10: out->key = TW_KEY_F10; break;
            case SDLK_F11: out->key = TW_KEY_F11; break;
            case SDLK_F12: out->key = TW_KEY_F12; break;
            default: break;
            }
            if (out->key) out->kind = 7;
            else if (e.type == SDL_KEYDOWN && (e.key.keysym.mod & KMOD_CTRL)
                     && e.key.keysym.sym >= SDLK_a && e.key.keysym.sym <= SDLK_z) {
                out->text[0] = (char)(e.key.keysym.sym - SDLK_a + 1); out->kind = 6;
            }
        } else if (e.type == SDL_KEYDOWN) {
            if ((e.key.keysym.mod & KMOD_ALT) && e.key.keysym.sym == SDLK_F4) {
                out->kind = 5;
            }
            else if (e.key.keysym.sym == SDLK_n && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT) && !e.key.repeat) {
                out->kind = 9; w->suppressActivation = SDLK_n;
            }
            else if (e.key.keysym.sym == SDLK_a && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT) && !e.key.repeat) {
                out->kind = 13; w->suppressActivation = SDLK_a;
            }
            else if (e.key.keysym.sym == SDLK_l && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT) && !e.key.repeat) {
                out->kind = 21; w->suppressActivation = SDLK_l;
            }
            else if (e.key.keysym.sym == SDLK_i && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT) && !e.key.repeat) {
                out->kind = 20; w->suppressActivation = SDLK_i;
            }
            else if (e.key.keysym.sym == SDLK_o && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT) && !e.key.repeat) {
                out->kind = 22; w->suppressActivation = SDLK_o;
            }
            else if (e.key.keysym.sym == SDLK_p && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT) && !e.key.repeat) {
                out->kind = 23; w->suppressActivation = SDLK_p;
            }
            else if (e.key.keysym.sym == SDLK_UP) out->kind = 3;
            else if (e.key.keysym.sym == SDLK_DOWN) out->kind = 4;
            else if (e.key.keysym.sym == SDLK_RIGHT) out->kind = 10;
            else if (e.key.keysym.sym == SDLK_LEFT) out->kind = 11;
            else if (e.key.keysym.sym == SDLK_ESCAPE) out->kind = 12;
            else if (e.key.keysym.sym == SDLK_RETURN && !e.key.repeat) { out->kind = 8; w->suppressActivation = SDLK_RETURN; }
        }
        if (out->kind) return 1;
    }
}
#endif
