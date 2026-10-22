TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SendLater
SendLater_FILES = Tweak.x SLStore.m SLSender.m SLMessages.m
SendLater_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
SendLater_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 MobileSMS; killall -9 SpringBoard"
