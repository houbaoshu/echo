#ifndef ECHO_RUNTIME_H
#define ECHO_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct EchoRuntime EchoRuntime;
typedef struct { uint32_t width, height, frame_count; } EchoInfo;
typedef struct { const uint8_t *data; size_t length; } EchoFrame;
typedef struct { uint32_t sprite_index; double next_frame_seconds; } EchoTick;

// All calls for one handle must be serialized. NULL handles fail safely.
// create copies a UTF-8 error into the caller's buffer and returns NULL on error.
EchoRuntime *echo_create(const char *directory, char *error, size_t capacity);
void echo_destroy(EchoRuntime *handle);
bool echo_info(const EchoRuntime *handle, EchoInfo *out);
// Borrowed RGBA8, straight alpha, top-to-bottom rows. Valid until destroy.
// The caller must copy data before retaining it beyond the handle's lifetime.
bool echo_frame(const EchoRuntime *handle, uint32_t index, EchoFrame *out);
// The pet's state: idle, or a Live Voice state on a planet.
bool echo_set_animation(EchoRuntime *handle, const char *name);
// A clip played once over that state, such as the wave on a click; a drag ends it.
bool echo_play_once(EchoRuntime *handle, const char *name);
bool echo_set_interaction(EchoRuntime *handle, bool hovered, int32_t direction);
bool echo_look_at(EchoRuntime *handle, double dx, double dy);
// next_frame_seconds > 0: schedule a wake-up; 0: static, no timer needed.
bool echo_tick(EchoRuntime *handle, EchoTick *out);

#endif
