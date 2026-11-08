#include "AppKitTextBridge.h"
#include "FontFamily.h"

#ifdef __linux__
#include <limits.h>
#include <math.h>
#include <string.h>
#include <pango/pangocairo.h>

enum { DOCUMENT_TILE_WIDTH = 2048, DOCUMENT_TILE_HEIGHT = 128 };

typedef struct {
    PangoLayoutLine *line; // Borrowed from the immutable retained layout.
    int top, bottom;
    int paint_top, paint_bottom, prefix_bottom, suffix_top;
    int paragraph_offset, paragraph_length;
    double origin_x, baseline;
} DocumentLine;

struct TATDocumentLayout {
    GPtrArray *paragraphs;
    GArray *line_storage;
    DocumentLine *lines;
    int line_count;
    int length;
};

static int boolean(int value) { return value == 0 || value == 1; }

// This is the same paragraph-direction rule used by Pango's automatic layout. Its deprecated
// helper has no replacement that preserves the first-strong/neutral paragraph semantics.
static PangoDirection direction(const char *text, int length) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    PangoDirection result = pango_find_base_dir(text, length);
    G_GNUC_END_IGNORE_DEPRECATIONS
    return result;
}

// The first line whose vertical band intersects y. A deep viewport must not walk the prefix.
static int line_at(TATDocumentLayout *document, double y) {
    int low = 0, high = document->line_count;
    while (low < high) {
        int middle = low + (high - low) / 2;
        if (document->lines[middle].bottom <= y) low = middle + 1;
        else high = middle;
    }
    return low;
}

static int paint_at(TATDocumentLayout *document, int y) {
    int low = 0, high = document->line_count;
    while (low < high) {
        int middle = low + (high - low) / 2;
        if (document->lines[middle].prefix_bottom <= y) low = middle + 1;
        else high = middle;
    }
    return low;
}

TATDocumentLayout *tat_document_create(const uint8_t *utf8, int length,
    int monospace, int weight, int italic, double size, int width,
    int char_wrapping, int alignment, double line_spacing, int antialias,
    TATMetrics *metrics, int *line_count) {
    if (!utf8 || length <= 0 || !metrics || !line_count ||
        !g_utf8_validate((const char *)utf8, length, NULL) ||
        !boolean(monospace) || weight < 0 || weight > 3 || !boolean(italic) ||
        !isfinite(size) || size < 1 || size > 128 || width <= 0 ||
        width > INT_MAX / PANGO_SCALE || !boolean(char_wrapping) ||
        alignment < 0 || alignment > 3 || !isfinite(line_spacing) ||
        line_spacing < 0 || line_spacing > 128 || !boolean(antialias)) return NULL;
    const int spacing = (int)lround(line_spacing * PANGO_SCALE);

    // A private map prevents a worker-owned layout from sharing the UI thread's font cache.
    // https://docs.gtk.org/PangoCairo/type_func.FontMap.get_default.html
    PangoFontMap *map = pango_cairo_font_map_new();
    PangoContext *context = pango_font_map_create_context(map);
    cairo_font_options_t *options = cairo_font_options_create();
    cairo_font_options_set_antialias(options, antialias ? CAIRO_ANTIALIAS_GRAY : CAIRO_ANTIALIAS_NONE);
    pango_cairo_context_set_font_options(context, options);
    cairo_font_options_destroy(options);
    g_object_unref(map);

    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, tat_font_family(monospace));
    PangoWeight weights[] = { PANGO_WEIGHT_NORMAL, PANGO_WEIGHT_MEDIUM,
                             PANGO_WEIGHT_SEMIBOLD, PANGO_WEIGHT_BOLD };
    pango_font_description_set_weight(font, weights[weight]);
    pango_font_description_set_style(font, italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    PangoAttrList *attributes = pango_attr_list_new();
    pango_attr_list_insert(attributes, pango_attr_insert_hyphens_new(FALSE));
    TATDocumentLayout *document = g_new0(TATDocumentLayout, 1);
    document->paragraphs = g_ptr_array_new_with_free_func(g_object_unref);
    document->line_storage = g_array_new(FALSE, FALSE, sizeof(DocumentLine));
    document->length = length;
    memset(metrics, 0, sizeof(*metrics));
    PangoDirection previous = direction((const char *)utf8, length);
    if (previous == PANGO_DIRECTION_NEUTRAL) previous = PANGO_DIRECTION_LTR;
    int offset = 0;
    double y = 0;
    gboolean valid = TRUE;
    while (valid) {
        int delimiter, next;
        const char *text = (const char *)utf8 + offset;
        pango_find_paragraph_boundary(text, length - offset, &delimiter, &next);
        PangoDirection resolved = direction(text, delimiter);
        if (resolved != PANGO_DIRECTION_NEUTRAL) previous = resolved;
        PangoContext *paragraph_context = pango_font_map_create_context(pango_context_get_font_map(context));
        pango_cairo_context_set_font_options(paragraph_context, pango_cairo_context_get_font_options(context));
        pango_context_set_base_dir(paragraph_context, previous);
        PangoLayout *layout = pango_layout_new(paragraph_context);
        g_object_unref(paragraph_context);
        pango_layout_set_auto_dir(layout, FALSE);
        pango_layout_set_font_description(layout, font);
        pango_layout_set_text(layout, text, delimiter);
        pango_layout_set_width(layout, width * PANGO_SCALE);
        pango_layout_set_wrap(layout, char_wrapping ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
        pango_layout_set_spacing(layout, spacing);
        PangoAlignment resolved_alignment = alignment == 1 ? PANGO_ALIGN_CENTER :
            alignment == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT;
        if (previous == PANGO_DIRECTION_RTL && alignment != 1)
            resolved_alignment = alignment == 2 ? PANGO_ALIGN_LEFT : PANGO_ALIGN_RIGHT;
        pango_layout_set_alignment(layout, resolved_alignment);
        pango_layout_set_justify(layout, alignment == 3);
        pango_layout_set_attributes(layout, attributes);
        g_ptr_array_add(document->paragraphs, layout);
        PangoLayoutIter *iterator = pango_layout_get_iter(layout);
        do {
            DocumentLine line = { 0 };
            line.line = pango_layout_iter_get_line_readonly(iterator);
            line.paragraph_offset = offset;
            line.paragraph_length = delimiter;
            PangoRectangle position, local, ink;
            int start, end;
            pango_layout_iter_get_line_extents(iterator, &ink, &position);
            pango_layout_line_get_extents(line.line, NULL, &local);
            pango_layout_iter_get_line_yrange(iterator, &start, &end);
            int64_t band_start = start, band_end = end;
            // Paragraph plans share the same inter-line bands as one complete Pango layout.
            // Pango's per-paragraph iterator has no preceding/following paragraph to include.
            if (offset > 0 && line.line->start_index == 0) band_start -= spacing / 2;
            if (offset + delimiter < length && pango_layout_iter_at_last_line(iterator)) {
                band_end += spacing - spacing / 2;
            }
            double bottom = ceil(y + (double)band_end / PANGO_SCALE);
            if (bottom > INT_MAX) { valid = FALSE; break; }
            line.top = (int)floor(y + (double)band_start / PANGO_SCALE);
            line.bottom = (int)bottom;
            line.origin_x = ((double)position.x - local.x) / PANGO_SCALE;
            line.baseline = y + (double)pango_layout_iter_get_baseline(iterator) / PANGO_SCALE;
            double paint_top = floor(y + (double)ink.y / PANGO_SCALE);
            double paint_bottom = ceil(y + ((double)ink.y + ink.height) / PANGO_SCALE);
            if (paint_top < INT_MIN || paint_bottom > INT_MAX) { valid = FALSE; break; }
            line.paint_top = MIN(line.top, (int)paint_top);
            line.paint_bottom = MAX(line.bottom, (int)paint_bottom);
            int count = document->line_storage->len;
            int prior_bottom = count == 0 ? 0 : g_array_index(document->line_storage, DocumentLine, count - 1).prefix_bottom;
            line.prefix_bottom = MAX(prior_bottom, line.paint_bottom);
            if (line.bottom <= line.top) { valid = FALSE; break; }
            int right = (int)ceil(((double)position.x + position.width) / PANGO_SCALE);
            metrics->width = MAX(metrics->width, right);
            metrics->height = line.bottom;
            if (count == 0) metrics->baseline = (int)lround(line.baseline);
            for (GSList *item = line.line->runs; item; item = item->next) {
                PangoGlyphItem *run = item->data;
                metrics->glyphs += MIN(run->glyphs->num_glyphs, INT_MAX - metrics->glyphs);
            }
            g_array_append_val(document->line_storage, line);
        } while (pango_layout_iter_next_line(iterator));
        pango_layout_iter_free(iterator);
        PangoRectangle paragraph;
        pango_layout_get_extents(layout, NULL, &paragraph);
        y += (double)paragraph.height / PANGO_SCALE;
        if (offset + delimiter == length) break;
        y += (double)spacing / PANGO_SCALE;
        offset += next;
    }
    pango_font_description_free(font);
    pango_attr_list_unref(attributes);
    g_object_unref(context);
    if (!valid) { tat_document_destroy(document); return NULL; }
    int count = document->line_storage->len;
    document->lines = (DocumentLine *)document->line_storage->data;
    document->line_count = count;
    for (int index = count - 1; index >= 0; index--) {
        DocumentLine *line = &document->lines[index];
        line->suffix_top = index == count - 1 ? line->paint_top
            : MIN(line->paint_top, document->lines[index + 1].suffix_top);
    }
    *line_count = count;
    return document;
}

void tat_document_destroy(TATDocumentLayout *document) {
    if (!document) return;
    g_ptr_array_unref(document->paragraphs);
    g_array_unref(document->line_storage);
    g_free(document);
}

int tat_document_hit(TATDocumentLayout *document, double x, double y) {
    if (!document || !isfinite(x) || !isfinite(y) ||
        fabs(x) > INT_MAX / PANGO_SCALE || fabs(y) > INT_MAX) return -1;
    int selected = MIN(line_at(document, y), document->line_count - 1);
    DocumentLine *line = &document->lines[selected];
    double local = (x - line->origin_x) * PANGO_SCALE;
    if (local < INT_MIN || local > INT_MAX) return -1;
    int byte = 0, trailing = 0;
    pango_layout_line_x_to_index(line->line, (int)lround(local), &byte, &trailing);
    const char *text = pango_layout_get_text(line->line->layout);
    const char *cursor = text + byte, *end = text + line->paragraph_length;
    for (int scalar = 0; scalar < trailing && cursor < end; scalar++) cursor = g_utf8_next_char(cursor);
    return line->paragraph_offset + (int)(cursor - text);
}

int tat_document_render(TATDocumentLayout *document, uint8_t *coverage, int capacity,
    int width, int height, int clip_x, int clip_y, int *visited_lines) {
    if (!document || !coverage || width <= 0 || width > DOCUMENT_TILE_WIDTH ||
        height <= 0 || height > DOCUMENT_TILE_HEIGHT || capacity < width * height ||
        clip_x < 0 || clip_x > INT_MAX - width || clip_y < 0 || clip_y > INT_MAX - height)
        return 0;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    int visited = 0;
    for (int index = paint_at(document, clip_y); index < document->line_count; index++) {
        DocumentLine *line = &document->lines[index];
        if (line->suffix_top >= clip_y + height) break;
        if (line->paint_bottom <= clip_y || line->paint_top >= clip_y + height) continue;
        cairo_move_to(cr, line->origin_x - clip_x, line->baseline - clip_y);
        pango_cairo_show_layout_line(cr, line->line);
        visited++;
    }
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++) memcpy(coverage + row * width, pixels + row * stride, width);
    if (visited_lines) *visited_lines = visited;
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}

int tat_document_selection(TATDocumentLayout *document, uint8_t *coverage, int capacity,
    int width, int height, int clip_x, int clip_y, int start_byte, int end_byte) {
    if (!document || !coverage || width <= 0 || width > DOCUMENT_TILE_WIDTH ||
        height <= 0 || height > DOCUMENT_TILE_HEIGHT || capacity < width * height ||
        clip_x < 0 || clip_x > INT_MAX - width || clip_y < 0 || clip_y > INT_MAX - height ||
        start_byte < 0 || end_byte < start_byte || end_byte > document->length) return 0;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    for (int index = line_at(document, clip_y); index < document->line_count; index++) {
        DocumentLine *line = &document->lines[index];
        if (line->top >= clip_y + height) break;
        int start = start_byte - line->paragraph_offset;
        int end = end_byte - line->paragraph_offset;
        if (end <= start || start > line->paragraph_length) continue;
        int *ranges = NULL, count = 0;
        pango_layout_line_get_x_ranges(line->line, start, end, &ranges, &count);
        for (int range = 0; range < count; range++) {
            double left = (double)ranges[range * 2] / PANGO_SCALE - clip_x;
            double right = (double)ranges[range * 2 + 1] / PANGO_SCALE - clip_x;
            cairo_rectangle(cr, left, line->top - clip_y, right - left, line->bottom - line->top);
        }
        g_free(ranges);
    }
    cairo_fill(cr);
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++) memcpy(coverage + row * width, pixels + row * stride, width);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}

int tat_document_render_rgba(TATDocumentLayout *document, uint8_t *rgba, int capacity,
    int width, int height, int clip_x, int clip_y, double red, double green, double blue,
    double alpha) {
    if (!document || !rgba || width <= 0 || width > DOCUMENT_TILE_WIDTH ||
        height <= 0 || height > DOCUMENT_TILE_HEIGHT || capacity < width * height * 4 ||
        clip_x < 0 || clip_x > INT_MAX - width || clip_y < 0 || clip_y > INT_MAX - height ||
        !isfinite(red) || red < 0 || red > 1 || !isfinite(green) || green < 0 || green > 1 ||
        !isfinite(blue) || blue < 0 || blue > 1 || !isfinite(alpha) || alpha < 0 || alpha > 1)
        return 0;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, red, green, blue, alpha);
    for (int index = paint_at(document, clip_y); index < document->line_count; index++) {
        DocumentLine *line = &document->lines[index];
        if (line->suffix_top >= clip_y + height) break;
        if (line->paint_bottom <= clip_y || line->paint_top >= clip_y + height) continue;
        cairo_move_to(cr, line->origin_x - clip_x, line->baseline - clip_y);
        pango_cairo_show_layout_line(cr, line->line);
    }
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++) {
        for (int column = 0; column < width; column++) {
            uint32_t pixel;
            memcpy(&pixel, pixels + row * stride + column * 4, sizeof(pixel));
            int a = (pixel >> 24) & 255;
            int offset = (row * width + column) * 4;
            rgba[offset] = a ? MIN(255, (((pixel >> 16) & 255) * 255 + a / 2) / a) : 0;
            rgba[offset + 1] = a ? MIN(255, (((pixel >> 8) & 255) * 255 + a / 2) / a) : 0;
            rgba[offset + 2] = a ? MIN(255, ((pixel & 255) * 255 + a / 2) / a) : 0;
            rgba[offset + 3] = a;
        }
    }
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}
#else
struct TATDocumentLayout { int unused; };
TATDocumentLayout *tat_document_create(const uint8_t *t, int n, int m, int w, int i, double s,
    int x, int c, int a, double spacing, int aa, TATMetrics *r, int *l) { return NULL; }
void tat_document_destroy(TATDocumentLayout *d) {}
int tat_document_hit(TATDocumentLayout *d, double x, double y) { return -1; }
int tat_document_render(TATDocumentLayout *d, uint8_t *p, int c, int w, int h, int x, int y,
    int *v) { return 0; }
int tat_document_selection(TATDocumentLayout *d, uint8_t *p, int c, int w, int h, int x, int y,
    int s, int e) { return 0; }
int tat_document_render_rgba(TATDocumentLayout *d, uint8_t *p, int c, int w, int h, int x, int y,
    double r, double g, double b, double a) { return 0; }
#endif
