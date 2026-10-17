#ifndef TAT_FONT_FAMILY_H
#define TAT_FONT_FAMILY_H

// Every UI text path uses the same family, including worker-owned document maps. The
// fixed-cell terminal has its own renderer and keeps its explicit monospaced face.
static inline const char *tat_font_family(int monospace) {
    return monospace ? "DejaVu Sans Mono" : "Inter Variable, DejaVu Sans";
}
#endif
