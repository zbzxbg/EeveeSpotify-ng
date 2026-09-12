#!/usr/bin/env bash
#
# 用**当前 CI 的 Xcode 工具链**从源码编译 SwiftProtobuf，替代 whoeevee 那份
# 预编译 deb。
#
# ── 为什么要自己编 ────────────────────────────────────────────────────────
# whoeevee/swift-protobuf 仓库已归档，其预编译 framework 是用 Swift 6.0.3 生成的
# `.swiftmodule`。Swift 的二进制模块格式**不跨编译器版本兼容**，所以在 Xcode 26.6
# （Swift 6.3.x）下导入会直接报 "module compiled with Swift X cannot be imported"。
# 而从源码编译出来的模块天然匹配当前工具链。
#
# ── 为什么不用 -enable-library-evolution ─────────────────────────────────
# 曾经加过它，目的是导出 `.swiftinterface` 以便将来换编译器时仍能重编。
# 结果导致启动闪退：它改变 ABI 弹性后，协议要求 / 泛型方法改走访问器，
# 符号发射方式变化，EeveeSpotify.dylib 在 dyld 阶段找不到
# `SwiftProtobuf.Decoder.decodeMapField` 的符号而 SIGABRT
# （崩溃日志 termination: namespace=DYLD, indicator="Symbol missing"）。
#
# 而且它本来就是多余的：framework 与 dylib 由**同一次 CI 的同一个 swiftc**
# 编译，版本必然匹配。「跨编译器不兼容」只在复用别人预编译产物时才会发生 ——
# 那正是这份脚本要摆脱的问题。
#
# 所以这里**刻意**与已验证可用的参考 flag 集合保持一致：
#   -O -emit-library -emit-module -Xfrontend -enable-testing -parse-as-library
#
# ── 为什么模块名不叫 EeveeSwiftProtobuf ─────────────────────────────────
# 参考实现（EeveeSpotifyReincarnated）把模块改名为 EeveeSwiftProtobuf，理由是
# Spotify 的 SpotifyShared.framework 里静态链了一份同名类。但本项目一直用的就是
# `SwiftProtobuf` 这个名字、且未出现崩溃，说明当前版本的 Spotify 并不冲突；
# 改名会连带改 Makefile 与 5 个自动生成的 .pb.swift 全部前缀，收益不明确。
# 所以这里**保持原名**，把改名留作可选的后续加固。
#
# ── 用法 ────────────────────────────────────────────────────────────────
#   ./Tools/SwiftProtobufBuild/build-swiftprotobuf.sh              # rootful
#   THEOS_PACKAGE_SCHEME=rootless ./Tools/.../build-swiftprotobuf.sh
#
# 输出路径与改动前那份预编译 deb 完全一致，所以 Makefile 不需要任何改动：
#   rootful  → $THEOS/lib/SwiftProtobuf.framework
#   rootless → $THEOS/lib/iphone/rootless/SwiftProtobuf.framework

set -euo pipefail

VERSION="${SWIFTPROTOBUF_VERSION:-1.29.0}"
SRC="${SRC_DIR:-/tmp/swiftprotobuf-build}"
MODULE="SwiftProtobuf"
SCHEME="${THEOS_PACKAGE_SCHEME:-rootful}"
DEPLOY_TARGET="${DEPLOY_TARGET:-14.0}"

# 编 arm64 + arm64e 并 lipo 成 fat。
#
# 两个都编，是为了与已验证可用的一份参考产物完全对齐
# （EeveeSpotifyReincarnated 的 EeveeSwiftProtobuf.framework）。
# 想省时间可以只留 arm64，但那就又多了一处与参考实现的差异。
ARCHS_TO_BUILD="${ARCHS_TO_BUILD:-arm64 arm64e}"

if [ -z "${THEOS:-}" ]; then
    echo "ERROR: THEOS 环境变量未设置"
    exit 1
fi

# roothide 用 @loader_path/.jbroot/...（每个 App 独立挂载命名空间）；
# rootful / rootless 用 @rpath/...（theos 打包时会注入对应的 rpath）。
if [ "$SCHEME" = "roothide" ]; then
    INSTALL_NAME="@loader_path/.jbroot/Library/Frameworks/${MODULE}.framework/${MODULE}"
else
    INSTALL_NAME="@rpath/${MODULE}.framework/${MODULE}"
fi

if [ "$SCHEME" = "rootless" ]; then
    OUT_DIR="$THEOS/lib/iphone/rootless"
else
    OUT_DIR="$THEOS/lib"
fi
OUT="${OUT_DIR}/${MODULE}.framework"

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

# ── 1. 取源码 ────────────────────────────────────────────────────────────
if [ ! -d "$SRC/.git" ]; then
    color "克隆 apple/swift-protobuf $VERSION"
    rm -rf "$SRC"
    # apple/swift-protobuf 的 tag 名不带 v 前缀（1.29.0 而非 v1.29.0）
    git clone --depth 1 --branch "$VERSION" \
        https://github.com/apple/swift-protobuf "$SRC"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
color "iPhoneOS SDK: $SDK"

SOURCES="$(find "$SRC/Sources/SwiftProtobuf" -name '*.swift')"
if [ -z "$SOURCES" ]; then
    echo "ERROR: 在 $SRC/Sources/SwiftProtobuf 下没找到 .swift 源码"
    exit 1
fi
color "源码文件数: $(echo "$SOURCES" | wc -l | tr -d ' ')"

# ── 2. 逐架构编译 ────────────────────────────────────────────────────────
build_arch() {
    local ARCH="$1"
    local TRIPLE="${ARCH}-apple-ios${DEPLOY_TARGET}"
    local OBJDIR="$SRC/build-${ARCH}"
    color "编译 $MODULE for $ARCH"
    rm -rf "$OBJDIR"
    mkdir -p "$OBJDIR"

    # shellcheck disable=SC2086
    #
    # ⚠️ 这里的 flag 集合是**刻意**与已验证可用的参考产物对齐的，改之前请先读文件头。
    #
    # 曾经的错误：加过 `-enable-library-evolution`（目的是导出 .swiftinterface 以兼容
    # 未来编译器）。它改变了 ABI 弹性 —— 协议要求与泛型方法改走访问器、符号发射方式变化，
    # 结果 EeveeSpotify.dylib 在启动期找不到 `SwiftProtobuf.Decoder.decodeMapField`
    # 的符号，dyld 直接 SIGABRT（"Symbol missing"）。
    # 而且它本来就是多余的：框架与 dylib 在同一次 CI 里用同一个 swiftc 编译，版本必然匹配；
    # 「跨编译器」只发生在使用别人预编译产物时。
    swiftc -O \
        -target "$TRIPLE" \
        -sdk "$SDK" \
        -emit-library \
        -emit-module \
        -module-name "$MODULE" \
        -Xfrontend -enable-testing \
        -parse-as-library \
        -Xlinker -install_name -Xlinker "$INSTALL_NAME" \
        -Xlinker -application_extension \
        -o "$OBJDIR/${MODULE}" \
        -emit-module-path "$OBJDIR/${MODULE}.swiftmodule" \
        $SOURCES

    if [ ! -f "$OBJDIR/${MODULE}" ]; then
        echo "ERROR: $ARCH 编译产物缺失: $OBJDIR/${MODULE}"
        exit 1
    fi
}

for ARCH in $ARCHS_TO_BUILD; do
    build_arch "$ARCH"
done

# ── 3. 组装 fat framework ────────────────────────────────────────────────
color "组装 framework 到 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Modules/${MODULE}.swiftmodule"

BINARIES=""
ARCH_COUNT=0
FIRST_ARCH=""
for ARCH in $ARCHS_TO_BUILD; do
    BINARIES="$BINARIES $SRC/build-${ARCH}/${MODULE}"
    ARCH_COUNT=$((ARCH_COUNT + 1))
    if [ -z "$FIRST_ARCH" ]; then
        FIRST_ARCH="$ARCH"
    fi
done

if [ "$ARCH_COUNT" -gt 1 ]; then
    # shellcheck disable=SC2086
    lipo -create $BINARIES -output "$OUT/${MODULE}"
else
    # 单架构时不能直接拼 "$ARCHS_TO_BUILD"（多个架构时它会变成
    # "arm64 arm64e" 这样的整串，拼出来的路径不存在），要用第一个架构。
    cp "$SRC/build-${FIRST_ARCH}/${MODULE}" "$OUT/${MODULE}"
fi

for ARCH in $ARCHS_TO_BUILD; do
    OBJDIR="$SRC/build-${ARCH}"
    TRIPLE="${ARCH}-apple-ios"
    cp "$OBJDIR/${MODULE}.swiftmodule"    "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.swiftmodule"
    cp "$OBJDIR/${MODULE}.swiftdoc"       "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.swiftdoc" 2>/dev/null || true
    cp "$OBJDIR/${MODULE}.abi.json"       "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.abi.json" 2>/dev/null || true
    # 注：不再生成 .swiftinterface（见文件头「为什么不用 -enable-library-evolution」）。
    # 这一行保留只是为了让「产物里有哪些模块文件」一目了然。
    if [ -f "$OBJDIR/${MODULE}.swiftinterface" ]; then
        cp "$OBJDIR/${MODULE}.swiftinterface" \
           "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.swiftinterface"
    fi
done

# ── 4. Info.plist ────────────────────────────────────────────────────────
cat > "$OUT/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${MODULE}</string>
    <key>CFBundleIdentifier</key><string>org.swift.protobuf.swiftprotobuf</string>
    <key>CFBundleName</key><string>${MODULE}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>MinimumOSVersion</key><string>${DEPLOY_TARGET}</string>
</dict>
</plist>
EOF

# ── 5. roothide 需要额外签名（RootHide 会校验注入依赖的签名）────────────
if [ "$SCHEME" = "roothide" ]; then
    command -v ldid >/dev/null 2>&1 || { echo "ERROR: ldid 未安装"; exit 1; }
    ldid -S "$OUT/${MODULE}"
fi

color "完成：$OUT"
ls -la "$OUT"
ls -la "$OUT/Modules/${MODULE}.swiftmodule"
file "$OUT/${MODULE}"
