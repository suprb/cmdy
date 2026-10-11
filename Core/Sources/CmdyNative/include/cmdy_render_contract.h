#ifndef CMDY_RENDER_CONTRACT_H
#define CMDY_RENDER_CONTRACT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
intptr_t cmdy_render_segment_span(intptr_t width,intptr_t count);
uint8_t cmdy_render_boundaries_valid(const intptr_t *,size_t count);
uint8_t cmdy_render_segment_boundaries_valid(const intptr_t *,size_t count,intptr_t characters,intptr_t text_length);
intptr_t cmdy_render_cell_index(const intptr_t *,size_t count,intptr_t offset);
typedef struct CmdyRenderCellRange { intptr_t lower,upper; } CmdyRenderCellRange;
CmdyRenderCellRange cmdy_render_cell_range(const intptr_t *,size_t count,intptr_t offset,intptr_t length);
typedef struct CmdyRenderTextPolicy { uint8_t snaps,padding,nearest; float exponent,power; } CmdyRenderTextPolicy;
CmdyRenderTextPolicy cmdy_render_text_policy(uint8_t mode);
#ifdef __cplusplus
}
#endif
#endif
