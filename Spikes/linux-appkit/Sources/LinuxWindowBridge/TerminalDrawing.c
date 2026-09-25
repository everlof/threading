#include "LinuxWindowBridge.h"
#ifdef __linux__
#include <pango/pangocairo.h>
#include <string.h>
#include <stdlib.h>
static void color(cairo_t *cr, uint32_t rgb) {
    cairo_set_source_rgb(cr, ((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0);
}
static void draw_preedit(cairo_t *cr, int width, int height, int cursorColumn, int cursorRow,
                         const char *text, int length, int cursor, int selectionLength) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("DejaVu Sans 16");
    pango_layout_set_font_description(layout, font);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    pango_layout_set_text(layout, text, length);

    const int maximumTextWidth = width - 24;
    int textWidth, textHeight;
    pango_layout_get_pixel_size(layout, &textWidth, &textHeight);
    if (textWidth > maximumTextWidth) {
        pango_layout_set_width(layout, maximumTextWidth * PANGO_SCALE);
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
        pango_layout_get_pixel_size(layout, &textWidth, &textHeight);
    }
    int popupWidth = textWidth + 12;
    if (popupWidth < 32) popupWidth = 32;
    if (popupWidth > width - 8) popupWidth = width - 8;
    int popupHeight = textHeight + 8;
    if (popupHeight < 28) popupHeight = 28;
    if (popupHeight > height - 8) popupHeight = height - 8;
    int x = cursorColumn >= 0 ? cursorColumn * TW_TERMINAL_CELL_WIDTH : 8;
    if (x > width - popupWidth - 4) x = width - popupWidth - 4;
    if (x < 4) x = 4;
    int y = cursorColumn >= 0 ? (cursorRow + 1) * TW_TERMINAL_CELL_HEIGHT : height - popupHeight - 4;
    if (y + popupHeight > height - 4) y = cursorRow * TW_TERMINAL_CELL_HEIGHT - popupHeight;
    if (y < 4) y = 4;

    PangoAttrList *attributes = pango_attr_list_new();
    PangoAttribute *underline = pango_attr_underline_new(PANGO_UNDERLINE_SINGLE);
    underline->start_index = 0;
    underline->end_index = (guint)length;
    pango_attr_list_insert(attributes, underline);
    const glong characters = g_utf8_strlen(text, length);
    if (cursor < 0) cursor = 0;
    if (cursor > characters) cursor = (int)characters;
    if (selectionLength < 0) selectionLength = 0;
    if (selectionLength > characters - cursor) selectionLength = (int)characters - cursor;
    const char *cursorByte = g_utf8_offset_to_pointer(text, cursor);
    if (selectionLength > 0) {
        PangoAttribute *selection = pango_attr_background_new(0x2222, 0x6666, 0xbbbb);
        selection->start_index = (guint)(cursorByte - text);
        selection->end_index = (guint)(g_utf8_offset_to_pointer(cursorByte, selectionLength) - text);
        pango_attr_list_insert(attributes, selection);
    }
    pango_layout_set_attributes(layout, attributes);

    cairo_save(cr);
    color(cr, 0x171f2b);
    cairo_rectangle(cr, x, y, popupWidth, popupHeight);
    cairo_fill(cr);
    color(cr, 0x6ca8ff);
    cairo_set_line_width(cr, 1);
    cairo_rectangle(cr, x + 0.5, y + 0.5, popupWidth - 1, popupHeight - 1);
    cairo_stroke(cr);
    color(cr, 0xf4f7ff);
    cairo_move_to(cr, x + 6, y + 4);
    pango_cairo_show_layout(cr, layout);
    if (selectionLength == 0) {
        PangoRectangle caret;
        pango_layout_get_cursor_pos(layout, (int)(cursorByte - text), &caret, NULL);
        int caretX = x + 6 + caret.x / PANGO_SCALE;
        if (caretX > x + popupWidth - 5) caretX = x + popupWidth - 5;
        cairo_rectangle(cr, caretX, y + 3, 1, popupHeight - 6);
        cairo_fill(cr);
    }
    cairo_restore(cr);
    pango_attr_list_unref(attributes);
    pango_font_description_free(font);
    g_object_unref(layout);
}
int tw_render_terminal(uint8_t *rgba, int width, int height, const TWCell *cells, int columns, int rows,
                       const char *text, int textLength, int cursorColumn, int cursorRow,
                       const char *preedit, int preeditLength, int preeditCursor, int preeditSelectionLength) {
    if (width < 1 || width > 1280 || height < 1 || height > 900 || columns < 2 || columns > 240 || rows < 1 || rows > 100) return -1;
    if (preeditLength < 0 || preeditLength > 1023 || (preeditLength > 0 &&
        (!preedit || !g_utf8_validate(preedit, preeditLength, NULL)))) return -1;
    if (preeditLength > 0 && (width < 40 || height < 36)) return -1;
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
            int x = col * TW_TERMINAL_CELL_WIDTH, y = row * TW_TERMINAL_CELL_HEIGHT;
            color(cr, cell->background); cairo_rectangle(cr, x, y, TW_TERMINAL_CELL_WIDTH, TW_TERMINAL_CELL_HEIGHT); cairo_fill(cr);
        }
        for (int col = 0; col < columns; col++) {
            const TWCell *cell = &cells[row * columns + col];
            if (!cell->width || !cell->length || (cell->length == 1 && text[cell->offset] == ' ')) continue;
            int x = col * TW_TERMINAL_CELL_WIDTH, y = row * TW_TERMINAL_CELL_HEIGHT;
            cairo_save(cr);
            cairo_rectangle(cr, x, y, cell->width * TW_TERMINAL_CELL_WIDTH, TW_TERMINAL_CELL_HEIGHT); cairo_clip(cr);
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
            if (cell->underline) { cairo_rectangle(cr, x, y + TW_TERMINAL_CELL_HEIGHT - 2, cell->width * TW_TERMINAL_CELL_WIDTH, 1); cairo_fill(cr); }
            cairo_restore(cr);
        }
    }
    if (cursorColumn >= 0 && cursorColumn < columns && cursorRow >= 0 && cursorRow < rows) {
        color(cr, 0xd4d4d4); cairo_rectangle(cr, cursorColumn * TW_TERMINAL_CELL_WIDTH,
            cursorRow * TW_TERMINAL_CELL_HEIGHT + TW_TERMINAL_CELL_HEIGHT - 2,
            TW_TERMINAL_CELL_WIDTH, 2); cairo_fill(cr);
    }
    if (preeditLength > 0) {
        draw_preedit(cr, width, height, cursorColumn, cursorRow, preedit, preeditLength,
                     preeditCursor, preeditSelectionLength);
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
