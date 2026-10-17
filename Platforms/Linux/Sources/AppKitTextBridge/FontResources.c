#include "AppKitTextBridge.h"
#ifdef __linux__
#include <fontconfig/fontconfig.h>
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>

int tat_register_ui_fonts(const char *regular_path, const char *italic_path) {
    if (!regular_path || !italic_path) return 0;
    FcConfig *config = FcConfigGetCurrent();
    if (!config || !FcConfigAppFontAddFile(config, (const FcChar8 *)regular_path) ||
        !FcConfigAppFontAddFile(config, (const FcChar8 *)italic_path)) return 0;
    // A native diagnostic may have measured text before constructing its first NSFont.
    // Invalidate that map's cached matches once; subsequent labels only select a weight.
    PangoFontMap *map = pango_cairo_font_map_get_default();
    if (PANGO_IS_FC_FONT_MAP(map)) pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
    return 1;
}
#else
int tat_register_ui_fonts(const char *regular_path, const char *italic_path) { return 0; }
#endif
