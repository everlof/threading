#include "LinuxWindowBridge.h"
#ifdef __linux__
#include <cairo.h>
#include <string.h>

typedef struct { const uint8_t *bytes; int count, offset; } PNGInput;
static cairo_status_t read_png(void *closure, unsigned char *data, unsigned int length) {
    PNGInput *input = closure;
    if (length > (unsigned int)(input->count - input->offset)) return CAIRO_STATUS_READ_ERROR;
    memcpy(data, input->bytes + input->offset, length);
    input->offset += (int)length;
    return CAIRO_STATUS_SUCCESS;
}
static uint32_t big_endian(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | bytes[3];
}

int tw_decode_provider_png(const uint8_t *png, int length, uint8_t *rgba, int capacity,
                           int *width, int *height) {
    // This leaf admits fixed app-owned marks, not arbitrary user imagery. Check IHDR before
    // Cairo/libpng can allocate from it. Compressed input and output have independent budgets.
    static const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (!png || !rgba || !width || !height || length < 33 || length > 65536 ||
        memcmp(png, signature, 8) || big_endian(png + 8) != 13 ||
        memcmp(png + 12, "IHDR", 4)) return -1;
    const uint32_t w = big_endian(png + 16), h = big_endian(png + 20);
    if (!w || !h || w > 64 || h > 64 || capacity < (int)(w * h * 4)) return -1;
    PNGInput input = {png, length, 0};
    cairo_surface_t *surface = cairo_image_surface_create_from_png_stream(read_png, &input);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS ||
        cairo_image_surface_get_width(surface) != (int)w ||
        cairo_image_surface_get_height(surface) != (int)h) {
        cairo_surface_destroy(surface);
        return -1;
    }
    cairo_format_t format = cairo_image_surface_get_format(surface);
    if (format != CAIRO_FORMAT_ARGB32 && format != CAIRO_FORMAT_RGB24) {
        cairo_surface_destroy(surface);
        return -1;
    }
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    const int stride = cairo_image_surface_get_stride(surface);
    for (uint32_t y = 0; y < h; y++) {
        const uint32_t *row = (const uint32_t *)(pixels + y * stride);
        for (uint32_t x = 0; x < w; x++) {
            const uint32_t pixel = row[x];
            const uint32_t alpha = format == CAIRO_FORMAT_RGB24 ? 255 : pixel >> 24;
            const uint32_t offset = (y * w + x) * 4;
            // Cairo stores premultiplied native ARGB; the shim consumes straight RGBA.
            rgba[offset] = alpha ? (uint8_t)((((pixel >> 16) & 255) * 255 + alpha / 2) / alpha) : 0;
            rgba[offset + 1] = alpha ? (uint8_t)((((pixel >> 8) & 255) * 255 + alpha / 2) / alpha) : 0;
            rgba[offset + 2] = alpha ? (uint8_t)(((pixel & 255) * 255 + alpha / 2) / alpha) : 0;
            rgba[offset + 3] = (uint8_t)alpha;
        }
    }
    cairo_surface_destroy(surface);
    *width = (int)w; *height = (int)h;
    return 0;
}
#endif
