#include "LinuxWindowBridge.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    TWExternalApp apps[TW_EXTERNAL_APP_LIMIT];
    char preferred[TW_EXTERNAL_APP_ID_CAPACITY];
    const int count = tw_external_apps_discover(apps, TW_EXTERNAL_APP_LIMIT,
                                                preferred, sizeof(preferred));
    if (count < 1 || strcmp(preferred, "threading-test-open.desktop") != 0) {
        fprintf(stderr, "directory default was not discovered: %s (%d)\n", preferred, count);
        return 3;
    }
    int found = 0;
    for (int index = 0; index < count; index++) {
        if (strcmp(apps[index].id, "threading-test-open.desktop") == 0) {
            found = strcmp(apps[index].name, "Threading Test Opener") == 0 &&
                    strcmp(apps[index].iconHint, "threading-test-icon") == 0;
        }
        if (strcmp(apps[index].id, "threading-test-file.desktop") == 0) {
            fprintf(stderr, "file-only app was offered for a directory\n");
            return 4;
        }
    }
    if (!found) return 5;

    char error[512];
    if (tw_external_app_launch("threading-test-open.desktop", argv[1], error,
                               sizeof(error)) != 0) {
        fprintf(stderr, "launch failed: %s\n", error);
        return 6;
    }
    if (tw_external_app_launch("threading-test-file.desktop", argv[1], error,
                               sizeof(error)) == 0) return 7;
    if (tw_external_app_launch("threading-test-open.desktop", "relative/path", error,
                               sizeof(error)) == 0) return 8;
    if (tw_external_app_launch("threading-test-open.desktop", argv[2], error,
                               sizeof(error)) == 0) return 9;
    return 0;
}
