APP_NAME := HitboxBridge
APP_EXECUTABLE := HitboxBridgeApp
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
ARCH := $(shell uname -m)
SDKROOT := $(shell xcrun --show-sdk-path)
MODULE_CACHE := $(BUILD_DIR)/ModuleCache
CORE_OBJ := $(BUILD_DIR)/hitbox_bridge_core.o
BRIDGE_SRCS := src/hitbox_bridge.c src/hitbox_bridge_core.c
BRIDGE_HDRS := src/hitbox_bridge_core.h
PROBE_SRC := tools/usb_probe.c
APP_ICON := app/AppIcon.icns
APP_ICON_NAME := EightBitDoAppIcon.icns
APP_SIGN_IDENTITY ?= -

.PHONY: all app clean

all: app hitbox_bridge usb_probe

app: $(MACOS_DIR)/$(APP_EXECUTABLE) $(CONTENTS_DIR)/Info.plist $(RESOURCES_DIR)/$(APP_ICON_NAME)
	codesign --force --sign "$(APP_SIGN_IDENTITY)" --timestamp=none "$(APP_DIR)"

hitbox_bridge: $(BRIDGE_SRCS) $(BRIDGE_HDRS)
	clang $(BRIDGE_SRCS) -framework IOKit -framework CoreFoundation -o hitbox_bridge

usb_probe: $(PROBE_SRC)
	clang $(PROBE_SRC) -framework IOKit -framework CoreFoundation -o usb_probe

$(CORE_OBJ): src/hitbox_bridge_core.c src/hitbox_bridge_core.h
	mkdir -p "$(BUILD_DIR)"
	clang -c src/hitbox_bridge_core.c -isysroot "$(SDKROOT)" -target "$(ARCH)-apple-macosx13.0" -o "$@"

$(MACOS_DIR)/$(APP_EXECUTABLE): app/HitboxBridgeApp.swift app/HitboxBridge-Bridging-Header.h $(CORE_OBJ)
	mkdir -p "$(MACOS_DIR)" "$(MODULE_CACHE)"
	xcrun swiftc app/HitboxBridgeApp.swift "$(CORE_OBJ)" -import-objc-header app/HitboxBridge-Bridging-Header.h -parse-as-library -O -sdk "$(SDKROOT)" -target "$(ARCH)-apple-macosx13.0" -module-cache-path "$(MODULE_CACHE)" -framework IOKit -framework CoreFoundation -o "$@"

$(CONTENTS_DIR)/Info.plist: app/Info.plist
	mkdir -p "$(CONTENTS_DIR)"
	cp app/Info.plist "$@"

$(RESOURCES_DIR)/$(APP_ICON_NAME): $(APP_ICON)
	mkdir -p "$(RESOURCES_DIR)"
	cp "$(APP_ICON)" "$@"

clean:
	rm -rf "$(BUILD_DIR)"
