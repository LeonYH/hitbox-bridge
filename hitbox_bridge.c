#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <mach/mach_error.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <signal.h>
#include <unistd.h>

#define VENDOR_ID 0x2DC8
#define PRODUCT_ID 0x202C

typedef struct {
    bool emit;
    bool forever;
    int seconds;
    const char *config_path;
} Options;

typedef struct {
    bool done;
    IOReturn result;
    UInt32 size;
    uint8_t data[128];
} ReadContext;

typedef struct {
    const char *name;
    uint8_t byte_index;
    uint8_t mask;
    CGKeyCode key;
    const char *default_label;
    char key_label[16];
    bool is_down;
} BitBinding;

typedef struct {
    const char *name;
    uint8_t lo_index;
    CGKeyCode key;
    const char *default_label;
    char key_label[16];
    bool is_down;
} AxisBinding;

typedef struct {
    const char *label;
    CGKeyCode key;
} KeyInfo;

static volatile sig_atomic_t g_stop = 0;
static CGEventSourceRef g_event_source = NULL;

static const KeyInfo key_table[] = {
    {"A", 0}, {"S", 1}, {"D", 2}, {"F", 3}, {"H", 4}, {"G", 5},
    {"Z", 6}, {"X", 7}, {"C", 8}, {"V", 9}, {"B", 11},
    {"Q", 12}, {"W", 13}, {"E", 14}, {"R", 15}, {"Y", 16}, {"T", 17},
    {"1", 18}, {"2", 19}, {"3", 20}, {"4", 21}, {"6", 22}, {"5", 23},
    {"=", 24}, {"9", 25}, {"7", 26}, {"-", 27}, {"8", 28}, {"0", 29},
    {"]", 30}, {"O", 31}, {"U", 32}, {"[", 33}, {"I", 34}, {"P", 35},
    {"ENTER", 36}, {"RETURN", 36}, {"L", 37}, {"J", 38}, {"'", 39},
    {"K", 40}, {";", 41}, {"SEMICOLON", 41}, {"\\", 42}, {",", 43},
    {"/", 44}, {"N", 45}, {"M", 46}, {".", 47}, {"TAB", 48},
    {"SPACE", 49}, {"`", 50}, {"ESC", 53}, {"ESCAPE", 53},
};

static BitBinding bit_bindings[] = {
    {"UP",    5, 0x01, 13, "W", "", false},
    {"DOWN",  5, 0x02, 1,  "S", "", false},
    {"LEFT",  5, 0x04, 0,  "A", "", false},
    {"RIGHT", 5, 0x08, 2,  "D", "", false},

    {"A",   4, 0x10, 38, "J", "", false},
    {"B",   4, 0x20, 40, "K", "", false},
    {"X",   4, 0x40, 32, "U", "", false},
    {"Y",   4, 0x80, 34, "I", "", false},
    {"LB",  5, 0x10, 35, "P", "", false},
    {"RB",  5, 0x20, 31, "O", "", false},
    {"LSB", 5, 0x40, 16, "Y", "", false},
    {"RSB", 5, 0x80, 4,  "H", "", false},
};

static AxisBinding axis_bindings[] = {
    {"LT", 6, 41, ";", "", false},
    {"RT", 8, 37, "L", "", false},
};

static const char *ret_str(IOReturn err) {
    if (err == kIOReturnSuccess) return "ok";
    const char *s = mach_error_string(err);
    return s ? s : "unknown";
}

static uint16_t le16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
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

static void post_key(CGKeyCode key, bool down) {
    if (!g_event_source) {
        g_event_source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (!g_event_source) return;
    }

    CGEventRef event = CGEventCreateKeyboardEvent(g_event_source, key, down);
    if (!event) return;

    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, 0);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void cleanup_event_source(void) {
    if (g_event_source) {
        CFRelease(g_event_source);
        g_event_source = NULL;
    }
}

static void release_all_keys(bool emit) {
    for (size_t i = 0; i < sizeof(bit_bindings) / sizeof(bit_bindings[0]); i++) {
        if (bit_bindings[i].is_down) {
            if (emit) post_key(bit_bindings[i].key, false);
            bit_bindings[i].is_down = false;
        }
    }
    for (size_t i = 0; i < sizeof(axis_bindings) / sizeof(axis_bindings[0]); i++) {
        if (axis_bindings[i].is_down) {
            if (emit) post_key(axis_bindings[i].key, false);
            axis_bindings[i].is_down = false;
        }
    }
}

static bool ensure_accessibility_permission(void) {
    if (AXIsProcessTrusted()) {
        return true;
    }

    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *values[] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault,
                                                 keys,
                                                 values,
                                                 1,
                                                 &kCFCopyStringDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    bool trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);

    if (!trusted) {
        fprintf(stderr, "Accessibility permission is required for --emit.\n");
        fprintf(stderr, "Open System Settings > Privacy & Security > Accessibility, enable the app that launched this tool, then rerun.\n");
        return false;
    }
    return true;
}

static void handle_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void copy_key_label(char *dest, size_t dest_size, const char *label) {
    snprintf(dest, dest_size, "%s", label);
}

static void init_key_labels(void) {
    for (size_t i = 0; i < sizeof(bit_bindings) / sizeof(bit_bindings[0]); i++) {
        copy_key_label(bit_bindings[i].key_label,
                       sizeof(bit_bindings[i].key_label),
                       bit_bindings[i].default_label);
    }
    for (size_t i = 0; i < sizeof(axis_bindings) / sizeof(axis_bindings[0]); i++) {
        copy_key_label(axis_bindings[i].key_label,
                       sizeof(axis_bindings[i].key_label),
                       axis_bindings[i].default_label);
    }
}

static const KeyInfo *find_key_info(const char *label) {
    for (size_t i = 0; i < sizeof(key_table) / sizeof(key_table[0]); i++) {
        if (!strcasecmp(label, key_table[i].label)) {
            return &key_table[i];
        }
    }
    return NULL;
}

static BitBinding *find_bit_binding(const char *name) {
    for (size_t i = 0; i < sizeof(bit_bindings) / sizeof(bit_bindings[0]); i++) {
        if (!strcasecmp(name, bit_bindings[i].name)) {
            return &bit_bindings[i];
        }
    }
    return NULL;
}

static AxisBinding *find_axis_binding(const char *name) {
    for (size_t i = 0; i < sizeof(axis_bindings) / sizeof(axis_bindings[0]); i++) {
        if (!strcasecmp(name, axis_bindings[i].name)) {
            return &axis_bindings[i];
        }
    }
    return NULL;
}

static char *trim(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    if (!*s) return s;

    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) {
        *end = '\0';
        end--;
    }
    return s;
}

static bool apply_mapping(const char *control, const char *label) {
    const KeyInfo *key = find_key_info(label);
    if (!key) {
        fprintf(stderr, "Unknown key label for %s: %s\n", control, label);
        return false;
    }

    BitBinding *bit = find_bit_binding(control);
    if (bit) {
        bit->key = key->key;
        copy_key_label(bit->key_label, sizeof(bit->key_label), key->label);
        return true;
    }

    AxisBinding *axis = find_axis_binding(control);
    if (axis) {
        axis->key = key->key;
        copy_key_label(axis->key_label, sizeof(axis->key_label), key->label);
        return true;
    }

    fprintf(stderr, "Unknown control in keymap: %s\n", control);
    return false;
}

static bool load_keymap(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) {
        perror(path);
        return false;
    }

    char line[256];
    unsigned int line_no = 0;
    while (fgets(line, sizeof(line), file)) {
        line_no++;

        char *comment = strchr(line, '#');
        if (comment) *comment = '\0';

        char *eq = strchr(line, '=');
        if (!eq) {
            if (*trim(line)) {
                fprintf(stderr, "%s:%u: expected CONTROL=KEY\n", path, line_no);
            }
            continue;
        }

        *eq = '\0';
        char *control = trim(line);
        char *label = trim(eq + 1);
        if (!*control || !*label) {
            fprintf(stderr, "%s:%u: expected CONTROL=KEY\n", path, line_no);
            continue;
        }

        apply_mapping(control, label);
    }

    fclose(file);
    return true;
}

static void print_keymap(void) {
    printf("Key map:");
    for (size_t i = 0; i < sizeof(bit_bindings) / sizeof(bit_bindings[0]); i++) {
        printf(" %s=%s", bit_bindings[i].name, bit_bindings[i].key_label);
    }
    for (size_t i = 0; i < sizeof(axis_bindings) / sizeof(axis_bindings[0]); i++) {
        printf(" %s=%s", axis_bindings[i].name, axis_bindings[i].key_label);
    }
    printf("\n");
}

static IOReturn create_device_interface(io_service_t service, IOUSBDeviceInterface ***dev_out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugin,
                                                    &score);
    if (kr != kIOReturnSuccess || !plugin) {
        fprintf(stderr, "IOCreatePlugInInterfaceForService(device): 0x%08x %s\n", kr, ret_str(kr));
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
        fprintf(stderr, "QueryInterface(device): 0x%08x\n", (unsigned int)hr);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

static IOReturn create_interface_interface(io_service_t service, IOUSBInterfaceInterface ***intf_out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBInterfaceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugin,
                                                    &score);
    if (kr != kIOReturnSuccess || !plugin) {
        fprintf(stderr, "IOCreatePlugInInterfaceForService(interface): 0x%08x %s\n", kr, ret_str(kr));
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
        fprintf(stderr, "QueryInterface(interface): 0x%08x\n", (unsigned int)hr);
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

static IOReturn configure_device(IOUSBDeviceInterface **dev) {
    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) return kr;

    IOUSBConfigurationDescriptorPtr cfg = NULL;
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg);
    if (kr != kIOReturnSuccess || !cfg) return kr ? kr : kIOReturnError;

    kr = (*dev)->SetConfiguration(dev, cfg->bConfigurationValue);
    sleep(1);
    return kr;
}

static IOUSBInterfaceInterface **open_control_interface(IOUSBDeviceInterface **dev,
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
        fprintf(stderr, "CreateInterfaceIterator: 0x%08x %s\n", kr, ret_str(kr));
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
        kr = create_interface_interface(intf_service, &intf);
        IOObjectRelease(intf_service);
        if (kr != kIOReturnSuccess || !intf) continue;

        kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "USBInterfaceOpen: 0x%08x %s\n", kr, ret_str(kr));
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

static void write_packet(IOUSBInterfaceInterface **intf, UInt8 pipe, uint8_t *packet, UInt32 size) {
    IOReturn kr = (*intf)->WritePipe(intf, pipe, packet, size);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "WritePipe: 0x%08x %s\n", kr, ret_str(kr));
    }
}

static void init_gip(IOUSBInterfaceInterface **intf, UInt8 out_pipe) {
    static UInt8 seq = 0;
    uint8_t power_on[] = {0x05, 0x20, 0x00, 0x01, 0x00};
    uint8_t auth_done[] = {0x06, 0x20, 0x00, 0x02, 0x01, 0x00};
    uint8_t led_on[] = {0x0a, 0x20, 0x00, 0x03, 0x00, 0x01, 0x14};
    power_on[2] = seq++;
    auth_done[2] = seq++;
    led_on[2] = seq++;
    write_packet(intf, out_pipe, power_on, sizeof(power_on));
    usleep(20000);
    write_packet(intf, out_pipe, auth_done, sizeof(auth_done));
    usleep(20000);
    write_packet(intf, out_pipe, led_on, sizeof(led_on));
    usleep(20000);
}

static void read_cb(void *refcon, IOReturn result, void *arg0) {
    ReadContext *ctx = (ReadContext *)refcon;
    ctx->result = result;
    ctx->size = (UInt32)(uintptr_t)arg0;
    ctx->done = true;
}

static bool update_binding(const char *name, bool old_down, bool new_down, CGKeyCode key, bool emit) {
    if (old_down == new_down) return old_down;
    printf("%s %s\n", name, new_down ? "down" : "up");
    if (emit) post_key(key, new_down);
    return new_down;
}

static void handle_input_packet(const uint8_t *data, UInt32 size, bool emit) {
    if (size < 10 || data[0] != 0x20) return;

    for (size_t i = 0; i < sizeof(bit_bindings) / sizeof(bit_bindings[0]); i++) {
        BitBinding *b = &bit_bindings[i];
        bool down = (data[b->byte_index] & b->mask) != 0;
        b->is_down = update_binding(b->name, b->is_down, down, b->key, emit);
    }

    for (size_t i = 0; i < sizeof(axis_bindings) / sizeof(axis_bindings[0]); i++) {
        AxisBinding *a = &axis_bindings[i];
        bool down = le16(data + a->lo_index) > 512;
        a->is_down = update_binding(a->name, a->is_down, down, a->key, emit);
    }
}

static int run_bridge(const Options *opts) {
    if (opts->emit && !ensure_accessibility_permission()) {
        return 2;
    }

    io_service_t service = find_device();
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "8BitDo device not found\n");
        return 1;
    }

    IOUSBDeviceInterface **dev = NULL;
    IOReturn kr = create_device_interface(service, &dev);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !dev) return 1;

    kr = configure_device(dev);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "configure_device: 0x%08x %s\n", kr, ret_str(kr));
        (*dev)->Release(dev);
        return 1;
    }

    UInt8 in_pipe = 0;
    UInt8 out_pipe = 0;
    IOUSBInterfaceInterface **intf = open_control_interface(dev, &in_pipe, &out_pipe);
    if (!intf) {
        fprintf(stderr, "control interface not found\n");
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return 1;
    }

    CFRunLoopSourceRef async_source = NULL;
    kr = (*intf)->CreateInterfaceAsyncEventSource(intf, &async_source);
    if (kr != kIOReturnSuccess || !async_source) {
        fprintf(stderr, "CreateInterfaceAsyncEventSource: 0x%08x %s\n", kr, ret_str(kr));
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return 1;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), async_source, kCFRunLoopDefaultMode);

    print_keymap();
    if (opts->forever) {
        printf("%s until stopped. Press Ctrl-C to stop.\n", opts->emit ? "Emitting keyboard events" : "Dry-run decoding");
    } else {
        printf("%s for %d seconds. Press Ctrl-C to stop.\n", opts->emit ? "Emitting keyboard events" : "Dry-run decoding", opts->seconds);
    }
    init_gip(intf, out_pipe);

    CFAbsoluteTime deadline = opts->forever ? 0 : CFAbsoluteTimeGetCurrent() + opts->seconds;
    bool pending = false;
    ReadContext ctx = {0};
    while (!g_stop && (opts->forever || CFAbsoluteTimeGetCurrent() < deadline)) {
        if (!pending) {
            memset(&ctx, 0, sizeof(ctx));
            kr = (*intf)->ReadPipeAsync(intf, in_pipe, ctx.data, sizeof(ctx.data), read_cb, &ctx);
            if (kr != kIOReturnSuccess) {
                fprintf(stderr, "ReadPipeAsync: 0x%08x %s\n", kr, ret_str(kr));
                usleep(50000);
            } else {
                pending = true;
            }
        }

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        if (pending && ctx.done) {
            if (ctx.result == kIOReturnSuccess && ctx.size > 0) {
                handle_input_packet(ctx.data, ctx.size, opts->emit);
            }
            pending = false;
        }
    }

    if (pending) {
        (*intf)->AbortPipe(intf, in_pipe);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
    }

    release_all_keys(opts->emit);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), async_source, kCFRunLoopDefaultMode);
    CFRelease(async_source);
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return 0;
}

static Options parse_args(int argc, char **argv) {
    Options opts = {.emit = false, .forever = false, .seconds = 60, .config_path = NULL};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--emit")) {
            opts.emit = true;
        } else if (!strcmp(argv[i], "--forever")) {
            opts.forever = true;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            opts.seconds = atoi(argv[++i]);
            if (opts.seconds < 1) opts.seconds = 1;
            if (opts.seconds > 3600) opts.seconds = 3600;
        } else if (!strcmp(argv[i], "--config") && i + 1 < argc) {
            opts.config_path = argv[++i];
        } else {
            fprintf(stderr, "Usage: %s [--emit] [--forever] [--seconds N] [--config keymap.conf]\n", argv[0]);
            exit(2);
        }
    }
    return opts;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    Options opts = parse_args(argc, argv);
    init_key_labels();
    if (opts.config_path && !load_keymap(opts.config_path)) {
        return 2;
    }
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    int result = run_bridge(&opts);
    cleanup_event_source();
    return result;
}
