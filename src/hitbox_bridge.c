#include "hitbox_bridge_core.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

typedef struct {
    bool forever;
    int seconds;
} Options;

_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "bridge pointer must be lock-free for signal handling");

static _Atomic(HitboxBridge *) g_bridge = NULL;

static void handle_signal(int sig) {
    (void)sig;
    hitbox_bridge_request_stop(atomic_load_explicit(&g_bridge, memory_order_acquire));
}

static void event_cb(void *context, const char *control, bool down) {
    (void)context;
    printf("%s %s\n", control, down ? "down" : "up");
}

static void log_cb(void *context, const char *message) {
    (void)context;
    fputs(message, stderr);
}

static Options parse_args(int argc, char **argv) {
    Options opts = {.forever = false, .seconds = 60};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--forever")) {
            opts.forever = true;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            opts.seconds = atoi(argv[++i]);
            if (opts.seconds < 1) opts.seconds = 1;
            if (opts.seconds > 3600) opts.seconds = 3600;
        } else {
            fprintf(stderr, "Usage: %s [--forever] [--seconds N]\n", argv[0]);
            exit(2);
        }
    }
    return opts;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    Options opts = parse_args(argc, argv);
    HitboxBridge *bridge = hitbox_bridge_create(event_cb, log_cb, NULL, NULL);
    if (!bridge) {
        fprintf(stderr, "failed to create bridge\n");
        return 1;
    }
    atomic_store_explicit(&g_bridge, bridge, memory_order_release);

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    int result = hitbox_bridge_run(bridge, opts.forever, opts.seconds);
    atomic_store_explicit(&g_bridge, NULL, memory_order_release);
    hitbox_bridge_destroy(bridge);
    return result;
}
