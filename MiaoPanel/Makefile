TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MiaoPanel

MiaoPanel_FILES = main.m MPAppDelegate.m MPRootViewController.m MPReport.m
MiaoPanel_CFLAGS = -fobjc-arc -I..
MiaoPanel_FRAMEWORKS = UIKit CoreGraphics
MiaoPanel_CODESIGN_FLAGS = -Sentitlements.plist
MiaoPanel_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# Resources/entitlements.plist entra nel .app; qui lo copiamo anche in root del
# bundle per il postinst che fa ldid -S dopo dpkg.
after-MiaoPanel-stage::
	$(ECHO_NOTHING)cp -f entitlements.plist "$(THEOS_STAGING_DIR)$(MiaoPanel_INSTALL_PATH)/MiaoPanel.app/entitlements.plist" 2>/dev/null; \
	if [ -d "$(THEOS_STAGING_DIR)/var/jb$(MiaoPanel_INSTALL_PATH)/MiaoPanel.app" ]; then \
	  cp -f entitlements.plist "$(THEOS_STAGING_DIR)/var/jb$(MiaoPanel_INSTALL_PATH)/MiaoPanel.app/entitlements.plist"; \
	fi$(ECHO_END)
