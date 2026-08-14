TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Miao

# Niente TouchSim/HID: crashava SpringBoard/backboardd. Tap soft in-process in Safari.
Miao_FILES = Tweak.x
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
