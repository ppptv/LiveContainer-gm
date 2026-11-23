# QuickBar dylib build (no Theos required; Xcode toolchain only)
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC  := $(shell xcrun --find clang)

NAME     := QuickBar
OUTPUT   := $(NAME).dylib
SRC      := $(NAME).m
MIN_OS   := 15.0

CFLAGS := -dynamiclib -fobjc-arc -fobjc-runtime=ios-$(MIN_OS) \
          -isysroot $(SDK) -miphoneos-version-min=$(MIN_OS) \
          -arch arm64 -O2 -Wall -Wno-unused-parameter \
          -framework Foundation -framework UIKit -framework QuartzCore \
          -framework CoreFoundation -framework CoreGraphics -lobjc

.PHONY: all clean info fix

all: $(OUTPUT)

$(OUTPUT): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -s - --force --timestamp=none $@
	@echo "Built and ad-hoc signed $@"

# Runtime geometry patch for the shipped QuickBar.dylib. Built separately and
# loaded next to it, so the verified QuickBar.dylib is never rebuilt from the
# newer QuickBar.m in this folder.
fix: QBLayoutFix.dylib

QBLayoutFix.dylib: QBLayoutFix.m
	$(CC) $(CFLAGS) -o $@ $<
	codesign -s - --force --timestamp=none $@
	@echo "Built and ad-hoc signed $@"

info:
	@echo "SDK: $(SDK)"
	@echo "CC:  $(CC)"

clean:
	rm -f $(OUTPUT) QBLayoutFix.dylib
