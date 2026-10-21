TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = MonitorPlus
THEOS_PACKAGE_SCHEME ?= roothide

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
THEOS_PACKAGE_DIR = rootless
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
THEOS_PACKAGE_DIR = roothide
else
THEOS_PACKAGE_DIR = rootful
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MonitorPlusHook

MonitorPlusHook_FILES = Tweak.xm
MonitorPlusHook_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
