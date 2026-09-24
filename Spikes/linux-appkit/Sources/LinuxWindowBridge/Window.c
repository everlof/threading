#include "LinuxWindowBridge.h"
#ifdef __linux__
#include <SDL2/SDL.h>
#include <stdlib.h>
#include <string.h>
struct TWWindow { SDL_Window *window; SDL_Renderer *renderer; SDL_Texture *texture; int width, height, terminal, projectNavigation, suppressActivation, explicitSurfaceUpdate; };
const char *tw_error(void) { return SDL_GetError(); }
void tw_close(TWWindow *w) {
    if (!w) return;
    SDL_DestroyTexture(w->texture);
    SDL_DestroyRenderer(w->renderer);
    SDL_DestroyWindow(w->window);
    free(w);
    SDL_Quit();
}
TWWindow *tw_open(const char *title, int width, int height) {
    if (SDL_Init(SDL_INIT_VIDEO) != 0) return NULL;
    TWWindow *w = calloc(1, sizeof(*w));
    if (!w) { SDL_Quit(); return NULL; }
    w->window = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                width, height, SDL_WINDOW_RESIZABLE);
    if (!w->window) { tw_close(w); return NULL; }
    // Explicit experiment bounds keep the software rasterizer's allocation/work bounded.
    SDL_SetWindowMinimumSize(w->window, 320, 180);
    SDL_SetWindowMaximumSize(w->window, 1280, 900);
    w->renderer = SDL_CreateRenderer(w->window, -1, SDL_RENDERER_SOFTWARE);
    if (!w->renderer) { tw_close(w); return NULL; }
    return w;
}
int tw_present(TWWindow *w, const uint8_t *rgba, int width, int height) {
    if (width < 1 || width > 1280 || height < 1 || height > 900) return -1;
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
    if (!w->texture) return 0;
    if (SDL_RenderClear(w->renderer) != 0 || SDL_RenderCopy(w->renderer, w->texture, NULL, NULL) != 0) return -1;
    SDL_RenderPresent(w->renderer);
    return !w->explicitSurfaceUpdate || SDL_UpdateWindowSurface(w->window) == 0 ? 0 : -1;
}
void tw_title(TWWindow *w, const char *title) { SDL_SetWindowTitle(w->window, title); }
int tw_resize(TWWindow *w, int width, int height) {
    int oldWidth, oldHeight;
    SDL_GetWindowSize(w->window, &oldWidth, &oldHeight);
    if (oldWidth == width && oldHeight == height) return 0;
    SDL_SetWindowSize(w->window, width, height);
    w->explicitSurfaceUpdate = 1;
    return 0;
}
void tw_terminal_mode(TWWindow *w) { w->terminal = 1; SDL_StartTextInput(); }
void tw_project_navigation(TWWindow *w, int enabled) { w->projectNavigation = enabled; }
void tw_project_mode(TWWindow *w) { w->terminal = 0; SDL_StopTextInput(); }
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
int tw_next(TWWindow *w, TWEvent *out) { return tw_next_timeout(w, out, -1); }
int tw_next_timeout(TWWindow *w, TWEvent *out, int milliseconds) {
    SDL_Event e;
    while (SDL_WaitEventTimeout(&e, milliseconds)) {
        *out = (TWEvent){0};
        SDL_GetWindowSize(w->window, &out->width, &out->height);
        if (e.type == SDL_QUIT) out->kind = 5;
        else if (e.type == SDL_WINDOWEVENT) {
            if (e.window.event == SDL_WINDOWEVENT_CLOSE) out->kind = 5;
            else if (e.window.event == SDL_WINDOWEVENT_EXPOSED || e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) out->kind = 1;
        } else if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT) {
            out->kind = 2; out->x = e.button.x; out->y = e.button.y;
        } else if (e.type == SDL_MOUSEWHEEL && e.wheel.y != 0) {
            int y = e.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -e.wheel.y : e.wheel.y;
            out->kind = y > 0 ? 3 : 4;
        } else if (w->suppressActivation && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP)
                   && e.key.keysym.sym == w->suppressActivation) {
            if (e.type == SDL_KEYUP) w->suppressActivation = 0;
        } else if (w->terminal && w->suppressActivation == SDLK_v && e.type == SDL_TEXTINPUT) {
            // A shortcut must not also type its printable key into the PTY.
        } else if (w->terminal && e.type == SDL_TEXTINPUT) {
            out->kind = 6; memcpy(out->text, e.text.text, sizeof(out->text));
        } else if (w->terminal && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP)) {
            if (e.key.keysym.sym == SDLK_v && (e.key.keysym.mod & KMOD_CTRL)
                && (e.key.keysym.mod & KMOD_SHIFT)) {
                if (e.type == SDL_KEYDOWN && !e.key.repeat) {
                    out->kind = 14; w->suppressActivation = SDLK_v; return 1;
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
            out->modifiers = ((e.key.keysym.mod & KMOD_SHIFT) ? 1 : 0)
                | ((e.key.keysym.mod & KMOD_ALT) ? 2 : 0)
                | ((e.key.keysym.mod & KMOD_CTRL) ? 4 : 0)
                | ((e.key.keysym.mod & KMOD_GUI) ? 8 : 0)
                | ((e.key.keysym.mod & KMOD_CAPS) ? 16 : 0)
                | ((e.key.keysym.mod & KMOD_NUM) ? 32 : 0);
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
            else if (e.key.keysym.sym == SDLK_UP) out->kind = 3;
            else if (e.key.keysym.sym == SDLK_DOWN) out->kind = 4;
            else if (e.key.keysym.sym == SDLK_RIGHT) out->kind = 10;
            else if (e.key.keysym.sym == SDLK_LEFT) out->kind = 11;
            else if (e.key.keysym.sym == SDLK_ESCAPE) out->kind = 12;
            else if (e.key.keysym.sym == SDLK_RETURN && !e.key.repeat) { out->kind = 8; w->suppressActivation = SDLK_RETURN; }
        }
        if (out->kind) return 1;
        if (milliseconds >= 0) return 0;
    }
    return 0;
}
#endif
