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
# 另外脚本显式加了 `-emit-module-interface`：生成 `.swiftinterface` 之后，
# 即使将来再换编译器版本，也能从文本接口重新编译，而不是再次卡死。
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

# 只编 arm64：Makefile 里 ARCHS = arm64，编 arm64e 是纯浪费。
ARCHS_TO_BUILD="${ARCHS_TO_BUILD:-arm64}"

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
    swiftc -O \
        -target "$TRIPLE" \
        -sdk "$SDK" \
        -emit-library \
        -emit-module \
        -module-name "$MODULE" \
        -enable-library-evolution \
        -emit-module-interface \
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
for ARCH in $ARCHS_TO_BUILD; do
    BINARIES="$BINARIES $SRC/build-${ARCH}/${MODULE}"
done

if [ "$(echo "$ARCHS_TO_BUILD" | wc -w | tr -d ' ')" -gt 1 ]; then
    # shellcheck disable=SC2086
    lipo -create $BINARIES -output "$OUT/${MODULE}"
else
    cp "$SRC/build-${ARCHS_TO_BUILD}/${MODULE}" "$OUT/${MODULE}"
fi

for ARCH in $ARCHS_TO_BUILD; do
    OBJDIR="$SRC/build-${ARCH}"
    TRIPLE="${ARCH}-apple-ios"
    cp "$OBJDIR/${MODULE}.swiftmodule"    "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.swiftmodule"
    cp "$OBJDIR/${MODULE}.swiftdoc"       "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.swiftdoc" 2>/dev/null || true
    cp "$OBJDIR/${MODULE}.abi.json"       "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.abi.json" 2>/dev/null || true
    # ★ 关键：文本接口是跨编译器版本兼容的保证
    if [ -f "$OBJDIR/${MODULE}.swiftinterface" ]; then
        cp "$OBJDIR/${MODULE}.swiftinterface" \
           "$OUT/Modules/${MODULE}.swiftmodule/${TRIPLE}.swiftinterface"
    else
        echo "WARNING: 未生成 .swiftinterface —— 下次升 Xcode 可能再次撞上模块不兼容"
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
