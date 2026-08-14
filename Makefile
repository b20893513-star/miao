TARGET := iphone:clang:16.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Miao

Miao_FILES = Tweak.x TouchSim.mm
Miao_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function
Miao_FRAMEWORKS = UIKit Foundation CoreGraphics CoreFoundation
# IOKit risolto a runtime via dlopen — non linkare il framework (spesso manca nei SDK Theos)

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo ">>> Miao rootless .deb pronto in ./packages/"
