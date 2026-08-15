TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Miao

# HID solo chiamato da MobileSafari (coordinate dal DOM). Non da SpringBoard.
Miao_FILES = Tweak.x TouchSim.mm
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
