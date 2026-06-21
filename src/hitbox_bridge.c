#include "hitbox_bridge_core.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

typedef struct {
    bool forever;
    int seconds;
} Options;

static HitboxBridge *g_bridge = NULL;

static void handle_signal(int sig) {
    (void)sig;
    hitbox_bridge_request_stop(g_bridge);
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
    g_bridge = hitbox_bridge_create(event_cb, log_cb, NULL);
    if (!g_bridge) {
        fprintf(stderr, "failed to create bridge\n");
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    int result = hitbox_bridge_run(g_bridge, opts.forever, opts.seconds);
    hitbox_bridge_destroy(g_bridge);
    g_bridge = NULL;
    return result;
}
