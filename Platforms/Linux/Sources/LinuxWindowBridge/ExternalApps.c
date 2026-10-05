#include "LinuxWindowBridge.h"

#ifdef __linux__
#include <gio/gio.h>
#include <string.h>

static const char *directory_mime = "inode/directory";

static int copy_text(char *destination, size_t capacity, const char *source) {
    if (!source || !g_utf8_validate(source, -1, NULL)) return 0;
    const size_t length = strlen(source);
    if (length == 0 || length >= capacity) return 0;
    memcpy(destination, source, length + 1);
    return 1;
}

static void icon_hint(GAppInfo *app, char *destination, size_t capacity) {
    GIcon *icon = g_app_info_get_icon(app);
    if (!icon) return;
    if (G_IS_FILE_ICON(icon)) {
        GFile *file = g_file_icon_get_file(G_FILE_ICON(icon));
        char *path = g_file_get_path(file);
        if (path) {
            (void)copy_text(destination, capacity, path);
            g_free(path);
        }
    } else if (G_IS_THEMED_ICON(icon)) {
        const char *const *names = g_themed_icon_get_names(G_THEMED_ICON(icon));
        if (names && names[0]) (void)copy_text(destination, capacity, names[0]);
    }
}

static int append_app(GAppInfo *app, TWExternalApp *apps, int count, int capacity) {
    if (!app || count >= capacity) return count;
    const char *id = g_app_info_get_id(app);
    const char *name = g_app_info_get_display_name(app);
    if (!id || !name) return count;
    for (int index = 0; index < count; index++) {
        if (strcmp(apps[index].id, id) == 0) return count;
    }
    TWExternalApp *item = &apps[count];
    memset(item, 0, sizeof(*item));
    if (!copy_text(item->id, sizeof(item->id), id) ||
        !copy_text(item->name, sizeof(item->name), name)) return count;
    icon_hint(app, item->iconHint, sizeof(item->iconHint));
    return count + 1;
}

int tw_external_apps_discover(TWExternalApp *apps, int capacity,
                              char *defaultID, int defaultCapacity) {
    if (!apps || capacity <= 0 || capacity > TW_EXTERNAL_APP_LIMIT ||
        !defaultID || defaultCapacity <= 0) return -1;
    memset(apps, 0, (size_t)capacity * sizeof(*apps));
    defaultID[0] = '\0';

    int count = 0;
    GAppInfo *preferred = g_app_info_get_default_for_type(directory_mime, FALSE);
    if (preferred) {
        const char *id = g_app_info_get_id(preferred);
        if (id && copy_text(defaultID, (size_t)defaultCapacity, id)) {
            count = append_app(preferred, apps, count, capacity);
            if (count == 0) defaultID[0] = '\0';
        }
        g_object_unref(preferred);
    }

    GList *handlers = g_app_info_get_all_for_type(directory_mime);
    for (GList *node = handlers; node && count < capacity; node = node->next) {
        count = append_app(G_APP_INFO(node->data), apps, count, capacity);
    }
    g_list_free_full(handlers, g_object_unref);
    return count;
}

static void write_error(char *destination, int capacity, const char *message) {
    if (destination && capacity > 0) g_strlcpy(destination, message, (size_t)capacity);
}

int tw_external_app_launch(const char *appID, const char *directory,
                           char *error, int errorCapacity) {
    if (error && errorCapacity > 0) error[0] = '\0';
    if (!appID || !directory || !error || errorCapacity <= 0 ||
        strnlen(appID, TW_EXTERNAL_APP_ID_CAPACITY) >= TW_EXTERNAL_APP_ID_CAPACITY ||
        strnlen(directory, 4097) > 4096 || !g_utf8_validate(appID, -1, NULL) ||
        !g_utf8_validate(directory, -1, NULL) || !g_path_is_absolute(directory)) {
        write_error(error, errorCapacity, "Invalid app ID or directory path.");
        return 1;
    }
    if (!g_file_test(directory, G_FILE_TEST_IS_DIR)) {
        write_error(error, errorCapacity, "The project directory no longer exists.");
        return 2;
    }

    GAppInfo *selected = NULL;
    GList *handlers = g_app_info_get_all_for_type(directory_mime);
    for (GList *node = handlers; node; node = node->next) {
        GAppInfo *candidate = G_APP_INFO(node->data);
        const char *id = g_app_info_get_id(candidate);
        if (id && strcmp(id, appID) == 0) {
            selected = g_object_ref(candidate);
            break;
        }
    }
    g_list_free_full(handlers, g_object_unref);
    if (!selected) {
        write_error(error, errorCapacity, "That app no longer handles project directories.");
        return 3;
    }

    GFile *folder = g_file_new_for_path(directory);
    GList *files = g_list_append(NULL, folder);
    GError *launchError = NULL;
    const gboolean launched = g_app_info_launch(selected, files, NULL, &launchError);
    g_list_free(files);
    g_object_unref(folder);
    g_object_unref(selected);
    if (!launched) {
        write_error(error, errorCapacity,
                    launchError ? launchError->message : "The app could not be opened.");
        g_clear_error(&launchError);
        return 4;
    }
    return 0;
}
#endif
