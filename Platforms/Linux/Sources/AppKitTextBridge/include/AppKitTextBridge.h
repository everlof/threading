#ifndef APPKIT_TEXT_BRIDGE_H
#define APPKIT_TEXT_BRIDGE_H

#include <stdint.h>

typedef struct {
    int width;
    int height;
    int baseline;
    int glyphs;
} TATMetrics;

typedef struct {
    double ascent;
    double descent;
    double approximate_width;
} TATFontMetrics;

int tat_font_metrics(int monospace, int weight, double pixel_size, TATFontMetrics *result);

// Inputs are UTF-8 bytes, not a NUL-terminated string. The bridge rejects out-of-range
// dimensions before Pango or Cairo allocate anything.
// weight: regular=0, medium=1, semibold=2, bold=3.
int tat_measure(const uint8_t *utf8, int length, int monospace, int weight,
                double pixel_size, TATMetrics *result);
// Measures authored line breaks for a wrapping label, without an imposed wrap width.
// The visible line count is bounded to 1...8, matching tat_render.
int tat_measure_paragraphs(const uint8_t *utf8, int length, int monospace, int weight,
                           double pixel_size, int maximum_lines, TATMetrics *result);
// Like tat_measure_paragraphs, but wraps at a positive width in device pixels.
// Both the wrap width and the result stay within the renderer's 2048x128 bounds.
int tat_measure_wrapped(const uint8_t *utf8, int length, int monospace, int weight,
                        double pixel_size, int maximum_lines, int wrap_width,
                        int char_wrapping, TATMetrics *result);
// mode: clipping=0, tail=1, word-wrap-with-ellipsis=2,
// char-wrap-with-ellipsis=3, head=4, middle=5,
// word-wrap-without-ellipsis=6, char-wrap-without-ellipsis=7.
// alignment: leading=0, center=1, trailing=2, justified=3. maximum_lines is 1...8.
int tat_render(uint8_t *coverage, int capacity, int visible_width, int visible_height,
               int layout_width, int clip_x, int clip_y, const uint8_t *utf8, int length,
               int monospace, int weight, double pixel_size, int mode, int alignment,
               int maximum_lines);

// A complete, ordered partition of at most 4096 UTF-8 bytes into at most 64 style runs.
// Pango shapes the whole string with run attributes, so a change of color does not require
// drawing a second, independently shaped substring. Colors are straight sRGB in 0...1.
typedef struct {
    int32_t start_byte;
    int32_t end_byte;
    int32_t monospace;
    int32_t weight;
    int32_t underline;
    double pixel_size;
    double kern;
    double foreground_red, foreground_green, foreground_blue, foreground_alpha;
    double background_red, background_green, background_blue, background_alpha;
} TATStyleSpan;

int tat_attributed_measure(const uint8_t *utf8, int length,
                           const TATStyleSpan *spans, int span_count, TATMetrics *result);
int tat_attributed_measure_wrapped(const uint8_t *utf8, int length,
                                   const TATStyleSpan *spans, int span_count,
                                   int wrap_width, int maximum_lines, int char_wrapping,
                                   TATMetrics *result);
// Writes visible straight-alpha RGBA pixels. The caller owns clipping and composition into
// its graphics state. Both APIs cap the shaped string to eight visible lines.
// layout_width=0 uses the natural width for draw(at:); a positive width enables the line
// mode and alignment used by draw(in:). mode matches tat_render's 0...7 convention.
int tat_attributed_render(uint8_t *rgba, int capacity, int visible_width, int visible_height,
                          int layout_width, int clip_x, int clip_y, int mode, int alignment,
                          int maximum_lines, const uint8_t *utf8, int length,
                          const TATStyleSpan *spans, int span_count);

#endif
