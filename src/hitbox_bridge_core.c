#include "hitbox_bridge_core.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <mach/mach_error.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VENDOR_ID 0x2DC8
#define PRODUCT_ID 0x202C

typedef struct {
    atomic_int references;
    atomic_bool done;
    IOReturn result;
    UInt32 size;
    uint8_t data[128];
} ReadContext;

typedef struct {
    const char *name;
    uint8_t byte_index;
    uint8_t mask;
    bool is_down;
} BitBinding;

typedef struct {
    const char *name;
    uint8_t lo_index;
    bool is_down;
} AxisBinding;

static const BitBinding bit_binding_defaults[] = {
    {"UP",    5, 0x01, false},
    {"DOWN",  5, 0x02, false},
    {"LEFT",  5, 0x04, false},
    {"RIGHT", 5, 0x08, false},

    {"A",   4, 0x10, false},
    {"B",   4, 0x20, false},
    {"X",   4, 0x40, false},
    {"Y",   4, 0x80, false},
    {"LB",  5, 0x10, false},
    {"RB",  5, 0x20, false},
    {"LSB", 5, 0x40, false},
    {"RSB", 5, 0x80, false},
};

static const AxisBinding axis_binding_defaults[] = {
    {"LT", 6, false},
    {"RT", 8, false},
};

enum {
    BIT_BINDING_COUNT = sizeof(bit_binding_defaults) / sizeof(bit_binding_defaults[0]),
    AXIS_BINDING_COUNT = sizeof(axis_binding_defaults) / sizeof(axis_binding_defaults[0]),
};

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "stop flag must be lock-free for signal handling");

struct HitboxBridge {
    HitboxBridgeEventCallback event_cb;
    HitboxBridgeLogCallback log_cb;
    HitboxBridgeConnectionCallback connection_cb;
    void *context;
    atomic_int stop_requested;
    pthread_mutex_t state_lock;
    CFRunLoopRef run_loop;
    bool connected;
    BitBinding bit_bindings[BIT_BINDING_COUNT];
    AxisBinding axis_bindings[AXIS_BINDING_COUNT];
};

static const char *ret_str(IOReturn err) {
    if (err == kIOReturnSuccess) return "ok";
    const char *s = mach_error_string(err);
    return s ? s : "unknown";
}

static void bridge_log(HitboxBridge *bridge, const char *fmt, ...) {
    if (!bridge->log_cb) return;

    char buffer[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    bridge->log_cb(bridge->context, buffer);
}

static uint16_t le16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8));
}

static CFNumberRef cfnum_u16(uint16_t value) {
    int v = value;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
}

static long prop_i64(io_service_t service, CFStringRef key, long fallback) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return fallback;
    long result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &result);
    }
    CFRelease(value);
    return result;
}

static void reset_bindings(HitboxBridge *bridge) {
    memcpy(bridge->bit_bindings, bit_binding_defaults, sizeof(bit_binding_defaults));
    memcpy(bridge->axis_bindings, axis_binding_defaults, sizeof(axis_binding_defaults));
}

static void emit_event(HitboxBridge *bridge, const char *control, bool down) {
    if (bridge->event_cb) {
        bridge->event_cb(bridge->context, control, down);
    }
}

static void set_connected(HitboxBridge *bridge, bool connected) {
    if (bridge->connected == connected) return;
    bridge->connected = connected;
    if (bridge->connection_cb) {
        bridge->connection_cb(bridge->context, connected);
    }
}

static bool stop_requested(const HitboxBridge *bridge) {
    return atomic_load_explicit(&bridge->stop_requested, memory_order_acquire) != 0;
}

static void install_run_loop(HitboxBridge *bridge, CFRunLoopRef run_loop) {
    if (run_loop) CFRetain(run_loop);

    pthread_mutex_lock(&bridge->state_lock);
    bridge->run_loop = run_loop;
    pthread_mutex_unlock(&bridge->state_lock);
}

static void clear_run_loop(HitboxBridge *bridge) {
    pthread_mutex_lock(&bridge->state_lock);
    CFRunLoopRef run_loop = bridge->run_loop;
    bridge->run_loop = NULL;
    pthread_mutex_unlock(&bridge->state_lock);

    if (run_loop) CFRelease(run_loop);
}

static void print_controls(HitboxBridge *bridge) {
    bridge_log(bridge, "Controls:");
    for (size_t i = 0; i < sizeof(bridge->bit_bindings) / sizeof(bridge->bit_bindings[0]); i++) {
        bridge_log(bridge, " %s", bridge->bit_bindings[i].name);
    }
    for (size_t i = 0; i < sizeof(bridge->axis_bindings) / sizeof(bridge->axis_bindings[0]); i++) {
        bridge_log(bridge, " %s", bridge->axis_bindings[i].name);
    }
    bridge_log(bridge, "\n");
}

static IOReturn create_device_interface(HitboxBridge *bridge,
                                        io_service_t service,
                                        IOUSBDeviceInterface ***dev_out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugin,
                                                    &score);
    if (kr != kIOReturnSuccess || !plugin) {
        bridge_log(bridge, "IOCreatePlugInInterfaceForService(device): 0x%08x %s\n", kr, ret_str(kr));
        return kr;
    }

    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942),
                                           (LPVOID *)dev_out);
    if (hr || !*dev_out) {
        hr = (*plugin)->QueryInterface(plugin,
                                       CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650),
                                       (LPVOID *)dev_out);
    }
    if (hr || !*dev_out) {
        hr = (*plugin)->QueryInterface(plugin,
                                       CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                       (LPVOID *)dev_out);
    }
    (*plugin)->Release(plugin);

    if (hr || !*dev_out) {
        bridge_log(bridge, "QueryInterface(device): 0x%08x\n", (unsigned int)hr);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

static IOReturn create_interface_interface(HitboxBridge *bridge,
                                           io_service_t service,
                                           IOUSBInterfaceInterface ***intf_out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBInterfaceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugin,
                                                    &score);
    if (kr != kIOReturnSuccess || !plugin) {
        bridge_log(bridge, "IOCreatePlugInInterfaceForService(interface): 0x%08x %s\n", kr, ret_str(kr));
        return kr;
    }

    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID650),
                                           (LPVOID *)intf_out);
    if (hr || !*intf_out) {
        hr = (*plugin)->QueryInterface(plugin,
                                       CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500),
                                       (LPVOID *)intf_out);
    }
    if (hr || !*intf_out) {
        hr = (*plugin)->QueryInterface(plugin,
                                       CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                       (LPVOID *)intf_out);
    }
    (*plugin)->Release(plugin);

    if (hr || !*intf_out) {
        bridge_log(bridge, "QueryInterface(interface): 0x%08x\n", (unsigned int)hr);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

static io_service_t find_device(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return IO_OBJECT_NULL;

    CFNumberRef vendor = cfnum_u16(VENDOR_ID);
    CFNumberRef product = cfnum_u16(PRODUCT_ID);
    CFDictionarySetValue(match, CFSTR("idVendor"), vendor);
    CFDictionarySetValue(match, CFSTR("idProduct"), product);
    CFRelease(vendor);
    CFRelease(product);

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (kr != kIOReturnSuccess) return IO_OBJECT_NULL;

    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    return service;
}

bool hitbox_bridge_device_present(void) {
    io_service_t service = find_device();
    if (service == IO_OBJECT_NULL) return false;
    IOObjectRelease(service);
    return true;
}

static IOReturn configure_device(IOUSBDeviceInterface **dev) {
    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) return kr;

    IOUSBConfigurationDescriptorPtr cfg = NULL;
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg);
    if (kr != kIOReturnSuccess || !cfg) {
        IOReturn result = kr ? kr : kIOReturnError;
        (*dev)->USBDeviceClose(dev);
        return result;
    }

    kr = (*dev)->SetConfiguration(dev, cfg->bConfigurationValue);
    if (kr != kIOReturnSuccess) {
        (*dev)->USBDeviceClose(dev);
        return kr;
    }

    sleep(1);
    return kr;
}

static IOUSBInterfaceInterface **open_control_interface(HitboxBridge *bridge,
                                                        IOUSBDeviceInterface **dev,
                                                        UInt8 *in_pipe_out,
                                                        UInt8 *out_pipe_out) {
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn kr = (*dev)->CreateInterfaceIterator(dev, &req, &iterator);
    if (kr != kIOReturnSuccess) {
        bridge_log(bridge, "CreateInterfaceIterator: 0x%08x %s\n", kr, ret_str(kr));
        return NULL;
    }

    IOUSBInterfaceInterface **chosen = NULL;
    io_service_t intf_service;
    while ((intf_service = IOIteratorNext(iterator))) {
        long if_num = prop_i64(intf_service, CFSTR("bInterfaceNumber"), -1);
        long alt = prop_i64(intf_service, CFSTR("bAlternateSetting"), -1);
        long eps = prop_i64(intf_service, CFSTR("bNumEndpoints"), -1);
        if (if_num != 0 || alt != 0 || eps < 2) {
            IOObjectRelease(intf_service);
            continue;
        }

        IOUSBInterfaceInterface **intf = NULL;
        kr = create_interface_interface(bridge, intf_service, &intf);
        IOObjectRelease(intf_service);
        if (kr != kIOReturnSuccess || !intf) continue;

        kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) {
            bridge_log(bridge, "USBInterfaceOpen: 0x%08x %s\n", kr, ret_str(kr));
            (*intf)->Release(intf);
            continue;
        }

        UInt8 pipe_count = 0;
        kr = (*intf)->GetNumEndpoints(intf, &pipe_count);
        if (kr != kIOReturnSuccess) {
            (*intf)->USBInterfaceClose(intf);
            (*intf)->Release(intf);
            continue;
        }

        UInt8 in_pipe = 0;
        UInt8 out_pipe = 0;
        for (UInt8 pipe = 1; pipe <= pipe_count; pipe++) {
            UInt8 direction = 0, number = 0, type = 0, interval = 0;
            UInt16 max_packet = 0;
            kr = (*intf)->GetPipeProperties(intf, pipe, &direction, &number, &type, &max_packet, &interval);
            if (kr != kIOReturnSuccess || type != 3) continue;
            if (direction == kUSBIn) in_pipe = pipe;
            if (direction == kUSBOut) out_pipe = pipe;
        }

        if (in_pipe && out_pipe) {
            *in_pipe_out = in_pipe;
            *out_pipe_out = out_pipe;
            chosen = intf;
            break;
        }

        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
    }

    IOObjectRelease(iterator);
    return chosen;
}

static void write_packet(HitboxBridge *bridge,
                         IOUSBInterfaceInterface **intf,
                         UInt8 pipe,
                         uint8_t *packet,
                         UInt32 size) {
    IOReturn kr = (*intf)->WritePipe(intf, pipe, packet, size);
    if (kr != kIOReturnSuccess) {
        bridge_log(bridge, "WritePipe: 0x%08x %s\n", kr, ret_str(kr));
    }
}

static void init_gip(HitboxBridge *bridge, IOUSBInterfaceInterface **intf, UInt8 out_pipe) {
    UInt8 seq = 0;
    uint8_t power_on[] = {0x05, 0x20, 0x00, 0x01, 0x00};
    uint8_t auth_done[] = {0x06, 0x20, 0x00, 0x02, 0x01, 0x00};
    uint8_t led_on[] = {0x0a, 0x20, 0x00, 0x03, 0x00, 0x01, 0x14};
    power_on[2] = seq++;
    auth_done[2] = seq++;
    led_on[2] = seq++;
    write_packet(bridge, intf, out_pipe, power_on, sizeof(power_on));
    usleep(20000);
    write_packet(bridge, intf, out_pipe, auth_done, sizeof(auth_done));
    usleep(20000);
    write_packet(bridge, intf, out_pipe, led_on, sizeof(led_on));
    usleep(20000);
}

static void read_context_retain(ReadContext *ctx) {
    atomic_fetch_add_explicit(&ctx->references, 1, memory_order_relaxed);
}

static void read_context_release(ReadContext *ctx) {
    if (atomic_fetch_sub_explicit(&ctx->references, 1, memory_order_acq_rel) == 1) {
        free(ctx);
    }
}

static void read_cb(void *refcon, IOReturn result, void *arg0) {
    ReadContext *ctx = (ReadContext *)refcon;
    ctx->result = result;
    ctx->size = (UInt32)(uintptr_t)arg0;
    atomic_store_explicit(&ctx->done, true, memory_order_release);
    read_context_release(ctx);
}

static bool update_binding(HitboxBridge *bridge, const char *name, bool old_down, bool new_down) {
    if (old_down == new_down) return old_down;
    emit_event(bridge, name, new_down);
    return new_down;
}

static void handle_input_packet(HitboxBridge *bridge, const uint8_t *data, UInt32 size) {
    if (data[0] != 0x20 || size < 10) return;

    for (size_t i = 0; i < sizeof(bridge->bit_bindings) / sizeof(bridge->bit_bindings[0]); i++) {
        BitBinding *b = &bridge->bit_bindings[i];
        bool down = (data[b->byte_index] & b->mask) != 0;
        b->is_down = update_binding(bridge, b->name, b->is_down, down);
    }

    for (size_t i = 0; i < sizeof(bridge->axis_bindings) / sizeof(bridge->axis_bindings[0]); i++) {
        AxisBinding *a = &bridge->axis_bindings[i];
        bool down = le16(data + a->lo_index) > 512;
        a->is_down = update_binding(bridge, a->name, a->is_down, down);
    }
}

HitboxBridge *hitbox_bridge_create(HitboxBridgeEventCallback event_cb,
                                   HitboxBridgeLogCallback log_cb,
                                   HitboxBridgeConnectionCallback connection_cb,
                                   void *context) {
    HitboxBridge *bridge = calloc(1, sizeof(*bridge));
    if (!bridge) return NULL;

    bridge->event_cb = event_cb;
    bridge->log_cb = log_cb;
    bridge->connection_cb = connection_cb;
    bridge->context = context;
    atomic_init(&bridge->stop_requested, 0);
    if (pthread_mutex_init(&bridge->state_lock, NULL) != 0) {
        free(bridge);
        return NULL;
    }
    reset_bindings(bridge);
    return bridge;
}

int hitbox_bridge_run(HitboxBridge *bridge, bool forever, int seconds) {
    if (!bridge) return 1;
    if (stop_requested(bridge)) return 0;
    reset_bindings(bridge);

    io_service_t service = find_device();
    if (service == IO_OBJECT_NULL) {
        bridge_log(bridge, "8BitDo device not found\n");
        return 1;
    }

    IOUSBDeviceInterface **dev = NULL;
    IOReturn kr = create_device_interface(bridge, service, &dev);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !dev) return 1;

    kr = configure_device(dev);
    if (kr != kIOReturnSuccess) {
        bridge_log(bridge, "configure_device: 0x%08x %s\n", kr, ret_str(kr));
        (*dev)->Release(dev);
        return 1;
    }

    UInt8 in_pipe = 0;
    UInt8 out_pipe = 0;
    IOUSBInterfaceInterface **intf = open_control_interface(bridge, dev, &in_pipe, &out_pipe);
    if (!intf) {
        bridge_log(bridge, "control interface not found\n");
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return 1;
    }

    CFRunLoopSourceRef async_source = NULL;
    kr = (*intf)->CreateInterfaceAsyncEventSource(intf, &async_source);
    if (kr != kIOReturnSuccess || !async_source) {
        bridge_log(bridge, "CreateInterfaceAsyncEventSource: 0x%08x %s\n", kr, ret_str(kr));
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return 1;
    }

    install_run_loop(bridge, CFRunLoopGetCurrent());
    CFRunLoopAddSource(CFRunLoopGetCurrent(), async_source, kCFRunLoopDefaultMode);

    print_controls(bridge);
    if (forever) {
        bridge_log(bridge, "Decoding until stopped.\n");
    } else {
        bridge_log(bridge, "Decoding for %d seconds.\n", seconds);
    }
    init_gip(bridge, intf, out_pipe);
    set_connected(bridge, true);

    int exit_code = 0;
    CFAbsoluteTime deadline = forever ? 0 : CFAbsoluteTimeGetCurrent() + seconds;
    bool pending = false;
    ReadContext *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        bridge_log(bridge, "Cannot allocate USB read context\n");
        exit_code = 1;
        goto cleanup;
    }
    atomic_init(&ctx->references, 1);
    atomic_init(&ctx->done, false);

    while (!stop_requested(bridge) && (forever || CFAbsoluteTimeGetCurrent() < deadline)) {
        if (!pending) {
            ctx->result = kIOReturnSuccess;
            ctx->size = 0;
            memset(ctx->data, 0, sizeof(ctx->data));
            atomic_store_explicit(&ctx->done, false, memory_order_release);
            read_context_retain(ctx);
            kr = (*intf)->ReadPipeAsync(intf, in_pipe, ctx->data, sizeof(ctx->data), read_cb, ctx);
            if (kr != kIOReturnSuccess) {
                read_context_release(ctx);
                bridge_log(bridge, "ReadPipeAsync: 0x%08x %s\n", kr, ret_str(kr));
                exit_code = 1;
                break;
            }
            pending = true;
        }

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        if (pending && atomic_load_explicit(&ctx->done, memory_order_acquire)) {
            if (ctx->result == kIOReturnSuccess && ctx->size > 0) {
                handle_input_packet(bridge, ctx->data, ctx->size);
            } else if (ctx->result != kIOReturnSuccess && ctx->result != kIOReturnAborted) {
                bridge_log(bridge, "ReadPipeAsync completion: 0x%08x %s\n", ctx->result, ret_str(ctx->result));
                exit_code = 1;
                pending = false;
                break;
            }
            pending = false;
        }
    }

    if (pending) {
        (*intf)->AbortPipe(intf, in_pipe);
        CFAbsoluteTime abort_deadline = CFAbsoluteTimeGetCurrent() + 1.0;
        while (!atomic_load_explicit(&ctx->done, memory_order_acquire) &&
               CFAbsoluteTimeGetCurrent() < abort_deadline) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        }
        if (!atomic_load_explicit(&ctx->done, memory_order_acquire)) {
            bridge_log(bridge, "USB read cancellation did not complete; retaining callback context\n");
        }
    }
    read_context_release(ctx);

cleanup:
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), async_source, kCFRunLoopDefaultMode);
    CFRelease(async_source);
    clear_run_loop(bridge);
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    set_connected(bridge, false);
    return exit_code;
}

void hitbox_bridge_request_stop(HitboxBridge *bridge) {
    if (bridge) {
        atomic_store_explicit(&bridge->stop_requested, 1, memory_order_release);
    }
}

void hitbox_bridge_stop(HitboxBridge *bridge) {
    if (!bridge) return;
    hitbox_bridge_request_stop(bridge);

    pthread_mutex_lock(&bridge->state_lock);
    CFRunLoopRef run_loop = bridge->run_loop;
    if (run_loop) CFRetain(run_loop);
    pthread_mutex_unlock(&bridge->state_lock);

    if (run_loop) {
        CFRunLoopStop(run_loop);
        CFRelease(run_loop);
    }
}

void hitbox_bridge_destroy(HitboxBridge *bridge) {
    if (!bridge) return;
    pthread_mutex_destroy(&bridge->state_lock);
    free(bridge);
}
