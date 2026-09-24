#include "LinuxWindowBridge.h"
#ifdef __linux__
#include <pango/pangocairo.h>
#include <string.h>
#include <stdlib.h>
static void color(cairo_t *cr, uint32_t rgb) {
    cairo_set_source_rgb(cr, ((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0);
}
int tw_render_terminal(uint8_t *rgba, int width, int height, const TWCell *cells, int columns, int rows,
                       const char *text, int textLength, int cursorColumn, int cursorRow) {
    if (width < 1 || width > 1280 || height < 1 || height > 900 || columns < 2 || columns > 240 || rows < 1 || rows > 100) return -1;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    cairo_t *cr = cairo_create(surface);
    color(cr, 0x17191d); cairo_paint(cr);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("DejaVu Sans Mono");
    pango_font_description_set_absolute_size(font, 16 * PANGO_SCALE);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    // The fixed diagnostic font has 95 printable ASCII characters and two weights. Keep
    // their shaped layouts only for this frame; Unicode continues through the original Pango
    // path, including color-font rendering. The cache has no externally sized keys or growth.
    PangoLayout *ascii[2][95] = {{0}};
    const char *reference = getenv("THREADING_TERMINAL_REFERENCE_RENDERER");
    int cacheEnabled = !reference || strcmp(reference, "1") != 0;
    int result = 0;
    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < columns; col++) {
            const TWCell *cell = &cells[row * columns + col];
            if (cell->offset < 0 || cell->length < 0 || cell->offset > textLength - cell->length) { result = -1; goto done; }
            int x = col * 10, y = row * 22;
            color(cr, cell->background); cairo_rectangle(cr, x, y, 10, 22); cairo_fill(cr);
        }
        for (int col = 0; col < columns; col++) {
            const TWCell *cell = &cells[row * columns + col];
            if (!cell->width || !cell->length || (cell->length == 1 && text[cell->offset] == ' ')) continue;
            int x = col * 10, y = row * 22;
            cairo_save(cr);
            cairo_rectangle(cr, x, y, cell->width * 10, 22); cairo_clip(cr);
            PangoLayout *shaped = layout;
            unsigned char character = (unsigned char)text[cell->offset];
            if (cacheEnabled && cell->length == 1 && cell->width == 1 && character >= 32 && character <= 126) {
                PangoLayout **cached = &ascii[cell->bold != 0][character - 32];
                if (!*cached) {
                    *cached = pango_cairo_create_layout(cr);
                    pango_layout_set_single_paragraph_mode(*cached, TRUE);
                    pango_font_description_set_weight(font, cell->bold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
                    pango_layout_set_font_description(*cached, font);
                    pango_layout_set_text(*cached, text + cell->offset, cell->length);
                }
                shaped = *cached;
            } else {
                pango_font_description_set_weight(font, cell->bold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
                pango_layout_set_font_description(layout, font);
                pango_layout_set_text(layout, text + cell->offset, cell->length);
            }
            color(cr, cell->foreground); cairo_move_to(cr, x, y);
            pango_cairo_show_layout(cr, shaped);
            if (cell->underline) { cairo_rectangle(cr, x, y + 20, cell->width * 10, 1); cairo_fill(cr); }
            cairo_restore(cr);
        }
    }
    if (cursorColumn >= 0 && cursorColumn < columns && cursorRow >= 0 && cursorRow < rows) {
        color(cr, 0xd4d4d4); cairo_rectangle(cr, cursorColumn * 10, cursorRow * 22 + 20, 10, 2); cairo_fill(cr);
    }
    cairo_surface_flush(surface);
    unsigned char *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int y = 0; y < height; y++) {
        const uint32_t *source = (const uint32_t *)(pixels + y * stride);
        for (int x = 0; x < width; x++) {
            uint32_t p = source[x]; int index = (y * width + x) * 4;
            rgba[index] = (p >> 16) & 255; rgba[index + 1] = (p >> 8) & 255;
            rgba[index + 2] = p & 255; rgba[index + 3] = 255;
        }
    }
done:
    if (cairo_status(cr) != CAIRO_STATUS_SUCCESS || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) result = -1;
    for (int weight = 0; weight < 2; weight++)
        for (int ch = 0; ch < 95; ch++)
            if (ascii[weight][ch]) g_object_unref(ascii[weight][ch]);
    pango_font_description_free(font); g_object_unref(layout); cairo_destroy(cr); cairo_surface_destroy(surface);
    return result;
}
#endif
