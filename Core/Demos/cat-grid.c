/* cat-grid — the lib_cmdy demo: cat a VT byte stream (stdin) into an
 * embedded CmdyCore, then print the resulting grid and blocks.
 *
 *   printf 'hello\x1b[31m world\x1b]133;A\x07' | ./cat-grid 40 10
 */
#include "../include/cmdy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    int cols = argc > 1 ? atoi(argv[1]) : 80;
    int rows = argc > 2 ? atoi(argv[2]) : 24;
    cmdy_t t = cmdy_create(cols, rows);

    uint8_t buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, stdin)) > 0) {
        cmdy_feed(t, buf, n);
    }

    int32_t top = cmdy_live_top_row(t);
    int32_t total = cmdy_buffer_line_count(t);
    printf("┌ cmdy %dx%d — %d buffer lines, cursor (%d,%d)\n",
           cmdy_cols(t), cmdy_rows(t), total,
           cmdy_cursor_row(t), cmdy_cursor_col(t));

    char line[4096];
    for (int32_t r = top; r < total; r++) {
        long len = cmdy_line_text(t, r, line, sizeof line);
        if (len < 0) break;
        printf("│%s\n", line);
    }

    int32_t blocks = cmdy_block_count(t);
    printf("└ %d block(s)\n", blocks);
    for (int32_t i = 0; i < blocks; i++) {
        int32_t prompt, cmd, end, exit_code, running;
        if (cmdy_block_get(t, i, &prompt, &cmd, &end, &exit_code, &running) == 0) {
            printf("  block %d: prompt@%d cmd@%d end@%d exit=%d%s\n",
                   i, prompt, cmd, end, exit_code, running ? " (running)" : "");
        }
    }

    cmdy_free(t);
    return 0;
}
