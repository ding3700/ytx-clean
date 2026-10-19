ARCHS = arm64
TARGET := iphone:clang:latest:latest

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = YTXClean
YTXClean_FILES = YTXClean.xm
YTXClean_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
YTXClean_FRAMEWORKS = UIKit Foundation CoreMotion QuartzCore CoreFoundation

# install_name 决定 App 启动时去哪儿找这个 dylib。
# TrollFools 会把 dylib 放进 App 的 Frameworks 目录，所以走下面这条。
# 若启动时报 "image not found"，改成去掉 Frameworks/ 的那条再编一次。
YTXClean_LDFLAGS = -install_name @executable_path/Frameworks/YTXClean.dylib
# YTXClean_LDFLAGS = -install_name @executable_path/YTXClean.dylib

include $(THEOS_MAKE_PATH)/library.mk
