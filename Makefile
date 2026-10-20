ARCHS = arm64
TARGET := iphone:clang:latest:latest

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = YTXClean
YTXClean_FILES = YTXClean.m
YTXClean_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
YTXClean_FRAMEWORKS = UIKit Foundation CoreMotion CoreFoundation
YTXClean_LDFLAGS = -install_name @executable_path/Frameworks/YTXClean.dylib

include $(THEOS_MAKE_PATH)/library.mk
