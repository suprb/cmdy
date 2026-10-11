#ifndef CMDY_PLATFORM_SHAPE_H
#define CMDY_PLATFORM_SHAPE_H
#include "platform_text.h"
#include "cmdy_render_shape.h"
#include <ImageIO/ImageIO.h>
#include "cmdy_render_image_bridge.h"
const void *cmdy_platform_shape_color_srgb(const void *color);
const void *cmdy_platform_shape_color_create(double r,double g,double b,double a);
const void *cmdy_platform_shape_font_traits(const void *font,unsigned long traits);
double cmdy_platform_shape_font_metric(const void *font,unsigned metric);
const void *cmdy_platform_shape_image(CGImageRef image,double width,double height);
#endif
