#include "AppKitTextBridge.h"
#include "FontFamily.h"
#include "LabelLayout.h"

#ifdef __linux__
#include <math.h>
#include <string.h>
#include <glib.h>
#include <pango/pangocairo.h>

enum { TAT_ATTR_MAX_UTF8 = 4096, TAT_ATTR_MAX_SPANS = 64,
       TAT_ATTR_MAX_WIDTH = 2048, TAT_ATTR_MAX_HEIGHT = 128, TAT_ATTR_MAX_LINES = 8 };

static int unit(double value) { return isfinite(value) && value >= 0 && value <= 1; }

static int valid(const uint8_t *utf8, int length, const TATStyleSpan *spans, int count) {
    if (!utf8 || length < 0 || length > TAT_ATTR_MAX_UTF8 ||
        !g_utf8_validate((const char *)utf8, length, NULL) ||
        count < 0 || count > TAT_ATTR_MAX_SPANS || (length > 0 && (!spans || count == 0)) ||
        (length == 0 && count != 0)) return 0;
    int end = 0;
    for (int index = 0; index < count; index++) {
        const TATStyleSpan *span = &spans[index];
        if (span->start_byte != end || span->end_byte <= end || span->end_byte > length ||
            !g_utf8_validate((const char *)utf8 + end, span->end_byte - end, NULL) ||
            (span->monospace != 0 && span->monospace != 1) ||
            span->weight < 0 || span->weight > 3 ||
            (span->italic != 0 && span->italic != 1) ||
            (span->underline != 0 && span->underline != 1) ||
            !isfinite(span->pixel_size) || span->pixel_size < 1 || span->pixel_size > 128 ||
            !isfinite(span->kern) || fabs(span->kern) > 64 ||
            !unit(span->foreground_red) || !unit(span->foreground_green) ||
            !unit(span->foreground_blue) || !unit(span->foreground_alpha) ||
            !unit(span->background_red) || !unit(span->background_green) ||
            !unit(span->background_blue) || !unit(span->background_alpha)) return 0;
        end = span->end_byte;
    }
    return end == length;
}

static uint16_t channel(double value) { return (uint16_t)lround(value * 65535); }

static PangoLayout *layout_for(cairo_t *cr, const uint8_t *utf8, int length,
                               const TATStyleSpan *spans, int count) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    pango_layout_set_text(layout, (const char *)utf8, length);
    PangoAttrList *list = pango_attr_list_new();
    // AppKit's default paragraph hyphenation factor is zero. A code line wrapping by
    // character must not gain a synthetic '-' that was never present in its source.
    pango_attr_list_insert(list, pango_attr_insert_hyphens_new(FALSE));
#define ADD_ATTRIBUTE(value) do { \
    PangoAttribute *attribute = (value); \
    attribute->start_index = (guint)span->start_byte; \
    attribute->end_index = (guint)span->end_byte; \
    pango_attr_list_insert(list, attribute); \
} while (0)
    for (int index = 0; index < count; index++) {
        const TATStyleSpan *span = &spans[index];
        ADD_ATTRIBUTE(pango_attr_family_new(tat_font_family(span->monospace)));
        PangoWeight weight = span->weight == 3 ? PANGO_WEIGHT_BOLD :
                             span->weight == 2 ? PANGO_WEIGHT_SEMIBOLD :
                             span->weight == 1 ? PANGO_WEIGHT_MEDIUM : PANGO_WEIGHT_NORMAL;
        ADD_ATTRIBUTE(pango_attr_weight_new(weight));
        ADD_ATTRIBUTE(pango_attr_style_new(span->italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL));
        ADD_ATTRIBUTE(pango_attr_size_new_absolute((int)lround(span->pixel_size * PANGO_SCALE)));
        ADD_ATTRIBUTE(pango_attr_foreground_new(channel(span->foreground_red),
                                                channel(span->foreground_green),
                                                channel(span->foreground_blue)));
        ADD_ATTRIBUTE(pango_attr_foreground_alpha_new(channel(span->foreground_alpha)));
        if (span->background_alpha > 0) {
            ADD_ATTRIBUTE(pango_attr_background_new(channel(span->background_red),
                                                    channel(span->background_green),
                                                    channel(span->background_blue)));
            ADD_ATTRIBUTE(pango_attr_background_alpha_new(channel(span->background_alpha)));
        }
        if (span->underline) ADD_ATTRIBUTE(pango_attr_underline_new(PANGO_UNDERLINE_SINGLE));
        if (span->kern != 0)
            ADD_ATTRIBUTE(pango_attr_letter_spacing_new((int)lround(span->kern * PANGO_SCALE)));
    }
#undef ADD_ATTRIBUTE
    pango_layout_set_attributes(layout, list);
    pango_attr_list_unref(list);
    return layout;
}

struct TATLabelLayout {
    PangoLayout *layout;
    int length;
};

TATLabelLayout *tat_label_create(const uint8_t *utf8, int length,
                                 const TATStyleSpan *spans, int count,
                                 int width, int mode, int alignment, int lines) {
    if (!valid(utf8, length, spans, count) || length == 0 || width <= 0 || width > TAT_ATTR_MAX_WIDTH ||
        mode < 0 || mode > 8 || alignment < 0 || alignment > 3 ||
        lines < 1 || lines > TAT_ATTR_MAX_LINES) return NULL;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return NULL;
    }
    cairo_t *cr = cairo_create(surface);
    PangoLayout *layout = layout_for(cr, utf8, length, spans, count);
    tat_configure_label_layout(layout, width, mode, alignment, lines);
    // Materialize once. Hit testing must not become the first shaping operation during drag.
    int ignored_width, ignored_height;
    pango_layout_get_pixel_size(layout, &ignored_width, &ignored_height);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    TATLabelLayout *label = g_new(TATLabelLayout, 1);
    label->layout = layout;
    label->length = length;
    return label;
}

void tat_label_destroy(TATLabelLayout *label) {
    if (!label) return;
    g_object_unref(label->layout);
    g_free(label);
}

int tat_label_hit(TATLabelLayout *label, double x, double y) {
    if (!label || !isfinite(x) || !isfinite(y) || fabs(x) > 1000000 || fabs(y) > 1000000) return -1;
    int index = 0, trailing = 0;
    pango_layout_xy_to_index(label->layout, (int)lround(x * PANGO_SCALE),
                            (int)lround(y * PANGO_SCALE), &index, &trailing);
    const char *text = pango_layout_get_text(label->layout);
    const char *cursor = text + index;
    const char *end = text + label->length;
    for (int offset = 0; offset < trailing && cursor < end; offset++) cursor = g_utf8_next_char(cursor);
    return (int)(cursor - text);
}

static void paint_selection(cairo_t *cr, PangoLayout *layout, int start, int end, TATSelectionInk ink) {
    if (start == end || ink.background_alpha == 0) return;
    cairo_set_source_rgba(cr, ink.background_red, ink.background_green,
                          ink.background_blue, ink.background_alpha);
    PangoLayoutIter *iter = pango_layout_get_iter(layout);
    int lines = 0;
    do {
        PangoLayoutLine *line = pango_layout_iter_get_line_readonly(iter);
        int line_end = line->start_index + line->length;
        if (start < line_end && end > line->start_index) {
            int *ranges = NULL, range_count = 0, y_start, y_end;
            pango_layout_line_get_x_ranges(line, start, end, &ranges, &range_count);
            pango_layout_iter_get_line_yrange(iter, &y_start, &y_end);
            for (int range = 0; range < range_count; range++) {
                double x = (double)ranges[range * 2] / PANGO_SCALE;
                double width = (double)(ranges[range * 2 + 1] - ranges[range * 2]) / PANGO_SCALE;
                cairo_rectangle(cr, x, (double)y_start / PANGO_SCALE,
                                width, (double)(y_end - y_start) / PANGO_SCALE);
            }
            cairo_fill(cr);
            g_free(ranges);
        }
        lines++;
    } while (lines < TAT_ATTR_MAX_LINES && pango_layout_iter_next_line(iter));
    pango_layout_iter_free(iter);
}

static void copy_rgba(cairo_surface_t *surface, uint8_t *rgba, int width, int height) {
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++) {
        for (int column = 0; column < width; column++) {
            uint32_t pixel;
            memcpy(&pixel, pixels + row * stride + column * 4, 4);
            unsigned alpha = pixel >> 24;
            int offset = (row * width + column) * 4;
            rgba[offset + 3] = (uint8_t)alpha;
            if (alpha == 0) {
                rgba[offset] = rgba[offset + 1] = rgba[offset + 2] = 0;
            } else {
                unsigned red = (pixel >> 16) & 255, green = (pixel >> 8) & 255, blue = pixel & 255;
                rgba[offset] = (uint8_t)fmin(255, (red * 255 + alpha / 2) / alpha);
                rgba[offset + 1] = (uint8_t)fmin(255, (green * 255 + alpha / 2) / alpha);
                rgba[offset + 2] = (uint8_t)fmin(255, (blue * 255 + alpha / 2) / alpha);
            }
        }
    }
}

int tat_label_render(TATLabelLayout *label, uint8_t *rgba, int capacity,
                     int width, int height, int clip_x, int clip_y, int antialias,
                     int start, int end, TATSelectionInk ink) {
    if (!label || !rgba || width <= 0 || width > TAT_ATTR_MAX_WIDTH ||
        height <= 0 || height > TAT_ATTR_MAX_HEIGHT || capacity < width * height * 4 ||
        clip_x < 0 || clip_x > TAT_ATTR_MAX_WIDTH || clip_y < 0 || clip_y > 2048 ||
        (antialias != 0 && antialias != 1) || start < 0 || start > end || end > label->length ||
        !unit(ink.background_red) || !unit(ink.background_green) || !unit(ink.background_blue) ||
        !unit(ink.background_alpha) || !unit(ink.foreground_red) || !unit(ink.foreground_green) ||
        !unit(ink.foreground_blue) || !unit(ink.foreground_alpha)) return 0;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_font_options_t *options = cairo_font_options_create();
    cairo_font_options_set_antialias(options, antialias ? CAIRO_ANTIALIAS_GRAY : CAIRO_ANTIALIAS_NONE);
    cairo_set_font_options(cr, options);
    cairo_font_options_destroy(options);
    cairo_translate(cr, -clip_x, -clip_y);
    paint_selection(cr, label->layout, start, end, ink);
    PangoLayout *drawn = label->layout;
    if (start != end) {
        // Foreground attributes cannot alter font or geometry. Keep the retained hit layout
        // immutable and override only the selected byte range in this drawing copy.
        drawn = pango_layout_copy(label->layout);
        PangoAttrList *attributes = pango_attr_list_copy(pango_layout_get_attributes(drawn));
        PangoAttribute *color = pango_attr_foreground_new(channel(ink.foreground_red),
            channel(ink.foreground_green), channel(ink.foreground_blue));
        color->start_index = (guint)start; color->end_index = (guint)end;
        pango_attr_list_change(attributes, color);
        PangoAttribute *alpha = pango_attr_foreground_alpha_new(channel(ink.foreground_alpha));
        alpha->start_index = (guint)start; alpha->end_index = (guint)end;
        pango_attr_list_change(attributes, alpha);
        PangoAttribute *background = pango_attr_background_alpha_new(0);
        background->start_index = (guint)start; background->end_index = (guint)end;
        pango_attr_list_change(attributes, background);
        pango_layout_set_attributes(drawn, attributes);
        pango_attr_list_unref(attributes);
    }
    pango_cairo_update_layout(cr, drawn);
    pango_cairo_show_layout(cr, drawn);
    copy_rgba(surface, rgba, width, height);
    if (drawn != label->layout) g_object_unref(drawn);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}

static void measure_layout(PangoLayout *layout, int maximum_lines, int maximum_height, TATMetrics *result) {
    result->width = 0;
    result->height = 0;
    result->baseline = (pango_layout_get_baseline(layout) + PANGO_SCALE / 2) / PANGO_SCALE;
    result->glyphs = 0;
    PangoLayoutIter *iter = pango_layout_get_iter(layout);
    int lines = 0;
    do {
        PangoLayoutLine *line = pango_layout_iter_get_line_readonly(iter);
        PangoRectangle logical;
        int y_start, y_end;
        pango_layout_line_get_pixel_extents(line, NULL, &logical);
        pango_layout_iter_get_line_yrange(iter, &y_start, &y_end);
        if (logical.width > result->width) result->width = logical.width;
        result->height = (y_end + PANGO_SCALE - 1) / PANGO_SCALE;
        for (GSList *run_link = line->runs; run_link; run_link = run_link->next) {
            PangoGlyphItem *run = run_link->data;
            result->glyphs += run->glyphs->num_glyphs;
        }
        lines++;
    } while (lines < maximum_lines && pango_layout_iter_next_line(iter));
    pango_layout_iter_free(iter);
    if (result->width > TAT_ATTR_MAX_WIDTH) result->width = TAT_ATTR_MAX_WIDTH;
    if (result->height > maximum_height) result->height = maximum_height;
}

static int measure(const uint8_t *utf8, int length, const TATStyleSpan *spans,
                   int count, int wrap_width, int maximum_lines,
                   int char_wrapping, int maximum_height, TATMetrics *result) {
    if (!result || !valid(utf8, length, spans, count) ||
        wrap_width < 0 || wrap_width > TAT_ATTR_MAX_WIDTH ||
        maximum_lines < 1 || maximum_lines > TAT_ATTR_MAX_LINES ||
        (char_wrapping != 0 && char_wrapping != 1)) return 0;
    if (length == 0) { memset(result, 0, sizeof(*result)); return 1; }
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_font_options_t *font_options = cairo_font_options_create();
    cairo_font_options_set_antialias(font_options, CAIRO_ANTIALIAS_GRAY);
    cairo_set_font_options(cr, font_options);
    cairo_font_options_destroy(font_options);
    PangoLayout *layout = layout_for(cr, utf8, length, spans, count);
    if (wrap_width > 0) {
        pango_layout_set_width(layout, wrap_width * PANGO_SCALE);
        pango_layout_set_wrap(layout, char_wrapping ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
    }
    measure_layout(layout, maximum_lines, maximum_height, result);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}

int tat_attributed_measure(const uint8_t *utf8, int length, const TATStyleSpan *spans,
                           int count, TATMetrics *result) {
    return measure(utf8, length, spans, count, 0, TAT_ATTR_MAX_LINES, 0, TAT_ATTR_MAX_HEIGHT, result);
}

int tat_attributed_measure_wrapped(const uint8_t *utf8, int length,
                                   const TATStyleSpan *spans, int count,
                                   int wrap_width, int maximum_lines, int char_wrapping,
                                   TATMetrics *result) {
    if (wrap_width <= 0) return 0;
    return measure(utf8, length, spans, count, wrap_width, maximum_lines,
                   char_wrapping, TAT_ATTR_MAX_HEIGHT, result);
}

int tat_attributed_measure_label(const uint8_t *utf8, int length, const TATStyleSpan *spans,
                                 int count, int width, int lines, int char_wrapping, TATMetrics *result) {
    return measure(utf8, length, spans, count, width, lines, char_wrapping, 2048, result);
}

int tat_attributed_render(uint8_t *rgba, int capacity, int width, int height,
                          int layout_width, int clip_x, int clip_y, int mode, int alignment,
                          int maximum_lines, int antialias, const uint8_t *utf8, int length,
                          const TATStyleSpan *spans, int count) {
    if (!rgba || !valid(utf8, length, spans, count) || width <= 0 || height <= 0 ||
        width > TAT_ATTR_MAX_WIDTH || height > TAT_ATTR_MAX_HEIGHT ||
        capacity < width * height * 4 || layout_width < 0 ||
        layout_width > TAT_ATTR_MAX_WIDTH || clip_x < 0 || clip_x > TAT_ATTR_MAX_WIDTH ||
        clip_y < 0 || clip_y > TAT_ATTR_MAX_HEIGHT || mode < 0 || mode > 8 ||
        alignment < 0 || alignment > 3 || maximum_lines < 1 ||
        maximum_lines > TAT_ATTR_MAX_LINES || (antialias != 0 && antialias != 1)) return 0;
    if (length == 0) { memset(rgba, 0, (size_t)width * height * 4); return 1; }
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_font_options_t *font_options = cairo_font_options_create();
    cairo_font_options_set_antialias(font_options,
                                   antialias ? CAIRO_ANTIALIAS_GRAY : CAIRO_ANTIALIAS_NONE);
    cairo_set_font_options(cr, font_options);
    cairo_font_options_destroy(font_options);
    PangoLayout *layout = layout_for(cr, utf8, length, spans, count);
    if (layout_width > 0)
        tat_configure_label_layout(layout, layout_width, mode, alignment, maximum_lines);
    cairo_set_source_rgba(cr, spans[0].foreground_red, spans[0].foreground_green,
                          spans[0].foreground_blue, spans[0].foreground_alpha);
    cairo_move_to(cr, -clip_x, -clip_y);
    pango_cairo_show_layout(cr, layout);
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++) {
        for (int column = 0; column < width; column++) {
            uint32_t pixel;
            memcpy(&pixel, pixels + row * stride + column * 4, 4);
            unsigned alpha = pixel >> 24;
            int offset = (row * width + column) * 4;
            rgba[offset + 3] = (uint8_t)alpha;
            if (alpha == 0) {
                rgba[offset] = rgba[offset + 1] = rgba[offset + 2] = 0;
            } else {
                unsigned red = (pixel >> 16) & 255, green = (pixel >> 8) & 255, blue = pixel & 255;
                rgba[offset] = (uint8_t)fmin(255, (red * 255 + alpha / 2) / alpha);
                rgba[offset + 1] = (uint8_t)fmin(255, (green * 255 + alpha / 2) / alpha);
                rgba[offset + 2] = (uint8_t)fmin(255, (blue * 255 + alpha / 2) / alpha);
            }
        }
    }
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}
#else
int tat_attributed_measure_label(const uint8_t *t, int n, const TATStyleSpan *s, int c,
                                 int w, int l, int h, TATMetrics *r) { return 0; }
struct TATLabelLayout { int unused; };
TATLabelLayout *tat_label_create(const uint8_t *t, int n, const TATStyleSpan *s, int c,
                                int w, int m, int a, int l) { return NULL; }
void tat_label_destroy(TATLabelLayout *l) {}
int tat_label_hit(TATLabelLayout *l, double x, double y) { return -1; }
int tat_label_render(TATLabelLayout *l, uint8_t *p, int c, int w, int h,
                     int x, int y, int a, int s, int e, TATSelectionInk i) { return 0; }
int tat_attributed_measure(const uint8_t *t, int n, const TATStyleSpan *s, int c, TATMetrics *r) { return 0; }
int tat_attributed_measure_wrapped(const uint8_t *t, int n, const TATStyleSpan *s, int c,
                                   int w, int l, int h, TATMetrics *r) { return 0; }
int tat_attributed_render(uint8_t *p, int cap, int w, int h, int lw, int x, int y,
                          int mode, int align, int lines, int antialias, const uint8_t *t, int n,
                          const TATStyleSpan *s, int c) { return 0; }
#endif
