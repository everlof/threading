#include "AppKitTextBridge.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pango/pangocairo.h>

enum { WIDTH = 360, HEIGHT = 128, SAMPLES = 7 };
static atomic_int finished;

static double seconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

static PangoLayout *reference(const char *text, int width, int alignment, int character_wrap) {
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    cairo_t *cr = cairo_create(surface);
    cairo_font_options_t *options = cairo_font_options_create();
    cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
    cairo_set_font_options(cr, options);
    cairo_font_options_destroy(options);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("DejaVu Sans");
    pango_font_description_set_absolute_size(font, 13 * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    pango_layout_set_text(layout, text, -1);
    pango_layout_set_width(layout, width * PANGO_SCALE);
    pango_layout_set_wrap(layout, character_wrap ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
    pango_layout_set_alignment(layout, alignment == 1 ? PANGO_ALIGN_CENTER :
                                      alignment == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
    pango_layout_set_justify(layout, alignment == 3);
    PangoAttrList *attributes = pango_attr_list_new();
    pango_attr_list_insert(attributes, pango_attr_insert_hyphens_new(FALSE));
    pango_layout_set_attributes(layout, attributes);
    pango_attr_list_unref(attributes);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return layout;
}

static void full_render(PangoLayout *layout, uint8_t *output, int x, int y) {
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, WIDTH, HEIGHT);
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    cairo_move_to(cr, -x, -y);
    pango_cairo_show_layout(cr, layout);
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < HEIGHT; row++) memcpy(output + row * WIDTH, pixels + row * stride, WIDTH);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}

static void full_selection(PangoLayout *layout, uint8_t *output, int y, int first, int last) {
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, WIDTH, HEIGHT);
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    PangoLayoutIter *iterator = pango_layout_get_iter(layout);
    do {
        PangoLayoutLine *line = pango_layout_iter_get_line_readonly(iterator);
        int top, bottom, *ranges = NULL, count = 0;
        pango_layout_iter_get_line_yrange(iterator, &top, &bottom);
        pango_layout_line_get_x_ranges(line, first, last, &ranges, &count);
        int pixel_top = (int)floor((double)top / PANGO_SCALE);
        int pixel_bottom = (int)ceil((double)bottom / PANGO_SCALE);
        for (int index = 0; index < count; index++) {
            double left = (double)ranges[index * 2] / PANGO_SCALE;
            double right = (double)ranges[index * 2 + 1] / PANGO_SCALE;
            cairo_rectangle(cr, left, pixel_top - y, right - left, pixel_bottom - pixel_top);
        }
        g_free(ranges);
    } while (pango_layout_iter_next_line(iterator));
    pango_layout_iter_free(iterator);
    cairo_fill(cr);
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < HEIGHT; row++) memcpy(output + row * WIDTH, pixels + row * stride, WIDTH);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}

static void full_rgba(PangoLayout *layout, uint8_t *output, int y) {
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, WIDTH, HEIGHT);
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, .1, .2, .3, 1);
    cairo_move_to(cr, 0, -y);
    pango_cairo_show_layout(cr, layout);
    cairo_surface_flush(surface);
    const uint8_t *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    for (int row = 0; row < HEIGHT; row++) {
        for (int column = 0; column < WIDTH; column++) {
            uint32_t pixel;
            memcpy(&pixel, pixels + row * stride + column * 4, sizeof(pixel));
            int a = (pixel >> 24) & 255, offset = (row * WIDTH + column) * 4;
            output[offset] = a ? MIN(255, (((pixel >> 16) & 255) * 255 + a / 2) / a) : 0;
            output[offset + 1] = a ? MIN(255, (((pixel >> 8) & 255) * 255 + a / 2) / a) : 0;
            output[offset + 2] = a ? MIN(255, ((pixel & 255) * 255 + a / 2) / a) : 0;
            output[offset + 3] = a;
        }
    }
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}

static char *content(int rows) {
    GString *text = g_string_new("FIRST é e\u0301 日本語 مرحبا 👩🏽‍🚀\n");
    for (int index = 0; index < rows; index++)
        g_string_append_printf(text, "Row %05d: Latin e\u0301 中文 العربية 👩🏽‍🚀 — a complete paragraph.\n", index);
    g_string_append(text, "TAIL unique final sentence: 日本語 é 👩🏽‍🚀");
    return g_string_free(text, FALSE);
}

static int compare_sample(const char *text, int alignment, int char_wrap) {
    TATMetrics metrics;
    int lines;
    TATDocumentLayout *document = tat_document_create((const uint8_t *)text, (int)strlen(text),
        0, 0, 0, 13, WIDTH, char_wrap, alignment, 1, &metrics, &lines);
    assert(document);
    PangoLayout *expected = reference(text, WIDTH, alignment, char_wrap);
    int measured_width, measured_height;
    pango_layout_get_pixel_size(expected, &measured_width, &measured_height);
    assert(metrics.height == measured_height);
    assert(lines == pango_layout_get_line_count(expected));
    uint8_t actual[WIDTH * HEIGHT], wanted[WIDTH * HEIGHT];
    uint8_t actual_rgba[WIDTH * HEIGHT * 4], wanted_rgba[WIDTH * HEIGHT * 4];
    int offsets[] = { 0, metrics.height / 2, MAX(0, metrics.height - HEIGHT) };
    int maximum_visits = 0;
    for (int view = 0; view < 3; view++) {
        int visited = 0;
        assert(tat_document_render(document, actual, sizeof(actual), WIDTH, HEIGHT, 0,
                                   offsets[view], &visited));
        full_render(expected, wanted, 0, offsets[view]);
        assert(memcmp(actual, wanted, sizeof(actual)) == 0);
        assert(tat_document_render_rgba(document, actual_rgba, sizeof(actual_rgba), WIDTH, HEIGHT,
            0, offsets[view], .1, .2, .3, 1));
        full_rgba(expected, wanted_rgba, offsets[view]);
        assert(memcmp(actual_rgba, wanted_rgba, sizeof(actual_rgba)) == 0);
        assert(tat_document_selection(document, actual, sizeof(actual), WIDTH, HEIGHT, 0,
            offsets[view], 0, (int)strlen(text)));
        full_selection(expected, wanted, offsets[view], 0, (int)strlen(text));
        assert(memcmp(actual, wanted, sizeof(actual)) == 0);
        maximum_visits = MAX(maximum_visits, visited);
        assert(visited <= 16);
        for (int x = 0; x < WIDTH; x += 29) {
            int byte, trailing;
            pango_layout_xy_to_index(expected, x * PANGO_SCALE,
                (offsets[view] + 24) * PANGO_SCALE, &byte, &trailing);
            const char *cursor = text + byte;
            for (int index = 0; index < trailing && *cursor; index++) cursor = g_utf8_next_char(cursor);
            assert(tat_document_hit(document, x, offsets[view] + 24) == cursor - text);
        }
    }
    if (strlen(text) > 4096) assert(tat_document_hit(document, WIDTH, metrics.height - 1) > 4096);
    assert(!tat_document_render(document, actual, sizeof(actual), WIDTH, HEIGHT + 1, 0, 0, NULL));
    assert(!tat_document_render(document, actual, 1, WIDTH, HEIGHT, 0, 0, NULL));
    assert(tat_document_hit(document, NAN, 0) == -1);
    printf("PASS full Unicode document: bytes=%zu lines=%d height=%d alignment=%d char_wrap=%d visited<=%d\n",
        strlen(text), lines, metrics.height, alignment, char_wrap, maximum_visits);
    tat_document_destroy(document);
    g_object_unref(expected);
    return maximum_visits;
}

static int compare_double(const void *first, const void *second) {
    double a = *(const double *)first, b = *(const double *)second;
    return (a > b) - (a < b);
}

static void benchmark(const char *text, int rows) {
    double start = seconds();
    TATMetrics metrics;
    int lines;
    TATDocumentLayout *document = tat_document_create((const uint8_t *)text, (int)strlen(text),
        0, 0, 0, 13, WIDTH, 0, 0, 1, &metrics, &lines);
    assert(document);
    double preparation = seconds() - start;
    PangoLayout *expected = reference(text, WIDTH, 0, 0);
    start = seconds();
    int reference_width, reference_height;
    pango_layout_get_pixel_size(expected, &reference_width, &reference_height);
    double reference_preparation = seconds() - start;
    uint8_t tile[WIDTH * HEIGHT];
    int tail = MAX(0, metrics.height - HEIGHT), visited;
    double before[SAMPLES], after[SAMPLES];
    full_render(expected, tile, 0, tail); // Font/cache bootstrap is outside the timed samples.
    assert(tat_document_render(document, tile, sizeof(tile), WIDTH, HEIGHT, 0, tail, &visited));
    for (int sample = 0; sample < SAMPLES; sample++) {
        start = seconds();
        full_render(expected, tile, 0, tail);
        before[sample] = seconds() - start;
        start = seconds();
        assert(tat_document_render(document, tile, sizeof(tile), WIDTH, HEIGHT, 0, tail, &visited));
        after[sample] = seconds() - start;
    }
    qsort(before, SAMPLES, sizeof(double), compare_double);
    qsort(after, SAMPLES, sizeof(double), compare_double);
    printf("BENCH rows=%d bytes=%zu preparation_ms=%.3f reference_preparation_ms=%.3f reference_median_ms=%.3f reference_max_ms=%.3f "
           "indexed_median_ms=%.3f indexed_max_ms=%.3f visited=%d\n", rows, strlen(text),
        preparation * 1000, reference_preparation * 1000, before[SAMPLES / 2] * 1000, before[SAMPLES - 1] * 1000,
        after[SAMPLES / 2] * 1000, after[SAMPLES - 1] * 1000, visited);
    tat_document_destroy(document);
    g_object_unref(expected);
}

static void *run(void *unused) {
    (void)unused;
    for (int alignment = 0; alignment <= 3; alignment++)
        compare_sample("12345\n\nעברית\n4567\nLatin\n\r\n中文\u2028tail\n", alignment, 0);
    char *expected = content(1000);
    for (int alignment = 0; alignment <= 3; alignment++) compare_sample(expected, alignment, 0);
    compare_sample(expected, 0, 1);
    benchmark(expected, 1000);
    g_free(expected);
    char *stress = content(10000);
    compare_sample(stress, 0, 0);
    benchmark(stress, 10000);
    for (char *cursor = stress; *cursor; cursor++) if (*cursor == '\n') *cursor = ' ';
    compare_sample(stress, 0, 0);
    benchmark(stress, 1); // One externally large paragraph, not only many short paragraphs.
    g_free(stress);
    char *token = g_strnfill(100000, 'W');
    compare_sample(token, 0, 0);
    g_free(token);
    uint8_t invalid[] = { 0xff };
    TATMetrics metrics;
    int lines;
    assert(!tat_document_create(invalid, 1, 0, 0, 0, 13, WIDTH, 0, 0, 1, &metrics, &lines));
    atomic_store(&finished, 1);
    return NULL;
}

int main(void) {
    pthread_t worker;
    assert(pthread_create(&worker, NULL, run, NULL) == 0);
    int ticks = 0;
    while (!atomic_load(&finished)) { usleep(1000); ticks++; }
    assert(pthread_join(worker, NULL) == 0);
    assert(ticks > 0);
    printf("PASS dedicated worker completes while caller remains available: ticks=%d\n", ticks);
    return 0;
}
