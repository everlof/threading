#include "AppKitTextBridge.h"

#ifdef __linux__
#include <math.h>
#include <string.h>
#include <glib.h>
#include <pango/pangocairo.h>

enum { TAT_MAX_UTF8 = 4096, TAT_MAX_WIDTH = 2048, TAT_MAX_HEIGHT = 128,
       TAT_MAX_PIXELS = TAT_MAX_WIDTH * TAT_MAX_HEIGHT, TAT_MAX_LINES = 8 };

static int valid_text(const uint8_t *text, int length, double size) {
    return text && length >= 0 && length <= TAT_MAX_UTF8 && isfinite(size) &&
           size >= 1 && size <= 128 && g_utf8_validate((const char *)text, length, NULL);
}

static PangoLayout *new_layout(cairo_t *cr, const uint8_t *text, int length,
                               int monospace, int weight, double size) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, monospace ? "DejaVu Sans Mono" : "DejaVu Sans");
    const PangoWeight pango_weight = weight == 3 ? PANGO_WEIGHT_BOLD :
                                     weight == 2 ? PANGO_WEIGHT_SEMIBOLD :
                                     weight == 1 ? PANGO_WEIGHT_MEDIUM : PANGO_WEIGHT_NORMAL;
    pango_font_description_set_weight(font, pango_weight);
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, (const char *)text, length);
    pango_font_description_free(font);
    return layout;
}

int tat_font_metrics(int monospace, int weight, double size, TATFontMetrics *result) {
    if (!result || (monospace != 0 && monospace != 1) || weight < 0 || weight > 3 ||
        !isfinite(size) || size < 1 || size > 128) return 0;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    PangoLayout *layout = new_layout(cr, (const uint8_t *)"Ag", 2, monospace, weight, size);
    PangoFontMetrics *metrics = pango_context_get_metrics(
        pango_layout_get_context(layout), pango_layout_get_font_description(layout),
        pango_language_get_default());
    result->ascent = (double)pango_font_metrics_get_ascent(metrics) / PANGO_SCALE;
    result->descent = (double)pango_font_metrics_get_descent(metrics) / PANGO_SCALE;
    result->approximate_width =
        (double)pango_font_metrics_get_approximate_char_width(metrics) / PANGO_SCALE;
    pango_font_metrics_unref(metrics);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return isfinite(result->ascent) && isfinite(result->descent) &&
           isfinite(result->approximate_width) && result->ascent > 0 &&
           result->descent >= 0 && result->approximate_width >= 0;
}

static int measure(const uint8_t *text, int length, int monospace, int weight,
                   double size, int maximum_lines, int paragraphs,
                   int wrap_width, int char_wrapping, TATMetrics *result) {
    if (!result || !valid_text(text, length, size) || weight < 0 || weight > 3 ||
        maximum_lines < 1 || maximum_lines > TAT_MAX_LINES ||
        wrap_width < 0 || wrap_width > TAT_MAX_WIDTH ||
        (char_wrapping != 0 && char_wrapping != 1)) return 0;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    PangoLayout *layout = new_layout(cr, text, length, monospace, weight, size);
    pango_layout_set_single_paragraph_mode(layout, !paragraphs);
    if (wrap_width > 0) {
        pango_layout_set_width(layout, wrap_width * PANGO_SCALE);
        pango_layout_set_wrap(layout, char_wrapping ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
    }
    pango_layout_get_pixel_size(layout, &result->width, &result->height);
    if (length == 0 && result->height == 0) {
        // AppKit's empty label still owns one line of vertical space. Some Pango versions
        // return a zero-height empty layout, so measure a space solely for font metrics.
        int ignored_width;
        pango_layout_set_text(layout, " ", 1);
        pango_layout_get_pixel_size(layout, &ignored_width, &result->height);
    }
    result->baseline = (pango_layout_get_baseline(layout) + PANGO_SCALE / 2) / PANGO_SCALE;
    result->glyphs = 0;
    if (paragraphs) {
        // With no wrap width, Pango's negative height does not limit authored paragraphs.
        // Inspect only the lines the label can paint, using the same Pango line positions.
        result->width = 0;
        result->height = 0;
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
            if (length > 0) {
                for (GSList *run_link = line->runs; run_link; run_link = run_link->next) {
                    PangoGlyphItem *run = run_link->data;
                    result->glyphs += run->glyphs->num_glyphs;
                }
            }
            lines++;
        } while (lines < maximum_lines && pango_layout_iter_next_line(iter));
        pango_layout_iter_free(iter);
        if (length == 0) result->width = 0;
    } else if (length > 0) {
        for (GSList *line_link = pango_layout_get_lines_readonly(layout); line_link; line_link = line_link->next) {
            PangoLayoutLine *line = line_link->data;
            for (GSList *run_link = line->runs; run_link; run_link = run_link->next) {
                PangoGlyphItem *run = run_link->data;
                result->glyphs += run->glyphs->num_glyphs;
            }
        }
    }
    // An intrinsic width beyond the maximum drawable line is capped consistently with render.
    if (result->width > TAT_MAX_WIDTH) result->width = TAT_MAX_WIDTH;
    if (result->height > TAT_MAX_HEIGHT) result->height = TAT_MAX_HEIGHT;
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}

int tat_measure(const uint8_t *text, int length, int monospace, int weight,
                double size, TATMetrics *result) {
    return measure(text, length, monospace, weight, size, 1, 0, 0, 0, result);
}

int tat_measure_paragraphs(const uint8_t *text, int length, int monospace, int weight,
                           double size, int maximum_lines, TATMetrics *result) {
    return measure(text, length, monospace, weight, size, maximum_lines, 1, 0, 0, result);
}

int tat_measure_wrapped(const uint8_t *text, int length, int monospace, int weight,
                        double size, int maximum_lines, int wrap_width,
                        int char_wrapping, TATMetrics *result) {
    if (wrap_width <= 0) return 0;
    return measure(text, length, monospace, weight, size, maximum_lines, 1,
                   wrap_width, char_wrapping, result);
}

int tat_render(uint8_t *coverage, int capacity, int width, int height,
               int layout_width, int clip_x, int clip_y, const uint8_t *text, int length,
               int monospace, int weight, double size, int mode, int alignment, int max_lines) {
    if (!coverage || !valid_text(text, length, size) || width <= 0 || height <= 0 ||
        width > TAT_MAX_WIDTH || height > TAT_MAX_HEIGHT ||
        width * height > TAT_MAX_PIXELS || capacity < width * height ||
        layout_width <= 0 || layout_width > TAT_MAX_WIDTH ||
        clip_x < 0 || clip_x > TAT_MAX_WIDTH || clip_y < -TAT_MAX_HEIGHT ||
        clip_y > TAT_MAX_HEIGHT || mode < 0 || mode > 7 ||
        alignment < 0 || alignment > 3 || max_lines < 1 || max_lines > TAT_MAX_LINES ||
        weight < 0 || weight > 3) return 0;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); return 0;
    }
    cairo_t *cr = cairo_create(surface);
    PangoLayout *layout = new_layout(cr, text, length, monospace, weight, size);
    pango_layout_set_width(layout, layout_width * PANGO_SCALE);
    pango_layout_set_alignment(layout, alignment == 1 ? PANGO_ALIGN_CENTER :
                                        alignment == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
    pango_layout_set_justify(layout, alignment == 3);
    if (mode == 2 || mode == 3 || mode == 6 || mode == 7) {
        pango_layout_set_wrap(layout, mode == 3 || mode == 7 ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
        pango_layout_set_height(layout, -max_lines);
        pango_layout_set_ellipsize(layout, mode == 2 || mode == 3
                                  ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE);
    } else {
        pango_layout_set_single_paragraph_mode(layout, TRUE);
        pango_layout_set_height(layout, -1);
        pango_layout_set_ellipsize(layout, mode == 1 ? PANGO_ELLIPSIZE_END :
                                   mode == 4 ? PANGO_ELLIPSIZE_START :
                                   mode == 5 ? PANGO_ELLIPSIZE_MIDDLE : PANGO_ELLIPSIZE_NONE);
    }
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    cairo_move_to(cr, -clip_x, -clip_y);
    pango_cairo_show_layout(cr, layout);
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < height; row++)
        memcpy(coverage + row * width, pixels + row * stride, width);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return 1;
}
#else
int tat_font_metrics(int m, int w, double s, TATFontMetrics *r) { return 0; }
int tat_measure(const uint8_t *t, int n, int m, int b, double s, TATMetrics *r) { return 0; }
int tat_measure_paragraphs(const uint8_t *t, int n, int m, int b, double s, int l, TATMetrics *r) { return 0; }
int tat_measure_wrapped(const uint8_t *t, int n, int m, int b, double s, int l,
                        int w, int c, TATMetrics *r) { return 0; }
int tat_render(uint8_t *c, int a, int w, int h, int lw, int x, int y,
               const uint8_t *t, int n, int m, int b, double s, int mode, int align, int lines) { return 0; }
#endif
