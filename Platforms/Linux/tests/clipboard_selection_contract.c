#include "LinuxWindowBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    FILE *expected = fopen(argv[2], "rb");
    if (!expected) return 3;
    if (fseek(expected, 0, SEEK_END) != 0) return 4;
    long size = ftell(expected);
    rewind(expected);
    if (size <= 0 || size > 32 * 1024 * 1024) return 5;
    unsigned char *reference = malloc((size_t)size);
    if (!reference || fread(reference, 1, (size_t)size, expected) != (size_t)size) return 6;
    fclose(expected);
    unsigned char *received = NULL;
    int length = 0;
    tw_clipboard_prepare();
    int result = tw_clipboard_read_target(argv[1], &received, &length);
    int matches = result == 0 && length == size
        && memcmp(reference, received, (size_t)size) == 0;
    tw_clipboard_free(received);
    free(reference);
    if (!matches) fprintf(stderr, "clipboard target=%s status=%d length=%d expected=%ld\n",
                          argv[1], result, length, size);
    return matches ? 0 : 1;
}
