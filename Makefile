TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard MobileSafari backboardd

include $(THEOS)/makefiles/common.mk

# Miao = SB+Safari. Il tap vero e' UIKit dentro Safari (TouchSimUIKit);
# l'HID resta come fallback. MiaoHID = backboardd best-effort.
TWEAK_NAME = Miao MiaoHID

Miao_FILES = Tweak.x MiaoCore.m TouchSimUIKit.m MiaoAX.m MiaoReport.m TouchSimSafari.m TouchSimBB.m
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation QuartzCore

MiaoHID_FILES = MiaoHID.m TouchSimBB.m
MiaoHID_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
MiaoHID_FRAMEWORKS = Foundation CoreFoundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

# Pannello: app vera sulla home, cosi' i risultati si guardano senza SSH
SUBPROJECTS += MiaoPanel
include $(THEOS_MAKE_PATH)/aggregate.mk
