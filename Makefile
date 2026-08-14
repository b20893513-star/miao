TARGET := iphone:clang:16.5:15.0
# OBBLIGATORIO per SpringBoard su A12+ (iPhone 11 = A13 = arm64e)
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Miao

Miao_FILES = Tweak.x TouchSim.mm
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo ">>> Miao rootless .deb pronto in ./packages/"
