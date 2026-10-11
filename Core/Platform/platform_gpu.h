#ifndef CMDY_PLATFORM_GPU_H
#define CMDY_PLATFORM_GPU_H
#include <stdint.h>
#include <stddef.h>
/* A deliberately mechanical Apple API bridge. Resource ownership, cache
 * policy, geometry, allocation decisions, and encoding order live in Zig. */
void *cmdy_gpu_apple_retain(const void *);
void cmdy_gpu_apple_release(const void *);
void *cmdy_gpu_apple_weak_create(const void *);
void *cmdy_gpu_apple_weak_load(const void *); /* +1 or NULL */
void *cmdy_gpu_apple_queue(const void *device);
void *cmdy_gpu_apple_library(const void *device,const char *source,char *error,size_t capacity);
void *cmdy_gpu_apple_pipeline(const void *device,const void *library,const char *vertex,const char *fragment,const char *label,uint64_t format,size_t samples,uint8_t blend,char *error,size_t capacity);
void *cmdy_gpu_apple_sampler(const void *device,uint8_t nearest);
void *cmdy_gpu_apple_texture(const void *device,size_t width,size_t height,size_t pages,uint64_t format,uint8_t render_target,uint8_t private_storage);
void cmdy_gpu_apple_texture_write(const void *texture,size_t x,size_t y,size_t width,size_t height,size_t slice,const void *bytes,size_t bytes_per_row);
/* Completed shared BGRA8 target only. Policy/ownership remain with the caller. */
uint8_t cmdy_gpu_apple_texture_read_bgra(const void *texture,void *bytes,size_t length);
size_t cmdy_gpu_apple_texture_bytes(const void *texture);
size_t cmdy_gpu_apple_texture_width(const void *texture);
size_t cmdy_gpu_apple_texture_height(const void *texture);
void *cmdy_gpu_apple_buffer(const void *device,size_t length);
void cmdy_gpu_apple_buffer_write(const void *buffer,size_t offset,const void *bytes,size_t length);
void *cmdy_gpu_apple_command_buffer(const void *queue);
void *cmdy_gpu_apple_pass(const void *texture);
typedef struct {
    const void *device;
    size_t width, height, samples;
    uint64_t format;
} CmdyGpuAppleTargetInfo;
/* Copy the descriptor and validate its color output against an optional
 * CAMetalDrawable. Returned descriptor is +1; info.device is borrowed. */
void *cmdy_gpu_apple_capture_pass(const void *pass,const void *drawable,CmdyGpuAppleTargetInfo *info);
/* Layer acquisition uses bounded, asynchronous presentation. Each returned
 * object is +1. Only next_drawable can wait, and the render worker calls it. */
void *cmdy_gpu_apple_layer_retain(const void *layer);
void *cmdy_gpu_apple_layer_next_drawable(const void *layer);
void *cmdy_gpu_apple_drawable_pass(const void *drawable);
uint64_t cmdy_gpu_apple_drawable_id(const void *drawable);
void cmdy_gpu_apple_pass_clear(const void *pass,double r,double g,double b,double a);
void *cmdy_gpu_apple_encoder(const void *command_buffer,const void *pass);
void cmdy_gpu_apple_encoder_scissor(const void *encoder,size_t x,size_t y,size_t width,size_t height);
void cmdy_gpu_apple_encoder_pipeline(const void *encoder,const void *pipeline);
void cmdy_gpu_apple_encoder_vertex_buffer(const void *encoder,const void *buffer,size_t offset,size_t index);
void cmdy_gpu_apple_encoder_bytes(const void *encoder,const void *bytes,size_t length,size_t index,uint8_t fragment);
void cmdy_gpu_apple_encoder_texture(const void *encoder,const void *texture,size_t index);
void cmdy_gpu_apple_encoder_sampler(const void *encoder,const void *sampler,size_t index);
void cmdy_gpu_apple_encoder_draw(const void *encoder,size_t count);
void cmdy_gpu_apple_encoder_end(const void *encoder);
typedef void (*CmdyGpuAppleTask)(void *context);
void cmdy_gpu_apple_scope(CmdyGpuAppleTask,void *context);
double cmdy_gpu_apple_uptime(void);
/* Current worker only: 0 utility, 1 user initiated, 2 user interactive.
 * Returns a pthread error code; rejects the main thread. Policy lives in Zig. */
int32_t cmdy_gpu_apple_set_thread_qos(uint8_t priority);
/* Optional, lazily created one-shot deadline hint. Arm/cancel never wait.
 * Destroy cancels and drains callbacks; never call it from the timer callback.
 * The caller owns context until destroy returns. A null creation means fallback. */
void *cmdy_gpu_apple_wakeup_create(CmdyGpuAppleTask,void *context);
void cmdy_gpu_apple_wakeup_arm(void *,uint64_t delay_ns);
void cmdy_gpu_apple_wakeup_cancel(void *);
void cmdy_gpu_apple_wakeup_destroy(void *);
typedef void (*CmdyGpuAppleCompletion)(void *context,double gpu_start,double gpu_end);
typedef void (*CmdyGpuAppleCheckedCompletion)(void *context,double gpu_start,double gpu_end,uint8_t succeeded);
typedef void (*CmdyGpuApplePresented)(void *context,double presented_time);
void cmdy_gpu_apple_dispatch_background(CmdyGpuAppleTask,void *context);
void cmdy_gpu_apple_dispatch_main(CmdyGpuAppleTask,void *context);
void cmdy_gpu_apple_commit(const void *buffer,const void *drawable,CmdyGpuAppleCompletion,void *context);
void cmdy_gpu_apple_commit_checked(const void *buffer,const void *drawable,CmdyGpuAppleCheckedCompletion,void *context);
void cmdy_gpu_apple_presented(const void *drawable,CmdyGpuApplePresented,void *context,CmdyGpuAppleTask dispose);
void *cmdy_gpu_apple_decode_image(const void *device,const void *image);
void *cmdy_gpu_apple_png_image(const uint8_t *bytes,size_t length);
size_t cmdy_gpu_apple_image_width(const void *image);
size_t cmdy_gpu_apple_image_height(const void *image);
void *cmdy_gpu_apple_image_texture(const void *device,const void *image);
const void *cmdy_gpu_apple_font_name(const void *font); /* retained CFString */
double cmdy_gpu_apple_font_size(const void *font);
uint8_t cmdy_gpu_apple_equal(const void *,const void *);
uint64_t cmdy_gpu_apple_hash(const void *); /* CFHash; equal objects share a hash. */
#endif
