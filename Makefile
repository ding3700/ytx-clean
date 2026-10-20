ARCHS = arm64
TARGET := iphone:clang:latest:latest

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = YTXClean

# 注意：这里是 .m 不是 .xm —— 纯 Objective-C，不经过 Logos 预处理器
YTXClean_FILES = YTXClean.m

# -Wno-error：防止警告被当成错误（不同 Xcode 版本警告策略不同）
YTXClean_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations -Wno-unused-variable

YTXClean_FRAMEWORKS = UIKit Foundation CoreMotion CoreFoundation

# install_name 决定 App 启动时去哪儿找这个 dylib。
# TrollFools 把 dylib 放进 App 的 Frameworks 目录，所以走下面这条。
# 若启动时报 "image not found"，改成去掉 Frameworks/ 的那条再编一次。
YTXClean_LDFLAGS = -install_name @executable_path/Frameworks/YTXClean.dylib
# YTXClean_LDFLAGS = -install_name @executable_path/YTXClean.dylib

include $(THEOS_MAKE_PATH)/library.mk
