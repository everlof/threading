#include "LinuxWindowBridge.h"
#ifdef __linux__
#include <pango/pangocairo.h>
#include <stdint.h>

int tw_draw_navigator_labels(uint8_t *rgba, int width, int height,
                             const uint8_t *utf8, int byteCount,
                             const TWNavigatorLabel *labels, int labelCount) {
    if (!rgba || width < 320 || width > 1280 || height < 180 || height > 900 ||
        byteCount < 0 || byteCount > 32768 || (byteCount && !utf8) ||
        labelCount < 0 || labelCount > TW_NAVIGATOR_MAX_LABELS || (labelCount && !labels)) return -1;
    if (!labelCount) return 0;
    if (!byteCount) return -1;
    for (int index = 0; index < labelCount; index++) {
        const TWNavigatorLabel *row = &labels[index];
        if (row->x < 0 || row->y < 0 || row->width < 1 || row->width > width ||
            row->height < 1 || row->height > 64 ||
            row->inset < 0 || row->inset > 128 || row->inset >= row->width ||
            row->trailingInset < 0 || row->trailingInset > 128 ||
            row->trailingInset >= row->width - row->inset ||
            (row->detail != 0 && row->detail != 1) ||
            row->x > width - row->width || row->y > height - row->height ||
            row->offset < 0 || row->length < 1 || row->length > 1024 ||
            row->offset > byteCount - row->length || (row->selected != 0 && row->selected != 1) ||
            !g_utf8_validate((const char *)utf8 + row->offset, row->length, NULL)) return -1;
    }

    // A single small surface is reused for each mounted row. No frame-sized second buffer,
    // persistent glyph cache or offscreen list content is constructed on navigation.
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, 64);
    cairo_t *cr = cairo_create(surface);
    cairo_font_options_t *fontOptions = cairo_font_options_create();
    cairo_font_options_set_antialias(fontOptions, CAIRO_ANTIALIAS_GRAY);
    cairo_set_font_options(cr, fontOptions);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    pango_cairo_context_set_font_options(pango_layout_get_context(layout), fontOptions);
    pango_layout_context_changed(layout);
    PangoFontDescription *font = pango_font_description_from_string("DejaVu Sans");
    pango_font_description_set_absolute_size(font, 18 * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);

    for (int index = 0; index < labelCount; index++) {
        const TWNavigatorLabel *row = &labels[index];
        const int textWidth = row->width - row->inset - row->trailingInset;
        cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
        cairo_paint(cr);
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
        pango_font_description_set_absolute_size(font, (row->detail ? 14 : 18) * PANGO_SCALE);
        pango_layout_set_font_description(layout, font);
        pango_layout_set_width(layout, textWidth * PANGO_SCALE);
        pango_layout_set_text(layout, (const char *)utf8 + row->offset, row->length);
        int textHeight;
        pango_layout_get_pixel_size(layout, NULL, &textHeight);
        cairo_save(cr);
        cairo_rectangle(cr, 0, 0, textWidth, row->height);
        cairo_clip(cr);
        if (row->selected) cairo_set_source_rgb(cr, 1, 1, 1);
        else if (row->detail) cairo_set_source_rgb(cr, 0.3, 0.3, 0.3);
        else cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);
        cairo_move_to(cr, 0, (row->height - textHeight) / 2);
        pango_cairo_show_layout(cr, layout);
        cairo_restore(cr);
        cairo_surface_flush(surface);

        const uint8_t *source = cairo_image_surface_get_data(surface);
        const int stride = cairo_image_surface_get_stride(surface);
        for (int y = 0; y < row->height; y++) {
            const uint32_t *sourceRow = (const uint32_t *)(source + y * stride);
            for (int x = 0; x < textWidth; x++) {
                const uint32_t pixel = sourceRow[x];
                const int alpha = (pixel >> 24) & 255;
                if (!alpha) continue;
                const int target = ((row->y + y) * width + row->x + row->inset + x) * 4;
                const int retained = 255 - alpha;
                rgba[target] = (uint8_t)(((pixel >> 16) & 255) +
                                         (rgba[target] * retained + 127) / 255);
                rgba[target + 1] = (uint8_t)(((pixel >> 8) & 255) +
                                             (rgba[target + 1] * retained + 127) / 255);
                rgba[target + 2] = (uint8_t)((pixel & 255) +
                                             (rgba[target + 2] * retained + 127) / 255);
            }
        }
    }

    const int ok = cairo_status(cr) == CAIRO_STATUS_SUCCESS &&
        cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS;
    pango_font_description_free(font);
    g_object_unref(layout);
    cairo_font_options_destroy(fontOptions);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return ok ? 0 : -1;
}
#endif
