APP_NAME := BatchPrint
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
SOURCES := $(shell find BatchPrint -name '*.swift')
SWIFT_FLAGS := -O -module-cache-path .build/swift-module-cache

.PHONY: build app run check status resume retry-job self-test clean

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

# 打印前体检：队列有没有被停用、打印机在不在线。
status: build
	"$(BUILD_DIR)/$(APP_NAME)" --printer-status

# 恢复被停用的打印队列（等同界面上的“恢复队列”按钮）。
resume: build
	"$(BUILD_DIR)/$(APP_NAME)" --resume-printer

# 把队列出错策略改成自动重试：一次超时不再停掉整个队列。
retry-job: build
	"$(BUILD_DIR)/$(APP_NAME)" --enable-auto-retry

# 解析规则自检：不访问真实打印机，验证状态/地址解析是否还正确。
self-test: build
	"$(BUILD_DIR)/$(APP_NAME)" --self-test

clean:
	swift package clean
	rm -rf dist
