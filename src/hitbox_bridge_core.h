#ifndef HITBOX_BRIDGE_CORE_H
#define HITBOX_BRIDGE_CORE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HitboxBridge HitboxBridge;

typedef void (*HitboxBridgeEventCallback)(void *context, const char *control, bool down);
typedef void (*HitboxBridgeLogCallback)(void *context, const char *message);
typedef void (*HitboxBridgeConnectionCallback)(void *context, bool connected);

HitboxBridge *hitbox_bridge_create(HitboxBridgeEventCallback event_cb,
                                   HitboxBridgeLogCallback log_cb,
                                   HitboxBridgeConnectionCallback connection_cb,
                                   void *context);
bool hitbox_bridge_device_present(void);
int hitbox_bridge_run(HitboxBridge *bridge, bool forever, int seconds);
void hitbox_bridge_request_stop(HitboxBridge *bridge);
void hitbox_bridge_stop(HitboxBridge *bridge);
void hitbox_bridge_destroy(HitboxBridge *bridge);

#ifdef __cplusplus
}
#endif

#endif
