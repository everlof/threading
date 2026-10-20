#include "LinuxWindowBridge.h"

#ifdef __linux__
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

enum { ATTACHMENT_MAX_INPUT = 32 * 1024 * 1024, ATTACHMENT_MAX_SOURCE_EDGE = 8192,
       ATTACHMENT_MAX_SOURCE_PIXELS = 40 * 1024 * 1024, ATTACHMENT_MAX_OUTPUT_EDGE = 128 };

typedef struct { gboolean refused; } AttachmentLoad;

static void attachment_size_prepared(GdkPixbufLoader *loader, int width, int height,
                                     void *context) {
    AttachmentLoad *load = context;
    if (width <= 0 || height <= 0 || width > ATTACHMENT_MAX_SOURCE_EDGE ||
        height > ATTACHMENT_MAX_SOURCE_EDGE ||
        (int64_t)width * height > ATTACHMENT_MAX_SOURCE_PIXELS) {
        load->refused = TRUE;
        return;
    }
    const double scale = fmin(1.0, fmin((double)ATTACHMENT_MAX_OUTPUT_EDGE / width,
                                      (double)ATTACHMENT_MAX_OUTPUT_EDGE / height));
    gdk_pixbuf_loader_set_size(loader, fmax(1, (int)lround(width * scale)),
                               fmax(1, (int)lround(height * scale)));
}

static void tiff_size_prepared(GdkPixbufLoader *loader, int width, int height,
                               void *context) {
    (void)loader;
    AttachmentLoad *load = context;
    if (width <= 0 || height <= 0 || width > ATTACHMENT_MAX_SOURCE_EDGE ||
        height > ATTACHMENT_MAX_SOURCE_EDGE ||
        (int64_t)width * height > ATTACHMENT_MAX_SOURCE_PIXELS) load->refused = TRUE;
}

typedef struct { GByteArray *bytes; } PNGOutput;

static gboolean write_png_chunk(const gchar *buffer, gsize count, GError **error,
                                gpointer context) {
    PNGOutput *output = context;
    if (count > ATTACHMENT_MAX_INPUT - output->bytes->len) {
        g_set_error_literal(error, GDK_PIXBUF_ERROR, GDK_PIXBUF_ERROR_INSUFFICIENT_MEMORY,
                            "Encoded PNG exceeds the attachment limit");
        return FALSE;
    }
    g_byte_array_append(output->bytes, (const guint8 *)buffer, (guint)count);
    return TRUE;
}

int tw_attachment_tiff_to_png(const uint8_t *tiff, int length,
                              uint8_t **png, int *pngLength) {
    if (!tiff || length < 4 || length > ATTACHMENT_MAX_INPUT || !png || !pngLength)
        return -1;
    *png = NULL;
    *pngLength = 0;
    GError *error = NULL;
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new_with_type("tiff", &error);
    if (!loader) { g_clear_error(&error); return -1; }
    AttachmentLoad load = {FALSE};
    g_signal_connect(loader, "size-prepared", G_CALLBACK(tiff_size_prepared), &load);
    gboolean valid = TRUE;
    for (int offset = 0; valid && !load.refused && offset < length; offset += 4096) {
        const int count = MIN(4096, length - offset);
        valid = gdk_pixbuf_loader_write(loader, tiff + offset, (gsize)count, &error);
    }
    if (valid && !load.refused) valid = gdk_pixbuf_loader_close(loader, &error);
    GdkPixbuf *image = valid && !load.refused ? gdk_pixbuf_loader_get_pixbuf(loader) : NULL;
    if (!image) { g_clear_error(&error); g_object_unref(loader); return -1; }
    PNGOutput output = { g_byte_array_new() };
    valid = gdk_pixbuf_save_to_callback(image, write_png_chunk, &output, "png", &error, NULL);
    if (valid && output.bytes->len > 0) {
        uint8_t *result = malloc(output.bytes->len);
        if (result) {
            memcpy(result, output.bytes->data, output.bytes->len);
            *png = result;
            *pngLength = (int)output.bytes->len;
        }
    }
    g_byte_array_unref(output.bytes);
    g_clear_error(&error);
    g_object_unref(loader);
    return *png ? 0 : -1;
}

int tw_attachment_thumbnail(const char *path, uint8_t *rgba, int capacity,
                            int *width, int *height) {
    if (!path || !rgba || capacity < ATTACHMENT_MAX_OUTPUT_EDGE * ATTACHMENT_MAX_OUTPUT_EDGE * 4 ||
        !width || !height) return -1;
    FILE *file = fopen(path, "rb");
    if (!file) return -1;
    struct stat state;
    if (fstat(fileno(file), &state) != 0 || !S_ISREG(state.st_mode) ||
        state.st_size <= 0 || state.st_size > ATTACHMENT_MAX_INPUT) {
        fclose(file);
        return -1;
    }

    GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
    if (!loader) { fclose(file); return -1; }
    AttachmentLoad load = {FALSE};
    g_signal_connect(loader, "size-prepared", G_CALLBACK(attachment_size_prepared), &load);
    GError *error = NULL;
    uint8_t bytes[4096];
    size_t count;
    size_t total = 0;
    gboolean valid = TRUE;
    while (valid && !load.refused && (count = fread(bytes, 1, sizeof(bytes), file)) > 0) {
        total += count;
        if (total > ATTACHMENT_MAX_INPUT) { valid = FALSE; break; }
        valid = gdk_pixbuf_loader_write(loader, bytes, count, &error);
    }
    if (ferror(file)) valid = FALSE;
    fclose(file);
    valid = valid && !load.refused && gdk_pixbuf_loader_close(loader, &error);
    if (!valid) {
        g_clear_error(&error);
        g_object_unref(loader);
        return -1;
    }
    GdkPixbuf *image = gdk_pixbuf_loader_get_pixbuf(loader);
    if (!image || gdk_pixbuf_get_bits_per_sample(image) != 8 ||
        gdk_pixbuf_get_n_channels(image) < 3 || gdk_pixbuf_get_n_channels(image) > 4) {
        g_object_unref(loader);
        return -1;
    }
    const int w = gdk_pixbuf_get_width(image), h = gdk_pixbuf_get_height(image);
    if (w <= 0 || h <= 0 || w > ATTACHMENT_MAX_OUTPUT_EDGE || h > ATTACHMENT_MAX_OUTPUT_EDGE) {
        g_object_unref(loader);
        return -1;
    }
    const int channels = gdk_pixbuf_get_n_channels(image);
    const int stride = gdk_pixbuf_get_rowstride(image);
    const uint8_t *pixels = gdk_pixbuf_read_pixels(image);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const uint8_t *source = pixels + y * stride + x * channels;
            uint8_t *target = rgba + (y * w + x) * 4;
            target[0] = source[0];
            target[1] = source[1];
            target[2] = source[2];
            target[3] = channels == 4 ? source[3] : 255;
        }
    }
    g_object_unref(loader);
    *width = w;
    *height = h;
    return 0;
}
#endif
