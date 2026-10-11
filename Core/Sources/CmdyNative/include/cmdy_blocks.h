#ifndef CMDY_ZIG_BLOCKS_H
#define CMDY_ZIG_BLOCKS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyZigBlock CmdyZigBlock;
typedef struct CmdyZigBlocks CmdyZigBlocks;
typedef void (*CmdyZigBlockLifetimeCallback)(void *, uint8_t);
typedef intptr_t (*CmdyZigRowMap)(void *, intptr_t);
typedef struct {
    uint64_t index;
    intptr_t prompt_row, input_row, input_col, command_row, end_row, exit_code;
    double started_at, finished_at;
    uint8_t has_input, has_end, has_exit, has_finished, running;
} CmdyZigBlockInfo;
CmdyZigBlock *cmdy_zig_block_create(uint64_t, intptr_t, double);
CmdyZigBlock *cmdy_zig_block_retain(CmdyZigBlock *);
void cmdy_zig_block_release(CmdyZigBlock *);
int32_t cmdy_zig_block_info(const CmdyZigBlock *, CmdyZigBlockInfo *);
int32_t cmdy_zig_block_set_info(CmdyZigBlock *, const CmdyZigBlockInfo *);
void *cmdy_zig_block_swift_context(const CmdyZigBlock *);
/* Same reference-transfer contract as cmdy_zig_image_associate. */
int32_t cmdy_zig_block_associate(CmdyZigBlock *, void *, CmdyZigBlockLifetimeCallback);
int32_t cmdy_zig_block_disassociate(CmdyZigBlock *, void *);
CmdyZigBlocks *cmdy_zig_blocks_create(void);
/* Free standalone trackers only. Terminal embedded trackers belong to terminal. */
void cmdy_zig_blocks_free(CmdyZigBlocks *);
size_t cmdy_zig_blocks_count(const CmdyZigBlocks *);
CmdyZigBlock *cmdy_zig_blocks_at(const CmdyZigBlocks *, size_t);
CmdyZigBlock *cmdy_zig_blocks_last_completed(const CmdyZigBlocks *);
uint8_t cmdy_zig_blocks_running(const CmdyZigBlocks *);
int32_t cmdy_zig_blocks_prompt_started(CmdyZigBlocks *, intptr_t, double);
void cmdy_zig_blocks_prompt_ended(CmdyZigBlocks *, intptr_t, intptr_t);
uint8_t cmdy_zig_blocks_command_started(CmdyZigBlocks *, intptr_t);
CmdyZigBlock *cmdy_zig_blocks_command_finished(CmdyZigBlocks *, intptr_t, intptr_t, uint8_t, double);
void cmdy_zig_blocks_rebase(CmdyZigBlocks *, intptr_t);
void cmdy_zig_blocks_reset(CmdyZigBlocks *);
int32_t cmdy_zig_blocks_remap(CmdyZigBlocks *, void *, CmdyZigRowMap);
#ifdef __cplusplus
}
#endif
#endif
