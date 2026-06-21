APP_NAME := HitboxBridge
APP_EXECUTABLE := HitboxBridgeApp
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
ARCH := $(shell uname -m)
SDKROOT := $(shell xcrun --show-sdk-path)
MODULE_CACHE := $(BUILD_DIR)/ModuleCache

.PHONY: all app clean

all: app usb_probe

app: $(MACOS_DIR)/$(APP_EXECUTABLE) $(MACOS_DIR)/hitbox_bridge $(CONTENTS_DIR)/Info.plist

hitbox_bridge: hitbox_bridge.c
	clang hitbox_bridge.c -framework IOKit -framework CoreFoundation -framework ApplicationServices -o hitbox_bridge

usb_probe: usb_probe.c
	clang usb_probe.c -framework IOKit -framework CoreFoundation -o usb_probe

$(MACOS_DIR)/hitbox_bridge: hitbox_bridge.c
	mkdir -p "$(MACOS_DIR)"
	clang hitbox_bridge.c -framework IOKit -framework CoreFoundation -framework ApplicationServices -o "$@"

$(MACOS_DIR)/$(APP_EXECUTABLE): app/HitboxBridgeApp.swift
	mkdir -p "$(MACOS_DIR)" "$(MODULE_CACHE)"
	xcrun swiftc app/HitboxBridgeApp.swift -parse-as-library -O -sdk "$(SDKROOT)" -target "$(ARCH)-apple-macosx13.0" -module-cache-path "$(MODULE_CACHE)" -o "$@"

$(CONTENTS_DIR)/Info.plist: app/Info.plist
	mkdir -p "$(CONTENTS_DIR)"
	cp app/Info.plist "$@"

clean:
	rm -rf "$(BUILD_DIR)"
