#include "AppKitTextBridge.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const uint8_t text[] = "selectable";
    const uint8_t broken[] = "sel\nect\nabl\ne";
    TATFontMetrics font = {0};
    TATMetrics wrapped = {0}, authored = {0}, attributed = {0};
    if (!tat_font_metrics(1, 0, 0, 12, &font)) return 1;
    int width = (int)ceil(font.approximate_width * 3);
    if (!tat_measure_wrapped(text, (int)strlen((const char *)text), 1, 0, 0,
                             12, 8, width, 1, &wrapped)) return 2;
    if (!tat_measure_paragraphs(broken, (int)strlen((const char *)broken),
                                1, 0, 0, 12, 8, &authored)) return 3;
    TATStyleSpan span = {0};
    span.end_byte = (int)strlen((const char *)text);
    span.monospace = 1;
    span.pixel_size = 12;
    span.foreground_alpha = 1;
    if (!tat_attributed_measure_label(text, span.end_byte, &span, 1,
                                               width, 8, 1, &attributed)) return 4;
    if (wrapped.height != authored.height || attributed.height != authored.height) {
        fprintf(stderr, "character wrapping gained synthetic hyphens: plain=%d attributed=%d authored=%d\n",
                wrapped.height, attributed.height, authored.height);
        return 5;
    }
    puts("PASS plain and attributed character wrapping equals authored line breaks without synthetic hyphens");
    return 0;
}
