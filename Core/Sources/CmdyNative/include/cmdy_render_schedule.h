#ifndef CMDY_RENDER_SCHEDULE_H
#define CMDY_RENDER_SCHEDULE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "cmdy_render_text.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmdyRenderSchedule CmdyRenderSchedule;
typedef struct { float x, y; } CmdyRenderVec2;
typedef struct { uint64_t x, y, width, height; } CmdyRenderScissor;
typedef struct { int64_t display_index, source_row, cache_row; } CmdyRenderVisibleRow;
typedef struct { double snapped_points, rendered_points; float y_shift_pixels; } CmdyRenderScrollTranslation;
typedef struct { CmdyRenderVec2 position; bool is_animating; } CmdyRenderCursorStep;
typedef struct { uint64_t content, context; } CmdyRenderRevision;
typedef struct { uint64_t generation, committed_generation; bool service_is_queued, is_drawing; } CmdyRenderInteractiveRequests;
typedef struct { double last_build_time; bool has_last_build; } CmdyRenderFramePacer;
typedef struct { float velocity, energy; double last_event_time, last_update_time; } CmdyRenderScrollEnvelope;
typedef struct {
    int64_t shader_mode;
    float cursor_speed, cursor_max_distance;
    bool smooth_cursor, host_cursor_hidden, smooth_scroll, has_user_pipeline, user_shader_uses_time;
} CmdyRenderScheduleConfig;
typedef struct {
    double now, cell_height_pixels;
    int64_t maximum_fps;
    bool has_view, has_source, visible, key_window, caret_focused, low_power;
    uint8_t thermal;
} CmdyRenderScheduleEnvironment;
typedef struct {
    uint32_t flags;
    double animation_interval, coalesced_interval, keyboard_interval, recovery_interval;
    int64_t preferred_fps;
} CmdyRenderScheduleActions;
typedef struct { uint64_t generation; double delay; uint32_t outcome; bool started; } CmdyRenderDrawStart;
typedef struct {
    double start_time, activity_time, active_until, keyboard_feedback_deadline, keyboard_response_deadline;
    double direct_until, selection_until, scroll_held, scroll_glide, animation_interval;
    uint64_t interactive_generation;
    float envelope_velocity, envelope_energy;
    bool has_feedback_deadline, has_response_deadline, cursor_blink_eligible;
    bool frame_in_flight, redraw_pending, interactive_pending, service_queued, drawing;
} CmdyRenderScheduleInspection;

enum {
    CMDY_RENDER_INVALIDATE_VIEW = 1u << 0, CMDY_RENDER_QUEUE_SERVICE = 1u << 1,
    CMDY_RENDER_DRAW_MANUAL = 1u << 2, CMDY_RENDER_STOP_ANIMATION = 1u << 3,
    CMDY_RENDER_START_ANIMATION = 1u << 4, CMDY_RENDER_STOP_COALESCED = 1u << 5,
    CMDY_RENDER_START_COALESCED = 1u << 6, CMDY_RENDER_STOP_KEYBOARD = 1u << 7,
    CMDY_RENDER_START_KEYBOARD = 1u << 8, CMDY_RENDER_STOP_RECOVERY = 1u << 9,
    CMDY_RENDER_START_RECOVERY = 1u << 10, CMDY_RENDER_DISPLAY_LOCKED = 1u << 11
};
enum {
    CMDY_RENDER_REQUEST = 0, CMDY_RENDER_REQUEST_IMMEDIATE = 1,
    CMDY_RENDER_ACTIVITY = 2, CMDY_RENDER_KEYBOARD = 3, CMDY_RENDER_CANCEL_KEYBOARD = 4,
    CMDY_RENDER_SCROLL = 5, CMDY_RENDER_SET_HELD = 6, CMDY_RENDER_UPDATE_HELD = 7,
    CMDY_RENDER_SELECTION = 8, CMDY_RENDER_UPDATE_ANIMATION = 9,
    CMDY_RENDER_RESET_PACING = 10, CMDY_RENDER_SERVICE = 11,
    CMDY_RENDER_ANIMATION_FIRED = 12, CMDY_RENDER_COALESCED_FIRED = 13,
    CMDY_RENDER_KEYBOARD_FIRED = 14, CMDY_RENDER_RECOVERY_FIRED = 15,
    CMDY_RENDER_COMMITTED = 16, CMDY_RENDER_COMPLETED = 17,
    CMDY_RENDER_DRAWABLE_MISSING = 18, CMDY_RENDER_DRAWABLE_AVAILABLE = 19
};

size_t cmdy_render_visible_rows(int64_t rows, int64_t buffer_lines, int64_t display_top, int64_t retained_origin, int64_t extra, CmdyRenderVisibleRow *out, size_t capacity);
bool cmdy_render_display_row(int64_t source, int64_t top, int64_t rows, int64_t *out);
bool cmdy_render_cache_row(int64_t source, int64_t origin, int64_t *out);
CmdyRenderVec2 cmdy_render_viewport_translation(double x, double height, double top, double cell_height, int64_t row, double scale);
CmdyRenderScrollTranslation cmdy_render_scroll_translation(double offset, double scale);
double cmdy_render_effective_scroll(double source, double held, double glide);
double cmdy_render_decayed_glide(double value, double elapsed);
double cmdy_render_accumulated_glide(double current, double impulse, double cell_height);
bool cmdy_render_scroll_self_animates(double glide);
int64_t cmdy_render_fringe_rows(double offset, double cell_height, bool enabled);
int64_t cmdy_render_device_top_inset(double inset, double scale);
CmdyRenderScissor cmdy_render_scissor(double width, double height, double top, double bottom, double left, double scale);
float cmdy_render_cursor_opacity(bool blinks, bool focused, double now, double activity, double active_until);
bool cmdy_render_final_cursor_frame(bool timer_active, bool blink_eligible, bool focused, bool visible, double now, double active_until);
CmdyRenderCursorStep cmdy_render_cursor_step(CmdyRenderVec2 from, CmdyRenderVec2 to, bool should_draw, bool smooth, bool live_resize, float elapsed, float speed, float maximum_distance, CmdyRenderVec2 cell);
bool cmdy_render_selection_rect(int64_t lower, int64_t upper, int64_t columns, double width, double height, CmdyRenderRect *out);
size_t cmdy_render_background_fragments(CmdyRenderRect rect, const CmdyRenderRect *selection, CmdyRenderRect *out);
double cmdy_render_cursor_font_height(double cell_height, const void *font, double scale);
double cmdy_render_cursor_natural_y(double y, double cell_height, double natural_height);
double cmdy_render_cursor_underline(double thickness, double scale);
double cmdy_render_cursor_bar(double scale);
CmdyRenderRect cmdy_render_line_mode_rect(CmdyRenderRect rect, int64_t display_index, uint32_t mode, double x_origin, double y_origin, double cell_height);
bool cmdy_render_revision_valid(CmdyRenderRevision revision, uint64_t version);
bool cmdy_render_revision_equal(CmdyRenderRevision a, CmdyRenderRevision b);
bool cmdy_render_continuously_animates(int64_t mode);
bool cmdy_render_selection_animates(double now, double active_until);
double cmdy_render_static_fps(bool key, uint8_t thermal, bool low_power);
double cmdy_render_shader_fps(bool key, uint8_t thermal, bool low_power);
double cmdy_render_interactive_fps(bool key, uint8_t thermal, bool low_power, int64_t maximum);
bool cmdy_render_requires_offscreen(int64_t mode, bool builtin, bool user);
bool cmdy_render_cursor_blink_eligible(bool blinks, bool hidden, bool host_hidden, int64_t col, int64_t columns, int64_t row, int64_t top, int64_t rows);
bool cmdy_render_cursor_inverts_glyph(bool is_block, bool focused, bool animating);

void cmdy_render_interactive_request(CmdyRenderInteractiveRequests *state);
bool cmdy_render_interactive_pending(const CmdyRenderInteractiveRequests *state);
bool cmdy_render_interactive_queue(CmdyRenderInteractiveRequests *state, bool blocked);
bool cmdy_render_interactive_begin_service(CmdyRenderInteractiveRequests *state);
bool cmdy_render_interactive_begin_draw(CmdyRenderInteractiveRequests *state, uint64_t *out);
void cmdy_render_interactive_finish_draw(CmdyRenderInteractiveRequests *state, bool has_generation, uint64_t generation);
void cmdy_render_interactive_cancel(CmdyRenderInteractiveRequests *state);
double cmdy_render_pacer_delay(CmdyRenderFramePacer state, double now, double fps);
void cmdy_render_pacer_mark(CmdyRenderFramePacer *state, double now);
void cmdy_render_pacer_reset(CmdyRenderFramePacer *state);
void cmdy_render_envelope_scroll(CmdyRenderScrollEnvelope *state, double pixels, double now);
void cmdy_render_envelope_update(CmdyRenderScrollEnvelope *state, double now);

CmdyRenderSchedule *cmdy_render_schedule_create(double now);
CmdyRenderScheduleConfig cmdy_render_schedule_default_config(void);
/* Read-only projection of copied state; no mutable scheduler/GPU handle. */
double cmdy_render_schedule_project_target_fps(CmdyRenderScheduleConfig,
    CmdyRenderScheduleInspection, CmdyRenderScheduleEnvironment);
void cmdy_render_schedule_destroy(CmdyRenderSchedule *state);
CmdyRenderScheduleConfig cmdy_render_schedule_config(const CmdyRenderSchedule *state);
void cmdy_render_schedule_set_config(CmdyRenderSchedule *state, CmdyRenderScheduleConfig config);
CmdyRenderScheduleInspection cmdy_render_schedule_inspect(const CmdyRenderSchedule *state);
CmdyRenderScheduleActions cmdy_render_schedule_event(CmdyRenderSchedule *state, uint32_t event, CmdyRenderScheduleEnvironment environment, double value, double value2);
CmdyRenderDrawStart cmdy_render_schedule_begin_draw(CmdyRenderSchedule *state, CmdyRenderScheduleEnvironment environment, CmdyRenderScheduleActions *actions);
CmdyRenderScheduleActions cmdy_render_schedule_finish_draw(CmdyRenderSchedule *state, uint64_t generation, bool committed, CmdyRenderScheduleEnvironment environment);
double cmdy_render_schedule_target_fps(const CmdyRenderSchedule *state, CmdyRenderScheduleEnvironment environment, CmdyRenderScheduleActions *actions);
bool cmdy_render_schedule_should_animate(const CmdyRenderSchedule *state, CmdyRenderScheduleEnvironment environment);
bool cmdy_render_schedule_cancel_scroll(CmdyRenderSchedule *state);
void cmdy_render_schedule_update_motion(CmdyRenderSchedule *state, double now);
double cmdy_render_schedule_effective_scroll(const CmdyRenderSchedule *state, double source_offset);

#ifdef __cplusplus
}
#endif
#endif
