#include "LinuxWindowBridge.h"

#ifdef __linux__
#include <gio/gio.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

enum { ICON_INPUT_LIMIT = 256 * 1024, ICON_SOURCE_LIMIT = 1024,
       ICON_OUTPUT_LIMIT = 64, ICON_OUTPUT_BYTES = 64 * 64 * 4 };

typedef struct { gboolean rejected; } IconLoad;

static void icon_size_prepared(GdkPixbufLoader *loader, int width, int height, void *data) {
    IconLoad *load = data;
    if (width <= 0 || height <= 0 || width > ICON_SOURCE_LIMIT ||
        height > ICON_SOURCE_LIMIT) {
        load->rejected = TRUE;
        return;
    }
    const double scale = fmin(1.0, fmin((double)ICON_OUTPUT_LIMIT / width,
                                      (double)ICON_OUTPUT_LIMIT / height));
    const int outputWidth = fmax(1, (int)lround(width * scale));
    const int outputHeight = fmax(1, (int)lround(height * scale));
    gdk_pixbuf_loader_set_size(loader, outputWidth, outputHeight);
}

static int decode_icon(const char *path, uint8_t *rgba, int *width, int *height) {
    const char *type = NULL;
    if (g_str_has_suffix(path, ".png") || g_str_has_suffix(path, ".PNG")) type = "png";
    if (g_str_has_suffix(path, ".svg") || g_str_has_suffix(path, ".SVG")) type = "svg";
    if (!type) return -1;
    FILE *file = fopen(path, "rb");
    if (!file) return -1;
    struct stat state;
    if (fstat(fileno(file), &state) != 0 || !S_ISREG(state.st_mode) ||
        state.st_size <= 0 || state.st_size > ICON_INPUT_LIMIT) {
        fclose(file);
        return -1;
    }
    uint8_t *input = g_malloc(ICON_INPUT_LIMIT + 1);
    const size_t length = fread(input, 1, ICON_INPUT_LIMIT + 1, file);
    const int readError = ferror(file);
    fclose(file);
    if (readError || length == 0 || length > ICON_INPUT_LIMIT) {
        g_free(input);
        return -1;
    }
    if (strcmp(type, "png") == 0) {
        static const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
        if (length < 24 || memcmp(input, signature, sizeof(signature)) != 0) {
            g_free(input);
            return -1;
        }
        const uint32_t sourceWidth = ((uint32_t)input[16] << 24) | ((uint32_t)input[17] << 16) |
                                     ((uint32_t)input[18] << 8) | input[19];
        const uint32_t sourceHeight = ((uint32_t)input[20] << 24) | ((uint32_t)input[21] << 16) |
                                      ((uint32_t)input[22] << 8) | input[23];
        if (!sourceWidth || !sourceHeight || sourceWidth > ICON_SOURCE_LIMIT ||
            sourceHeight > ICON_SOURCE_LIMIT) {
            g_free(input);
            return -1;
        }
    }

    GError *error = NULL;
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new_with_type(type, &error);
    if (!loader) {
        g_clear_error(&error);
        g_free(input);
        return -1;
    }
    IconLoad load = {FALSE};
    g_signal_connect(loader, "size-prepared", G_CALLBACK(icon_size_prepared), &load);
    gboolean valid = TRUE;
    // A small write bound lets the size callback refuse before the remainder of an oversized
    // image is handed to its loader. The source byte cap also bounds SVG parser input.
    for (size_t offset = 0; offset < length && valid && !load.rejected; offset += 4096) {
        const size_t chunk = MIN((size_t)4096, length - offset);
        valid = gdk_pixbuf_loader_write(loader, input + offset, chunk, &error);
    }
    g_free(input);
    valid = valid && !load.rejected && gdk_pixbuf_loader_close(loader, &error);
    if (!valid) {
        g_clear_error(&error);
        g_object_unref(loader);
        return -1;
    }
    GdkPixbuf *decoded = gdk_pixbuf_loader_get_pixbuf(loader);
    if (!decoded || gdk_pixbuf_get_bits_per_sample(decoded) != 8 ||
        gdk_pixbuf_get_n_channels(decoded) < 3 || gdk_pixbuf_get_n_channels(decoded) > 4) {
        g_object_unref(loader);
        return -1;
    }
    const int sourceWidth = gdk_pixbuf_get_width(decoded);
    const int sourceHeight = gdk_pixbuf_get_height(decoded);
    if (sourceWidth <= 0 || sourceHeight <= 0 || sourceWidth > ICON_SOURCE_LIMIT ||
        sourceHeight > ICON_SOURCE_LIMIT) {
        g_object_unref(loader);
        return -1;
    }
    GdkPixbuf *scaled = NULL;
    if (sourceWidth > ICON_OUTPUT_LIMIT || sourceHeight > ICON_OUTPUT_LIMIT) {
        const double scale = fmin((double)ICON_OUTPUT_LIMIT / sourceWidth,
                                  (double)ICON_OUTPUT_LIMIT / sourceHeight);
        scaled = gdk_pixbuf_scale_simple(decoded, fmax(1, (int)lround(sourceWidth * scale)),
                                        fmax(1, (int)lround(sourceHeight * scale)),
                                        GDK_INTERP_BILINEAR);
        decoded = scaled;
    }
    if (!decoded) {
        g_object_unref(loader);
        return -1;
    }
    const int outputWidth = gdk_pixbuf_get_width(decoded);
    const int outputHeight = gdk_pixbuf_get_height(decoded);
    const int channels = gdk_pixbuf_get_n_channels(decoded);
    const int stride = gdk_pixbuf_get_rowstride(decoded);
    const uint8_t *pixels = gdk_pixbuf_read_pixels(decoded);
    for (int y = 0; y < outputHeight; y++) {
        for (int x = 0; x < outputWidth; x++) {
            const uint8_t *source = pixels + y * stride + x * channels;
            uint8_t *target = rgba + (y * outputWidth + x) * 4;
            target[0] = source[0]; target[1] = source[1]; target[2] = source[2];
            target[3] = channels == 4 ? source[3] : 255;
        }
    }
    if (scaled) g_object_unref(scaled);
    g_object_unref(loader);
    *width = outputWidth;
    *height = outputHeight;
    return 0;
}

static gboolean safe_icon_name(const char *name) {
    const size_t length = strnlen(name, TW_EXTERNAL_APP_ICON_CAPACITY);
    if (length == 0 || length >= TW_EXTERNAL_APP_ICON_CAPACITY) return FALSE;
    for (const unsigned char *letter = (const unsigned char *)name; *letter; letter++) {
        if (!g_ascii_isalnum(*letter) && *letter != '-' && *letter != '_' && *letter != '.')
            return FALSE;
    }
    return strcmp(name, ".") != 0 && strcmp(name, "..") != 0;
}

static char *desktop_icon_theme(void) {
    GSettingsSchemaSource *source = g_settings_schema_source_get_default();
    if (!source) return NULL;
    GSettingsSchema *schema = g_settings_schema_source_lookup(
        source, "org.gnome.desktop.interface", TRUE);
    if (!schema) return NULL;
    if (!g_settings_schema_has_key(schema, "icon-theme")) {
        g_settings_schema_unref(schema);
        return NULL;
    }
    GSettings *settings = g_settings_new_full(schema, NULL, NULL);
    char *theme = g_settings_get_string(settings, "icon-theme");
    g_object_unref(settings);
    g_settings_schema_unref(schema);
    if (!theme || !safe_icon_name(theme)) {
        g_free(theme);
        return NULL;
    }
    return theme;
}

static int themed_icon(const char *name, uint8_t *rgba, int *width, int *height) {
    if (!safe_icon_name(name)) return -1;
    char *stem = g_strdup(name);
    const size_t stemLength = strlen(stem);
    if (stemLength > 4 && (g_str_has_suffix(stem, ".png") ||
                           g_str_has_suffix(stem, ".svg"))) stem[stemLength - 4] = '\0';
    const char *const sizes[] = {"64x64", "48x48", "128x128", "32x32", "256x256",
                                  "scalable"};
    const char *const extensions[] = {"png", "svg"};
    char *theme = desktop_icon_theme();
    const char *const themes[] = {theme, "hicolor", "Adwaita"};
    const char *systemCounted[8] = {g_get_user_data_dir()};
    int rootCount = 1;
    const char *const *system = g_get_system_data_dirs();
    for (int index = 0; system[index] && rootCount < 8; index++)
        systemCounted[rootCount++] = system[index];
    for (int root = 0; root < rootCount; root++) {
        if (!systemCounted[root] || strlen(systemCounted[root]) > 2048) continue;
        for (int themeIndex = 0; themeIndex < 3; themeIndex++) {
            const char *candidateTheme = themes[themeIndex];
            if (!candidateTheme || !safe_icon_name(candidateTheme)) continue;
            for (int size = 0; size < 6; size++) {
                for (int extension = 0; extension < 2; extension++) {
                    char *filename = g_strdup_printf("%s.%s", stem, extensions[extension]);
                    char *path = g_build_filename(systemCounted[root], "icons", candidateTheme,
                                                  sizes[size], "apps", filename, NULL);
                    g_free(filename);
                    const int result = decode_icon(path, rgba, width, height);
                    g_free(path);
                    if (result == 0) { g_free(stem); g_free(theme); return 0; }
                }
            }
        }
        for (int extension = 0; extension < 2; extension++) {
            char *filename = g_strdup_printf("%s.%s", stem, extensions[extension]);
            char *path = g_build_filename(systemCounted[root], "pixmaps", filename, NULL);
            g_free(filename);
            const int result = decode_icon(path, rgba, width, height);
            g_free(path);
            if (result == 0) { g_free(stem); g_free(theme); return 0; }
        }
    }
    g_free(stem);
    g_free(theme);
    return -1;
}

int tw_external_app_icon(const char *hint, uint8_t *rgba, int capacity,
                         int *width, int *height) {
    if (!hint || !rgba || !width || !height || capacity < ICON_OUTPUT_BYTES ||
        strnlen(hint, TW_EXTERNAL_APP_ICON_CAPACITY) >= TW_EXTERNAL_APP_ICON_CAPACITY ||
        !g_utf8_validate(hint, -1, NULL)) return -1;
    if (g_path_is_absolute(hint)) return decode_icon(hint, rgba, width, height);
    return themed_icon(hint, rgba, width, height);
}
#endif
