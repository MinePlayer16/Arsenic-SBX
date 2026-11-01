TARGET := iphone:clang:latest:17.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ArsenicSBX

ArsenicSBX_FILES = Tweak.m

ArsenicSBX_CCFLAGS = $(ArsenicSBX_CFLAGS)
ArsenicSBX_OBJCFLAGS = $(ArsenicSBX_CFLAGS)
ArsenicSBX_OBJCCFLAGS = $(ArsenicSBX_CFLAGS)

ArsenicSBX_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation
ArsenicSBX_PRIVATE_FRAMEWORKS = IOSurface
ArsenicSBX_LIBRARIES = z sandbox

include $(THEOS_MAKE_PATH)/tweak.mk
