TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard MobileSafari backboardd

include $(THEOS)/makefiles/common.mk

# Due dylib: Miao (SB+Safari, UIKit) e MiaoHID (solo backboardd, NO UIKit)
TWEAK_NAME = Miao MiaoHID

Miao_FILES = Tweak.x MiaoCore.m
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation
Miao_LIBRARIES = notify

MiaoHID_FILES = MiaoHID.x TouchSimBB.m
MiaoHID_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
MiaoHID_FRAMEWORKS = Foundation CoreFoundation CoreGraphics
MiaoHID_LIBRARIES = notify

include $(THEOS_MAKE_PATH)/tweak.mk
