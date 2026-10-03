// Test-only SDL renderer readback for the installed headless-Wayland smoke.
// The headless compositor has no screenshot hotkey; the separate test module
// supplies a synthetic seat when pointer and keyboard delivery are exercised.
#define _GNU_SOURCE
#include <SDL2/SDL.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void SDL_RenderPresent(SDL_Renderer *renderer) {
    static void (*present)(SDL_Renderer *);
    static char captured[16];
    if (!present) present = dlsym(RTLD_NEXT, "SDL_RenderPresent");

    const char *directory = getenv("THREADING_WAYLAND_CAPTURE_DIR");
    if (directory) {
        char trigger[512], requested[16] = {0};
        snprintf(trigger, sizeof(trigger), "%s/trigger", directory);
        FILE *source = fopen(trigger, "r");
        if (source) {
            if (!fgets(requested, sizeof(requested), source)) requested[0] = 0;
            fclose(source);
            requested[strcspn(requested, "\r\n")] = 0;
        }
        if ((strcmp(requested, "normal") == 0 || strcmp(requested, "alternate") == 0
             || strcmp(requested, "open") == 0 || strcmp(requested, "idle") == 0
             || strcmp(requested, "dark-idle") == 0
             || strcmp(requested, "light-idle") == 0
             || strcmp(requested, "terminal") == 0
             || strcmp(requested, "other-selected") == 0
             || strcmp(requested, "title-reveal") == 0)
            && strcmp(requested, captured) != 0) {
            int width = 0, height = 0;
            if (SDL_GetRendererOutputSize(renderer, &width, &height) == 0
                && width > 0 && height > 0 && width <= 1600 && height <= 900) {
                void *pixels = malloc((size_t)width * height * 4);
                if (pixels && SDL_RenderReadPixels(renderer, NULL, SDL_PIXELFORMAT_ARGB8888,
                                                   pixels, width * 4) == 0) {
                    SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormatFrom(
                        pixels, width, height, 32, width * 4, SDL_PIXELFORMAT_ARGB8888);
                    if (surface) {
                        char path[512], temporary[512];
                        snprintf(path, sizeof(path), "%s/%s.bmp", directory, requested);
                        snprintf(temporary, sizeof(temporary), "%s/%s.tmp", directory, requested);
                        if (SDL_SaveBMP(surface, temporary) == 0 && rename(temporary, path) == 0) {
                            strcpy(captured, requested);
                            fprintf(stderr, "WAYLAND_CAPTURE state=%s width=%d height=%d\n",
                                    requested, width, height);
                        }
                        SDL_FreeSurface(surface);
                    }
                }
                free(pixels);
            }
        }
    }
    present(renderer);
}
