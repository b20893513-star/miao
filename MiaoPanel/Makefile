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
