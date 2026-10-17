#ifndef TAT_LABEL_LAYOUT_H
#define TAT_LABEL_LAYOUT_H

#ifdef __linux__
#include <pango/pangocairo.h>

// Shared by plain/attributed drawing and selectable-label hit testing. A clipped line is
// shaped whole, then cropped by the bounded destination. Pango's single-paragraph flag alone
// does not prevent word wrapping. AppKit aligns a fitting line, but starts an overflowing
// clipped line at its leading edge even for centered/right-aligned labels.
static inline void tat_configure_label_layout(PangoLayout *layout, int width, int mode,
                                              int alignment, int lines) {
    if (mode == 8) {
        pango_layout_set_width(layout, -1);
        pango_layout_set_single_paragraph_mode(layout, FALSE);
        return;
    }
    pango_layout_set_alignment(layout, alignment == 1 ? PANGO_ALIGN_CENTER :
                                        alignment == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
    pango_layout_set_justify(layout, alignment == 3);
    if (mode == 0) {
        pango_layout_set_single_paragraph_mode(layout, TRUE);
        pango_layout_set_width(layout, -1);
        int natural_width, natural_height;
        pango_layout_get_size(layout, &natural_width, &natural_height);
        pango_layout_set_width(layout, MAX(width * PANGO_SCALE, natural_width));
        return;
    }
    pango_layout_set_width(layout, width * PANGO_SCALE);
    if (mode == 2 || mode == 3 || mode == 6 || mode == 7) {
        pango_layout_set_wrap(layout, mode == 3 || mode == 7 ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
        pango_layout_set_height(layout, -lines);
        pango_layout_set_ellipsize(layout, mode == 2 || mode == 3
                                  ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE);
    } else {
        pango_layout_set_single_paragraph_mode(layout, TRUE);
        pango_layout_set_height(layout, -1);
        pango_layout_set_ellipsize(layout, mode == 1 ? PANGO_ELLIPSIZE_END :
                                           mode == 4 ? PANGO_ELLIPSIZE_START : PANGO_ELLIPSIZE_MIDDLE);
    }
}
#endif
#endif
