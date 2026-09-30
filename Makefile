APP_NAME := BatchPrint
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
SOURCES := $(shell find BatchPrint -name '*.swift')
SWIFT_FLAGS := -O -module-cache-path .build/swift-module-cache

.PHONY: build app run check clean

# 直接用 swiftc 编译。本机 Command Line Tools 自带的 SDK 与 SwiftPM 版本对不上，
# `swift build` 会报 “this SDK is not supported by the compiler”，所以这里绕开 SwiftPM。
build:
	mkdir -p "$(BUILD_DIR)"
	swiftc $(SWIFT_FLAGS) -o "$(BUILD_DIR)/$(APP_NAME)" $(SOURCES)
	@echo "已生成 $(BUILD_DIR)/$(APP_NAME)"

app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Support/Info.plist "$(APP_DIR)/Contents/Info.plist"
	printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	@echo "已生成 $(APP_DIR)"

run: app
	open "$(APP_DIR)"

# 打印参数自检：不开界面，直接打印这组参数最终会下发给打印机的选项。
check: build
	"$(BUILD_DIR)/$(APP_NAME)" --print-check

clean:
	swift package clean
	rm -rf dist
