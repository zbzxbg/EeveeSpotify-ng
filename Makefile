TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Spotify
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EeveeSpotify

EeveeSpotify_FILES = $(shell find Sources/EeveeSpotify -name '*.swift') $(shell find Sources/EeveeSpotifyC -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
EeveeSpotify_SWIFTFLAGS = -ISources/EeveeSpotifyC/include -Osize
EeveeSpotify_EXTRA_FRAMEWORKS = SwiftProtobuf
EeveeSpotify_CFLAGS = -fobjc-arc -ISources/EeveeSpotifyC/include -Os

include $(THEOS_MAKE_PATH)/tweak.mk

# ⚠️ 已弃用：这里下载的 whoeevee 预编译 deb 是用 Swift 6.0.3 生成的 .swiftmodule，
# 而 Swift 二进制模块不跨编译器版本兼容 —— Xcode 26.x（Swift 6.3.x）下会直接报
# "module compiled with Swift 6.0.3 cannot be imported"。该上游仓库已归档。
#
# 现在请改用源码编译脚本（CI 也是走它）：
#   ./Tools/SwiftProtobufBuild/build-swiftprotobuf.sh
#   THEOS_PACKAGE_SCHEME=rootless ./Tools/SwiftProtobufBuild/build-swiftprotobuf.sh
copy-swiftprotobuf:
	mkdir -p swiftprotobuf && cd swiftprotobuf ;\
	curl -OL https://github.com/whoeevee/EeveeSpotify/releases/download/swift2.0/org.swift.protobuf.swiftprotobuf_1.26.0_iphoneos-arm.deb ;\
	ar -x org.swift.protobuf.swiftprotobuf_1.26.0_iphoneos-arm.deb ;\
	tar -xvf data.tar.lzma ;\
	cp -r Library/Frameworks/SwiftProtobuf.framework "${THEOS}/lib" ;\
