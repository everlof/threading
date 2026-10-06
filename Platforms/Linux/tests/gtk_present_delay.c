// Test-only delay for the first GTK window presentation in each chooser process. Keep the
// real zenity PID, dialogs and input while exposing handshake/visible-window coupling.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>

static void delay_presentation(void) {
    static int delayed;
    const char *value = getenv("THREADING_GTK_PRESENT_DELAY_MS");
    if (!delayed && value) {
        delayed = 1;
        char *end;
        const long milliseconds = strtol(value, &end, 10);
        if (*end == '\0' && milliseconds > 0 && milliseconds <= 4000) {
            const char *trace = getenv("THREADING_GTK_PRESENT_TRACE");
            FILE *file = trace ? fopen(trace, "a") : NULL;
            if (file) { fprintf(file, "pid=%ld delayMs=%ld\n", (long)getpid(), milliseconds); fclose(file); }
            struct timespec remaining = {milliseconds / 1000, milliseconds % 1000 * 1000000};
            while (nanosleep(&remaining, &remaining) != 0) { }
        }
    }
}

void gtk_window_present(void *window) {
    void (*present)(void *) = dlsym(RTLD_NEXT, "gtk_window_present");
    if (!present) abort();
    delay_presentation();
    present(window);
}

void gtk_native_dialog_show(void *dialog) {
    void (*show)(void *) = dlsym(RTLD_NEXT, "gtk_native_dialog_show");
    if (!show) abort();
    delay_presentation();
    show(dialog);
}
