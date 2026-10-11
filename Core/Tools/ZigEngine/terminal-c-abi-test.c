#include "cmdy_native.h"
#include <assert.h>
#include <stddef.h>
#include <string.h>

_Static_assert(sizeof(CmdyZigCell) == 24, "cell ABI layout");
_Static_assert(offsetof(CmdyZigCell, width) == 18, "cell width offset");
_Static_assert(sizeof(CmdyZigHost) == 24, "host ABI layout");
_Static_assert(sizeof(CmdyZigEvent) == 64, "event ABI layout");
typedef struct Observer {
    CmdyZigTerminal *terminal;
    unsigned sends, bells, changes;
    unsigned free_on_bell;
    unsigned reenter_on_bell;
    unsigned payload_releases;
    char reply[128];
    size_t reply_len;
} Observer;
static void release_payload(void *context) {
    Observer *observer = context;
    observer->payload_releases++;
    /* Reenter while the outer destroy is releasing its native image rows. */
    cmdy_zig_terminal_free(observer->terminal);
    assert(cmdy_zig_terminal_feed(observer->terminal, NULL, 0) == CMDY_ZIG_DISPOSED);
    assert(cmdy_zig_terminal_buffer(observer->terminal, 0) == NULL);
    assert(cmdy_zig_terminal_parser(observer->terminal) == NULL);
    assert(cmdy_zig_terminal_blocks(observer->terminal) == NULL);
    assert(cmdy_zig_terminal_graphics(observer->terminal) == NULL);
    assert(cmdy_cols(observer->terminal) == -1);
    assert(cmdy_rows(observer->terminal) == -1);
    assert(cmdy_buffer_line_count(observer->terminal) == -1);
    assert(cmdy_block_count(observer->terminal) == -1);
    size_t length = 100;
    assert(cmdy_zig_terminal_title(observer->terminal, &length) == NULL && length == 0);
}
static void event(void *context, const CmdyZigEvent *e) {
    Observer *o = context;
    if (e->kind == CMDY_ZIG_EVENT_SEND) {
        assert(e->length <= sizeof(o->reply) - o->reply_len);
        memcpy(o->reply + o->reply_len, e->bytes, e->length);
        o->reply_len += e->length;
        o->sends++;
    } else if (e->kind == CMDY_ZIG_EVENT_BELL) {
        o->bells++;
        if (o->reenter_on_bell) {
            o->reenter_on_bell = 0;
            const uint8_t nested[] = {'N'};
            assert(cmdy_zig_terminal_feed(o->terminal, nested, sizeof(nested)) == CMDY_ZIG_OK);
        }
        if (o->free_on_bell) {
            cmdy_zig_terminal_free(o->terminal);
            assert(cmdy_zig_terminal_feed(o->terminal, NULL, 0) == CMDY_ZIG_DISPOSED);
            o->terminal = NULL;
        }
    } else if (e->kind == CMDY_ZIG_EVENT_CONTENT_CHANGED) o->changes++;
}
int main(void) {
    assert(cmdy_zig_engine_abi_version() == 1);
    assert(cmdy_zig_terminal_feed(NULL, NULL, 0) == CMDY_ZIG_INVALID_INPUT);
    Observer o = {0};
    o.terminal = cmdy_zig_terminal_create(8, 4, 20);
    assert(o.terminal);
    CmdyZigHost host = {&o, event, NULL};
    assert(cmdy_zig_terminal_set_host(o.terminal, &host) == CMDY_ZIG_OK);
    const uint8_t text[] = "hello\033[6n";
    assert(cmdy_zig_terminal_feed(o.terminal, text, sizeof(text)-1) == CMDY_ZIG_OK);
    assert(o.sends == 1 && o.reply_len == 6 && memcmp(o.reply, "\033[1;6R", 6) == 0);
    assert(cmdy_zig_terminal_feed(o.terminal, NULL, 1) == CMDY_ZIG_INVALID_INPUT);
    assert(cmdy_zig_terminal_set_int(o.terminal, 999, 1) == CMDY_ZIG_INVALID_INPUT);
    assert(cmdy_zig_terminal_get_int(o.terminal, CMDY_ZIG_AUTO_WRAP) == 1);
    assert(cmdy_zig_terminal_set_int(o.terminal, CMDY_ZIG_AUTO_WRAP, 0) == CMDY_ZIG_OK);
    assert(cmdy_zig_terminal_get_int(o.terminal, CMDY_ZIG_AUTO_WRAP) == 0);
    CmdyZigSpan dirty;
    assert(cmdy_zig_terminal_dirty(o.terminal, 1, &dirty) == 1);
    assert(cmdy_zig_terminal_dirty(o.terminal, 0, &dirty) == 0);
    o.reenter_on_bell = 1;
    const uint8_t bell[] = {7};
    assert(cmdy_zig_terminal_feed(o.terminal, bell, 1) == CMDY_ZIG_OK);
    assert(o.bells == 1);
    o.free_on_bell = 1;
    assert(cmdy_zig_terminal_feed(o.terminal, bell, 1) == CMDY_ZIG_OK);
    assert(o.terminal == NULL && o.bells == 2);
    o.terminal = cmdy_zig_terminal_create(2, 2, 0);
    assert(o.terminal);
    const uint8_t encoded[] = {1, 2, 3, 4};
    CmdyZigPayload *payload = cmdy_zig_payload_create_host(1, encoded, sizeof(encoded), 0, 0, &o, release_payload);
    assert(payload);
    CmdyZigImage *image = cmdy_zig_image_create_host(payload, 1, 1, 0);
    assert(image);
    cmdy_zig_payload_release(payload);
    /* Destruction reaches this after it has already destroyed normal rows. */
    CmdyZigLine *line = cmdy_zig_buffer_line(cmdy_zig_terminal_buffer(o.terminal, 2), 0);
    assert(line);
    assert(cmdy_zig_line_set_images(line, &image, 1, 1) == CMDY_ZIG_OK);
    cmdy_zig_image_release(image);
    cmdy_zig_line_release(line);
    cmdy_zig_terminal_free(o.terminal);
    o.terminal = NULL;
    assert(o.payload_releases == 1);
    cmdy_zig_terminal_free(NULL);
    return 0;
}
