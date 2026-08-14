TARGET := iphone:clang:16.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Miao

Miao_FILES = Tweak.x TouchSim.mm
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics
Miao_LDFLAGS = -framework IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo ">>> Miao rootless .deb pronto in ./packages/"
