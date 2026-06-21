#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <mach/mach_error.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_VENDOR 0x2DC8
#define DEFAULT_PRODUCT 0x202C

typedef struct {
    uint16_t vendor;
    uint16_t product;
    bool set_config;
    bool seize;
    bool read_pipes;
    bool init_gip;
    bool brief;
    int reads;
} Options;

typedef struct {
    bool done;
    IOReturn result;
    UInt32 size;
} AsyncReadContext;

typedef struct {
    UInt8 ref;
    UInt8 direction;
    UInt8 number;
    UInt8 type;
    UInt16 max_packet;
    UInt8 interval;
} PipeInfo;

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

static void prop_string(io_service_t service, CFStringRef key, char *out, size_t out_size) {
    out[0] = '\0';
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, out, out_size, kCFStringEncodingUTF8);
    }
    CFRelease(value);
}

static void print_hex(const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (i && (i % 16) == 0) printf("\n    ");
        printf("%02x ", buf[i]);
    }
    printf("\n");
}

static void async_read_cb(void *refcon, IOReturn result, void *arg0) {
    AsyncReadContext *ctx = (AsyncReadContext *)refcon;
    ctx->done = true;
    ctx->result = result;
    ctx->size = (UInt32)(uintptr_t)arg0;
}

static void write_packet(IOUSBInterfaceInterface **intf,
                         UInt8 pipe,
                         const char *label,
                         uint8_t *packet,
                         UInt32 size) {
    IOReturn kr = (*intf)->WritePipe(intf, pipe, packet, size);
    printf("    write %-14s pipe=%u: 0x%08x %s data=", label, pipe, kr, ret_str(kr));
    for (UInt32 i = 0; i < size; i++) printf("%02x", packet[i]);
    printf("\n");
}

static void send_gip_init(IOUSBInterfaceInterface **intf, UInt8 out_pipe) {
    static UInt8 seq = 0;
    uint8_t power_on[] = {0x05, 0x20, 0x00, 0x01, 0x00};
    uint8_t auth_done[] = {0x06, 0x20, 0x00, 0x02, 0x01, 0x00};
    uint8_t led_on[] = {0x0a, 0x20, 0x00, 0x03, 0x00, 0x01, 0x14};

    power_on[2] = seq++;
    write_packet(intf, out_pipe, "power_on", power_on, sizeof(power_on));
    usleep(20000);

    auth_done[2] = seq++;
    write_packet(intf, out_pipe, "auth_done", auth_done, sizeof(auth_done));
    usleep(20000);

    led_on[2] = seq++;
    write_packet(intf, out_pipe, "led_on", led_on, sizeof(led_on));
    usleep(20000);
}

static void read_from_pipe(IOUSBInterfaceInterface **intf, UInt8 pipe, int reads) {
    for (int i = 0; i < reads; i++) {
        uint8_t buf[128] = {0};
        AsyncReadContext ctx = {
            .done = false,
            .result = kIOReturnTimeout,
            .size = 0,
        };

        IOReturn rkr = (*intf)->ReadPipeAsync(intf, pipe, buf, sizeof(buf), async_read_cb, &ctx);
        if (rkr == kIOReturnSuccess) {
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1.0;
            while (!ctx.done && CFAbsoluteTimeGetCurrent() < deadline) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
            }
            if (!ctx.done) {
                (*intf)->AbortPipe(intf, pipe);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.20, true);
                (*intf)->ClearPipeStallBothEnds(intf, pipe);
                (*intf)->ResetPipe(intf, pipe);
                if (!ctx.done) {
                    ctx.result = kIOReturnTimeout;
                }
            }
        } else {
            ctx.result = rkr;
        }

        printf("      read %d: 0x%08x %s size=%u", i + 1, ctx.result, ret_str(ctx.result), ctx.size);
        if (ctx.result == kIOReturnSuccess && ctx.size > 0) {
            printf(" data=");
            for (UInt32 j = 0; j < ctx.size; j++) printf("%02x", buf[j]);
        }
        printf("\n");
    }
}

static const char *desc_type(uint8_t type) {
    switch (type) {
        case kUSBDeviceDesc: return "device";
        case kUSBConfDesc: return "config";
        case kUSBStringDesc: return "string";
        case kUSBInterfaceDesc: return "interface";
        case kUSBEndpointDesc: return "endpoint";
        case kUSBHIDDesc: return "hid";
        default: return "other";
    }
}

static const char *transfer_type(uint8_t type) {
    switch (type) {
        case 0: return "control";
        case 1: return "isochronous";
        case 2: return "bulk";
        case 3: return "interrupt";
        default: return "unknown";
    }
}

static const char *direction_name(uint8_t direction) {
    switch (direction) {
        case kUSBOut: return "out";
        case kUSBIn: return "in";
        case kUSBNone: return "none";
        case kUSBAnyDirn: return "any";
        default: return "unknown";
    }
}

static void parse_config_descriptor(const uint8_t *buf, size_t len) {
    if (len < 9) {
        printf("  config descriptor too short: %zu bytes\n", len);
        return;
    }

    printf("  raw config descriptor (%zu bytes):\n    ", len);
    print_hex(buf, len);

    printf("  descriptor walk:\n");
    size_t pos = 0;
    while (pos + 2 <= len) {
        uint8_t bLength = buf[pos];
        uint8_t bDescriptorType = buf[pos + 1];
        if (bLength < 2 || pos + bLength > len) {
            printf("    @%zu invalid length=%u type=0x%02x\n", pos, bLength, bDescriptorType);
            break;
        }

        printf("    @%03zu len=%u type=0x%02x (%s)", pos, bLength, bDescriptorType, desc_type(bDescriptorType));
        if (bDescriptorType == kUSBConfDesc && bLength >= 9) {
            printf(" total=%u interfaces=%u configValue=%u attrs=0x%02x maxPower=%umA",
                   le16(buf + pos + 2), buf[pos + 4], buf[pos + 5], buf[pos + 7], buf[pos + 8] * 2);
        } else if (bDescriptorType == kUSBInterfaceDesc && bLength >= 9) {
            printf(" if=%u alt=%u endpoints=%u class=0x%02x sub=0x%02x proto=0x%02x",
                   buf[pos + 2], buf[pos + 3], buf[pos + 4], buf[pos + 5], buf[pos + 6], buf[pos + 7]);
        } else if (bDescriptorType == kUSBEndpointDesc && bLength >= 7) {
            uint8_t addr = buf[pos + 2];
            uint8_t attrs = buf[pos + 3];
            printf(" ep=0x%02x dir=%s type=%s maxPacket=%u interval=%u",
                   addr,
                   (addr & 0x80) ? "in" : "out",
                   transfer_type(attrs & 0x03),
                   le16(buf + pos + 4),
                   buf[pos + 6]);
        }
        printf("\n");
        pos += bLength;
    }
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
        printf("  IOCreatePlugInInterfaceForService(device) failed: 0x%08x %s\n", kr, ret_str(kr));
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
        printf("  QueryInterface(device) failed: 0x%08x\n", (unsigned int)hr);
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
        printf("    IOCreatePlugInInterfaceForService(interface) failed: 0x%08x %s\n", kr, ret_str(kr));
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
        printf("    QueryInterface(interface) failed: 0x%08x\n", (unsigned int)hr);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

static void print_device_methods(IOUSBDeviceInterface **dev) {
    UInt8 cls = 0, sub = 0, proto = 0, speed = 0;
    UInt16 vendor = 0, product = 0, release = 0;
    USBDeviceAddress addr = 0;

    (*dev)->GetDeviceClass(dev, &cls);
    (*dev)->GetDeviceSubClass(dev, &sub);
    (*dev)->GetDeviceProtocol(dev, &proto);
    (*dev)->GetDeviceVendor(dev, &vendor);
    (*dev)->GetDeviceProduct(dev, &product);
    (*dev)->GetDeviceReleaseNumber(dev, &release);
    (*dev)->GetDeviceAddress(dev, &addr);
    (*dev)->GetDeviceSpeed(dev, &speed);

    printf("  methods: vid=0x%04x pid=0x%04x bcdDevice=0x%04x class=0x%02x sub=0x%02x proto=0x%02x addr=%u speed=%u\n",
           vendor, product, release, cls, sub, proto, addr, speed);
}

static void read_config_via_request(IOUSBDeviceInterface **dev) {
    uint8_t header[9] = {0};
    IOUSBDevRequestTO req = {0};
    req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
    req.bRequest = kUSBRqGetDescriptor;
    req.wValue = (kUSBConfDesc << 8) | 0;
    req.wIndex = 0;
    req.wLength = sizeof(header);
    req.pData = header;
    req.noDataTimeout = 1000;
    req.completionTimeout = 1000;

    IOReturn kr = (*dev)->DeviceRequestTO(dev, &req);
    printf("  GET_DESCRIPTOR(config header): 0x%08x %s", kr, ret_str(kr));
    if (kr != kIOReturnSuccess) {
        printf("\n");
        return;
    }

    printf(" (%u bytes)\n", req.wLenDone);
    if (req.wLenDone < 9) return;

    uint16_t total = le16(header + 2);
    if (total < 9 || total > 4096) {
        printf("  config total length looks odd: %u\n", total);
        return;
    }

    uint8_t *buf = calloc(total, 1);
    if (!buf) return;
    req.wLength = total;
    req.pData = buf;
    req.wLenDone = 0;
    kr = (*dev)->DeviceRequestTO(dev, &req);
    printf("  GET_DESCRIPTOR(config full): 0x%08x %s", kr, ret_str(kr));
    if (kr == kIOReturnSuccess) {
        printf(" (%u bytes)\n", req.wLenDone);
        parse_config_descriptor(buf, req.wLenDone);
    } else {
        printf("\n");
    }
    free(buf);
}

static void read_config_via_cached_ptr(IOUSBDeviceInterface **dev) {
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    IOReturn kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg);
    printf("  cached config descriptor[0]: 0x%08x %s", kr, ret_str(kr));
    if (kr != kIOReturnSuccess || !cfg) {
        printf("\n");
        return;
    }

    uint16_t total = USBToHostWord(cfg->wTotalLength);
    printf(" (%u bytes)\n", total);
    if (total >= 9 && total < 4096) {
        parse_config_descriptor((const uint8_t *)cfg, total);
    }
}

static void probe_interface(io_service_t intf_service, const Options *opts) {
    char name[256];
    IORegistryEntryGetName(intf_service, name);
    long if_num = prop_i64(intf_service, CFSTR("bInterfaceNumber"), -1);
    long alt = prop_i64(intf_service, CFSTR("bAlternateSetting"), -1);
    long cls = prop_i64(intf_service, CFSTR("bInterfaceClass"), -1);
    long sub = prop_i64(intf_service, CFSTR("bInterfaceSubClass"), -1);
    long proto = prop_i64(intf_service, CFSTR("bInterfaceProtocol"), -1);
    long eps = prop_i64(intf_service, CFSTR("bNumEndpoints"), -1);

    printf("  interface: %s if=%ld alt=%ld endpoints=%ld class=0x%02lx sub=0x%02lx proto=0x%02lx\n",
           name, if_num, alt, eps, cls, sub, proto);

    IOUSBInterfaceInterface **intf = NULL;
    IOReturn kr = create_interface_interface(intf_service, &intf);
    if (kr != kIOReturnSuccess || !intf) return;

    kr = (*intf)->USBInterfaceOpen(intf);
    printf("    USBInterfaceOpen: 0x%08x %s\n", kr, ret_str(kr));
    if (kr != kIOReturnSuccess) {
        (*intf)->Release(intf);
        return;
    }

    UInt8 pipe_count = 0;
    kr = (*intf)->GetNumEndpoints(intf, &pipe_count);
    printf("    GetNumEndpoints: 0x%08x %s count=%u\n", kr, ret_str(kr), pipe_count);
    if (kr == kIOReturnSuccess) {
        CFRunLoopSourceRef async_source = NULL;
        bool async_ready = false;
        if (opts->read_pipes) {
            IOReturn askr = (*intf)->CreateInterfaceAsyncEventSource(intf, &async_source);
            printf("    CreateInterfaceAsyncEventSource: 0x%08x %s\n", askr, ret_str(askr));
            if (askr == kIOReturnSuccess && async_source) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), async_source, kCFRunLoopDefaultMode);
                async_ready = true;
            }
        }

        PipeInfo pipes[32] = {0};
        UInt8 saved_pipes = 0;
        UInt8 first_interrupt_in = 0;
        UInt8 first_interrupt_out = 0;

        for (UInt8 pipe = 1; pipe <= pipe_count && pipe < 32; pipe++) {
            UInt8 direction = 0, number = 0, type = 0, interval = 0;
            UInt16 max_packet = 0;
            kr = (*intf)->GetPipeProperties(intf, pipe, &direction, &number, &type, &max_packet, &interval);
            printf("    pipe %u: 0x%08x %s dir=%s ep=%u type=%s maxPacket=%u interval=%u\n",
                   pipe, kr, ret_str(kr), direction_name(direction), number,
                   transfer_type(type), max_packet, interval);

            if (kr == kIOReturnSuccess) {
                pipes[saved_pipes++] = (PipeInfo){
                    .ref = pipe,
                    .direction = direction,
                    .number = number,
                    .type = type,
                    .max_packet = max_packet,
                    .interval = interval,
                };
                if (!first_interrupt_in && direction == kUSBIn && type == 3) {
                    first_interrupt_in = pipe;
                }
                if (!first_interrupt_out && direction == kUSBOut && type == 3) {
                    first_interrupt_out = pipe;
                }
            }
        }

        if (opts->init_gip && first_interrupt_out) {
            send_gip_init(intf, first_interrupt_out);
        } else if (opts->init_gip) {
            printf("    --init-gip requested but no interrupt OUT pipe found\n");
        }

        if (opts->read_pipes && async_ready) {
            for (UInt8 i = 0; i < saved_pipes; i++) {
                if (pipes[i].direction == kUSBIn && pipes[i].type == 3) {
                    printf("    reading interrupt IN pipe %u\n", pipes[i].ref);
                    read_from_pipe(intf, pipes[i].ref, opts->reads);
                }
            }
        }

        if (async_source) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), async_source, kCFRunLoopDefaultMode);
            CFRelease(async_source);
        }
    }

    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
}

static void enumerate_interfaces(IOUSBDeviceInterface **dev, const Options *opts) {
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn kr = (*dev)->CreateInterfaceIterator(dev, &req, &iterator);
    printf("  CreateInterfaceIterator: 0x%08x %s\n", kr, ret_str(kr));
    if (kr != kIOReturnSuccess || iterator == IO_OBJECT_NULL) return;

    int count = 0;
    io_service_t intf_service;
    while ((intf_service = IOIteratorNext(iterator))) {
        count++;
        probe_interface(intf_service, opts);
        IOObjectRelease(intf_service);
    }
    IOObjectRelease(iterator);
    printf("  interfaces found: %d\n", count);
}

static void probe_device(io_service_t service, const Options *opts, int index) {
    char name[256] = {0};
    char product_name[256] = {0};
    char vendor_name[256] = {0};
    IORegistryEntryGetName(service, name);
    prop_string(service, CFSTR("USB Product Name"), product_name, sizeof(product_name));
    prop_string(service, CFSTR("USB Vendor Name"), vendor_name, sizeof(vendor_name));

    printf("device #%d: %s\n", index, name);
    printf("  registry: product=\"%s\" vendor=\"%s\" vid=0x%04lx pid=0x%04lx location=0x%08lx currentConfig=%ld\n",
           product_name,
           vendor_name,
           prop_i64(service, CFSTR("idVendor"), -1),
           prop_i64(service, CFSTR("idProduct"), -1),
           prop_i64(service, CFSTR("locationID"), -1),
           prop_i64(service, CFSTR("kUSBCurrentConfiguration"), -1));

    IOUSBDeviceInterface **dev = NULL;
    IOReturn kr = create_device_interface(service, &dev);
    if (kr != kIOReturnSuccess || !dev) return;

    print_device_methods(dev);
    if (!opts->brief) {
        read_config_via_cached_ptr(dev);
        read_config_via_request(dev);
    }

    if (opts->set_config) {
        IOReturn open_kr = opts->seize ? (*dev)->USBDeviceOpenSeize(dev) : (*dev)->USBDeviceOpen(dev);
        printf("  %s: 0x%08x %s\n", opts->seize ? "USBDeviceOpenSeize" : "USBDeviceOpen", open_kr, ret_str(open_kr));
        if (open_kr == kIOReturnSuccess) {
            IOUSBConfigurationDescriptorPtr cfg = NULL;
            kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg);
            UInt8 config_value = cfg ? cfg->bConfigurationValue : 1;
            IOReturn set_kr = (*dev)->SetConfiguration(dev, config_value);
            printf("  SetConfiguration(%u): 0x%08x %s\n", config_value, set_kr, ret_str(set_kr));
            sleep(1);
            enumerate_interfaces(dev, opts);
            (*dev)->USBDeviceClose(dev);
        } else {
            printf("  skipping SetConfiguration/interface probe because device open failed\n");
        }
    } else {
        enumerate_interfaces(dev, opts);
    }

    (*dev)->Release(dev);
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "Usage: %s [--set-config] [--seize] [--read-pipes] [--reads N] [--vid HEX] [--pid HEX]\n"
            "          [--init-gip] [--brief]\n"
            "Default target: VID 0x%04x PID 0x%04x\n",
            argv0, DEFAULT_VENDOR, DEFAULT_PRODUCT);
}

static uint16_t parse_hex_u16(const char *s) {
    char *end = NULL;
    unsigned long v = strtoul(s, &end, 0);
    if (!s[0] || (end && *end) || v > 0xffff) {
        fprintf(stderr, "invalid 16-bit value: %s\n", s);
        exit(2);
    }
    return (uint16_t)v;
}

static Options parse_args(int argc, char **argv) {
    Options opts = {
        .vendor = DEFAULT_VENDOR,
        .product = DEFAULT_PRODUCT,
        .set_config = false,
        .seize = false,
        .read_pipes = false,
        .init_gip = false,
        .brief = false,
        .reads = 3,
    };

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--set-config")) {
            opts.set_config = true;
        } else if (!strcmp(argv[i], "--seize")) {
            opts.seize = true;
        } else if (!strcmp(argv[i], "--read-pipes")) {
            opts.read_pipes = true;
        } else if (!strcmp(argv[i], "--init-gip")) {
            opts.init_gip = true;
        } else if (!strcmp(argv[i], "--brief")) {
            opts.brief = true;
        } else if (!strcmp(argv[i], "--reads") && i + 1 < argc) {
            opts.reads = atoi(argv[++i]);
            if (opts.reads < 1) opts.reads = 1;
            if (opts.reads > 100) opts.reads = 100;
        } else if (!strcmp(argv[i], "--vid") && i + 1 < argc) {
            opts.vendor = parse_hex_u16(argv[++i]);
        } else if (!strcmp(argv[i], "--pid") && i + 1 < argc) {
            opts.product = parse_hex_u16(argv[++i]);
        } else {
            usage(argv[0]);
            exit(2);
        }
    }
    return opts;
}

int main(int argc, char **argv) {
    Options opts = parse_args(argc, argv);

    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) {
        fprintf(stderr, "IOServiceMatching failed\n");
        return 1;
    }

    CFNumberRef vendor = cfnum_u16(opts.vendor);
    CFNumberRef product = cfnum_u16(opts.product);
    CFDictionarySetValue(match, CFSTR("idVendor"), vendor);
    CFDictionarySetValue(match, CFSTR("idProduct"), product);
    CFRelease(vendor);
    CFRelease(product);

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "IOServiceGetMatchingServices: 0x%08x %s\n", kr, ret_str(kr));
        return 1;
    }

    int count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        count++;
        probe_device(service, &opts, count);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (count == 0) {
        printf("No matching IOUSBHostDevice for VID 0x%04x PID 0x%04x\n", opts.vendor, opts.product);
        return 1;
    }
    return 0;
}
