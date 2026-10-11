#import "platform_gpu.h"
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <string.h>
#import <pthread.h>
#import <pthread/qos.h>
#import <errno.h>

@interface CmdyGpuWeakObject : NSObject
@property(nonatomic,weak) id value;
@end
@implementation CmdyGpuWeakObject
@end
@interface CmdyGpuCallbackContext : NSObject
@property(nonatomic,assign) void *context;
@property(nonatomic,assign) CmdyGpuAppleTask dispose;
@end
@implementation CmdyGpuCallbackContext
- (void)dealloc { if(_dispose) _dispose(_context); }
@end

@interface CmdyGpuDeadlineWakeup : NSObject
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic,strong) dispatch_semaphore_t cancelled;
@end
@implementation CmdyGpuDeadlineWakeup
@end

static void *owned(id value) { return value ? (__bridge_retained void *)value : NULL; }
static id obj(const void *value) { return (__bridge id)value; }
void *cmdy_gpu_apple_layer_retain(const void *raw) {
    if (!raw || ![obj(raw) isKindOfClass:CAMetalLayer.class]) return NULL;
    CAMetalLayer *layer=obj(raw);
    if (!layer.allowsNextDrawableTimeout || layer.presentsWithTransaction) return NULL;
    return owned(layer);
}
void *cmdy_gpu_apple_layer_next_drawable(const void *raw) {
    return owned([(CAMetalLayer *)obj(raw) nextDrawable]);
}
void *cmdy_gpu_apple_drawable_pass(const void *raw) {
    if (!raw) return NULL;
    id<MTLTexture> texture=[(id<CAMetalDrawable>)obj(raw) texture];
    if (!texture) return NULL;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    return owned(pass);
}
uint64_t cmdy_gpu_apple_drawable_id(const void *raw) { return [(id<MTLDrawable>)obj(raw) drawableID]; }
void *cmdy_gpu_apple_capture_pass(const void *raw,const void *drawable,CmdyGpuAppleTargetInfo *info) {
    if (!raw || !info || ![obj(raw) isKindOfClass:MTLRenderPassDescriptor.class]) return NULL;
    MTLRenderPassDescriptor *pass=[obj(raw) copy];
    MTLRenderPassColorAttachmentDescriptor *attachment=pass.colorAttachments[0];
    id<MTLTexture> texture=attachment.texture;
    if (!texture || attachment.level>=texture.mipmapLevelCount || attachment.level>=sizeof(NSUInteger)*8) return NULL;
    if (drawable) {
        id candidate=obj(drawable);
        if (![candidate respondsToSelector:@selector(texture)]) return NULL;
        id<MTLTexture> output=attachment.resolveTexture ?: texture;
        if ([(id<CAMetalDrawable>)candidate texture]!=output) return NULL;
    }
    *info=(CmdyGpuAppleTargetInfo){ .device=(__bridge const void *)texture.device,
        .width=MAX((NSUInteger)1,texture.width>>attachment.level),
        .height=MAX((NSUInteger)1,texture.height>>attachment.level),
        .samples=texture.sampleCount, .format=texture.pixelFormat };
    return owned(pass);
}
static void errorText(NSError *error,char *out,size_t size) {
    if (out && size) strlcpy(out,error.localizedDescription.UTF8String ?: "Apple API unavailable",size);
}
void *cmdy_gpu_apple_retain(const void *value) { return owned(obj(value)); }
void cmdy_gpu_apple_release(const void *value) { if(value) CFRelease(value); }
void *cmdy_gpu_apple_weak_create(const void *value) {
    CmdyGpuWeakObject *box=[CmdyGpuWeakObject new]; box.value=obj(value); return owned(box);
}
void *cmdy_gpu_apple_weak_load(const void *value) { return owned(((CmdyGpuWeakObject *)obj(value)).value); }
void *cmdy_gpu_apple_queue(const void *device) { return owned([(id<MTLDevice>)obj(device) newCommandQueue]); }
void *cmdy_gpu_apple_library(const void *device,const char *source,char *error,size_t capacity) {
    NSError *failure=nil;
    id library=[(id<MTLDevice>)obj(device) newLibraryWithSource:[NSString stringWithUTF8String:source] options:nil error:&failure];
    if(!library) errorText(failure,error,capacity); return owned(library);
}
void *cmdy_gpu_apple_pipeline(const void *device,const void *library,const char *vertex,const char *fragment,const char *label,uint64_t format,size_t samples,uint8_t blend,char *error,size_t capacity) {
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.label=[NSString stringWithUTF8String:label];
    d.vertexFunction=[(id<MTLLibrary>)obj(library) newFunctionWithName:[NSString stringWithUTF8String:vertex]];
    d.fragmentFunction=[(id<MTLLibrary>)obj(library) newFunctionWithName:[NSString stringWithUTF8String:fragment]];
    d.colorAttachments[0].pixelFormat=(MTLPixelFormat)format; d.rasterSampleCount=samples;
    if(blend) {
        MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[0];
        a.blendingEnabled=YES; a.rgbBlendOperation=MTLBlendOperationAdd; a.alphaBlendOperation=MTLBlendOperationAdd;
        a.sourceRGBBlendFactor=blend==2 ? MTLBlendFactorOne : MTLBlendFactorSourceAlpha;
        a.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        a.sourceAlphaBlendFactor=MTLBlendFactorOne; a.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
    }
    NSError *failure=nil;
    id pipeline=[(id<MTLDevice>)obj(device) newRenderPipelineStateWithDescriptor:d error:&failure];
    if(!pipeline) errorText(failure,error,capacity); return owned(pipeline);
}
void *cmdy_gpu_apple_sampler(const void *device,uint8_t nearest) {
    MTLSamplerDescriptor *d=[MTLSamplerDescriptor new];
    d.minFilter=nearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    d.magFilter=d.minFilter; d.sAddressMode=MTLSamplerAddressModeClampToEdge; d.tAddressMode=d.sAddressMode;
    return owned([(id<MTLDevice>)obj(device) newSamplerStateWithDescriptor:d]);
}
void *cmdy_gpu_apple_texture(const void *device,size_t width,size_t height,size_t pages,uint64_t format,uint8_t render_target,uint8_t private_storage) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    if(pages) { d.textureType=MTLTextureType2DArray; d.arrayLength=pages; }
    d.storageMode=private_storage ? MTLStorageModePrivate : MTLStorageModeShared;
    d.usage=MTLTextureUsageShaderRead | (render_target ? MTLTextureUsageRenderTarget : 0);
    return owned([(id<MTLDevice>)obj(device) newTextureWithDescriptor:d]);
}
void cmdy_gpu_apple_texture_write(const void *texture,size_t x,size_t y,size_t width,size_t height,size_t slice,const void *bytes,size_t bytes_per_row) {
    [(id<MTLTexture>)obj(texture) replaceRegion:MTLRegionMake2D(x,y,width,height) mipmapLevel:0 slice:slice withBytes:bytes bytesPerRow:bytes_per_row bytesPerImage:bytes_per_row*height];
}
uint8_t cmdy_gpu_apple_texture_read_bgra(const void *texture,void *bytes,size_t length) {
    id<MTLTexture> value = (id<MTLTexture>)obj(texture);
    if (!value || !bytes || value.pixelFormat != MTLPixelFormatBGRA8Unorm ||
        value.storageMode != MTLStorageModeShared || value.sampleCount != 1 ||
        value.width == 0 || value.height == 0 || value.width > SIZE_MAX / 4 / value.height ||
        length != value.width * value.height * 4) return 0;
    [value getBytes:bytes bytesPerRow:value.width * 4
        fromRegion:MTLRegionMake2D(0,0,value.width,value.height) mipmapLevel:0];
    return 1;
}
size_t cmdy_gpu_apple_texture_bytes(const void *texture) { return [(id<MTLTexture>)obj(texture) allocatedSize]; }
size_t cmdy_gpu_apple_texture_width(const void *texture) { return [(id<MTLTexture>)obj(texture) width]; }
size_t cmdy_gpu_apple_texture_height(const void *texture) { return [(id<MTLTexture>)obj(texture) height]; }
void *cmdy_gpu_apple_buffer(const void *device,size_t length) { return owned([(id<MTLDevice>)obj(device) newBufferWithLength:length options:MTLResourceStorageModeShared]); }
void cmdy_gpu_apple_buffer_write(const void *buffer,size_t offset,const void *bytes,size_t length) { memcpy((char *)[(id<MTLBuffer>)obj(buffer) contents]+offset,bytes,length); }
void *cmdy_gpu_apple_command_buffer(const void *queue) { return owned([(id<MTLCommandQueue>)obj(queue) commandBuffer]); }
void *cmdy_gpu_apple_pass(const void *texture) {
    MTLRenderPassDescriptor *d=[MTLRenderPassDescriptor renderPassDescriptor]; d.colorAttachments[0].texture=obj(texture); return owned(d);
}
void cmdy_gpu_apple_pass_clear(const void *pass,double r,double g,double b,double a) {
    MTLRenderPassColorAttachmentDescriptor *d=((MTLRenderPassDescriptor *)obj(pass)).colorAttachments[0];
    d.clearColor=MTLClearColorMake(r,g,b,a); d.loadAction=MTLLoadActionClear; d.storeAction=MTLStoreActionStore;
}
void *cmdy_gpu_apple_encoder(const void *buffer,const void *pass) { return owned([(id<MTLCommandBuffer>)obj(buffer) renderCommandEncoderWithDescriptor:obj(pass)]); }
void cmdy_gpu_apple_encoder_scissor(const void *e,size_t x,size_t y,size_t w,size_t h) { [(id<MTLRenderCommandEncoder>)obj(e) setScissorRect:(MTLScissorRect){x,y,w,h}]; }
void cmdy_gpu_apple_encoder_pipeline(const void *e,const void *p) { [(id<MTLRenderCommandEncoder>)obj(e) setRenderPipelineState:obj(p)]; }
void cmdy_gpu_apple_encoder_vertex_buffer(const void *e,const void *b,size_t o,size_t i) { [(id<MTLRenderCommandEncoder>)obj(e) setVertexBuffer:obj(b) offset:o atIndex:i]; }
void cmdy_gpu_apple_encoder_bytes(const void *e,const void *b,size_t n,size_t i,uint8_t f) {
    if(f) [(id<MTLRenderCommandEncoder>)obj(e) setFragmentBytes:b length:n atIndex:i];
    else [(id<MTLRenderCommandEncoder>)obj(e) setVertexBytes:b length:n atIndex:i];
}
void cmdy_gpu_apple_encoder_texture(const void *e,const void *t,size_t i) { [(id<MTLRenderCommandEncoder>)obj(e) setFragmentTexture:obj(t) atIndex:i]; }
void cmdy_gpu_apple_encoder_sampler(const void *e,const void *s,size_t i) { [(id<MTLRenderCommandEncoder>)obj(e) setFragmentSamplerState:obj(s) atIndex:i]; }
void cmdy_gpu_apple_encoder_draw(const void *e,size_t count) { [(id<MTLRenderCommandEncoder>)obj(e) drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count]; }
void cmdy_gpu_apple_encoder_end(const void *e) { [(id<MTLRenderCommandEncoder>)obj(e) endEncoding]; }
void cmdy_gpu_apple_dispatch_background(CmdyGpuAppleTask fn,void *ctx) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool { fn(ctx); } }); }
void cmdy_gpu_apple_dispatch_main(CmdyGpuAppleTask fn,void *ctx) { dispatch_async(dispatch_get_main_queue(),^{ fn(ctx); }); }
void cmdy_gpu_apple_commit(const void *buffer,const void *drawable,CmdyGpuAppleCompletion fn,void *ctx) {
    id<MTLCommandBuffer> b=obj(buffer);
    if (drawable) [b presentDrawable:obj(drawable)];
    [b addCompletedHandler:^(id<MTLCommandBuffer> completed){ fn(ctx,completed.GPUStartTime,completed.GPUEndTime); }];
    [b commit];
}
void cmdy_gpu_apple_commit_checked(const void *buffer,const void *drawable,CmdyGpuAppleCheckedCompletion fn,void *ctx) {
    id<MTLCommandBuffer> b=obj(buffer);
    if (drawable) [b presentDrawable:obj(drawable)];
    [b addCompletedHandler:^(id<MTLCommandBuffer> completed){
        fn(ctx,completed.GPUStartTime,completed.GPUEndTime,completed.status==MTLCommandBufferStatusCompleted);
    }];
    [b commit];
}
void cmdy_gpu_apple_scope(CmdyGpuAppleTask body,void *context) { @autoreleasepool { body(context); } }
double cmdy_gpu_apple_uptime(void) { return NSProcessInfo.processInfo.systemUptime; }
int32_t cmdy_gpu_apple_set_thread_qos(uint8_t priority) {
    qos_class_t value;
    switch (priority) {
        case 0: value = QOS_CLASS_UTILITY; break;
        case 1: value = QOS_CLASS_USER_INITIATED; break;
        case 2: value = QOS_CLASS_USER_INTERACTIVE; break;
        default: return EINVAL;
    }
    if (pthread_main_np()) return EPERM;
    return pthread_set_qos_class_self_np(value, 0);
}
void *cmdy_gpu_apple_wakeup_create(CmdyGpuAppleTask wake,void *context) {
    if (!wake || !context) return NULL;
    CmdyGpuDeadlineWakeup *box=[CmdyGpuDeadlineWakeup new];
    if (!box) return NULL;
    dispatch_queue_attr_t attr=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0);
    dispatch_queue_t queue=dispatch_queue_create("com.cmdy.render.deadline",attr);
    if (!queue) return NULL;
    box.cancelled=dispatch_semaphore_create(0);
    if (!box.cancelled) return NULL;
    box.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,DISPATCH_TIMER_STRICT,queue);
    if (!box.timer) return NULL;
    dispatch_semaphore_t cancelled=box.cancelled;
    dispatch_source_set_event_handler(box.timer,^{ wake(context); });
    dispatch_source_set_cancel_handler(box.timer,^{ dispatch_semaphore_signal(cancelled); });
    dispatch_source_set_timer(box.timer,DISPATCH_TIME_FOREVER,DISPATCH_TIME_FOREVER,0);
    dispatch_resume(box.timer);
    return owned(box);
}
void cmdy_gpu_apple_wakeup_arm(void *raw,uint64_t delay_ns) {
    if (!raw) return;
    CmdyGpuDeadlineWakeup *box=obj(raw);
    int64_t delay=(int64_t)MIN(delay_ns,(uint64_t)INT64_MAX);
    dispatch_source_set_timer(box.timer,dispatch_time(DISPATCH_TIME_NOW,delay),DISPATCH_TIME_FOREVER,0);
}
void cmdy_gpu_apple_wakeup_cancel(void *raw) {
    if (!raw) return;
    dispatch_source_set_timer(((CmdyGpuDeadlineWakeup *)obj(raw)).timer,DISPATCH_TIME_FOREVER,DISPATCH_TIME_FOREVER,0);
}
void cmdy_gpu_apple_wakeup_destroy(void *raw) {
    if (!raw) return;
    __attribute__((objc_precise_lifetime)) CmdyGpuDeadlineWakeup *box=(__bridge_transfer CmdyGpuDeadlineWakeup *)raw;
    dispatch_source_cancel(box.timer);
    dispatch_semaphore_wait(box.cancelled,DISPATCH_TIME_FOREVER);
}
void cmdy_gpu_apple_presented(const void *drawable,CmdyGpuApplePresented fn,void *ctx,CmdyGpuAppleTask dispose) {
    CmdyGpuCallbackContext *box=[CmdyGpuCallbackContext new];box.context=ctx;box.dispose=dispose;
    [(id<MTLDrawable>)obj(drawable) addPresentedHandler:^(id<MTLDrawable> presented){fn(box.context,presented.presentedTime);}];
}
void *cmdy_gpu_apple_decode_image(const void *device,const void *image) {
    NSImage *ns=obj(image); CGRect rect={CGPointZero,ns.size};
    CGImageRef cg=[ns CGImageForProposedRect:&rect context:nil hints:nil];
    if(!cg) return NULL;
    return owned([[[MTKTextureLoader alloc] initWithDevice:obj(device)] newTextureWithCGImage:cg options:@{MTKTextureLoaderOptionSRGB:@NO,MTKTextureLoaderOptionOrigin:MTKTextureLoaderOriginTopLeft} error:nil]);
}
void *cmdy_gpu_apple_png_image(const uint8_t *bytes,size_t length) {
    CGImageSourceRef s=CGImageSourceCreateWithData((__bridge CFDataRef)[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO],NULL);
    if(!s) return NULL; CGImageRef image=CGImageSourceCreateImageAtIndex(s,0,NULL); CFRelease(s);
    return (void *)image;
}
size_t cmdy_gpu_apple_image_width(const void *image) { return CGImageGetWidth((CGImageRef)image); }
size_t cmdy_gpu_apple_image_height(const void *image) { return CGImageGetHeight((CGImageRef)image); }
void *cmdy_gpu_apple_image_texture(const void *device,const void *image) {
    return owned([[[MTKTextureLoader alloc] initWithDevice:obj(device)] newTextureWithCGImage:(CGImageRef)image options:@{MTKTextureLoaderOptionSRGB:@NO,MTKTextureLoaderOptionOrigin:MTKTextureLoaderOriginTopLeft} error:nil]);
}
const void *cmdy_gpu_apple_font_name(const void *font) { return CTFontCopyPostScriptName((CTFontRef)font); }
double cmdy_gpu_apple_font_size(const void *font) { return CTFontGetSize((CTFontRef)font); }
uint8_t cmdy_gpu_apple_equal(const void *a,const void *b) { return a==b || (a && b && CFEqual(a,b)); }
uint64_t cmdy_gpu_apple_hash(const void *value) { return value ? CFHash(value) : 0; }
