#!/bin/zsh
# 编译并运行端到端解码自测（Tests/DecodeSelfTest.mm），需要一台已启动的 iOS 模拟器。
# 用法：scripts/run_decode_selftest.sh [--dump-frame <png 路径>]
#       scripts/run_decode_selftest.sh --dump-transfer <输出目录> <mode_val> <文件> [encode_id]   # 给 Debug 模拟相机用
set -euo pipefail

HERE=${0:A:h}
APP_ROOT=${HERE:h}
REPO=${APP_ROOT:h:h}
SRC=$REPO/src
OUT=$APP_ROOT/build/selftest
mkdir -p $OUT/obj

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=arm64-apple-ios16.0-simulator
OPENCV_DIR=$REPO/ios/ThirdParty/opencv2.xcframework/ios-arm64-simulator

COMMON=(-target $TARGET -isysroot $SDK -O2 -g0
  -DIOS=1 -DZSTD_STATIC_LINKING_ONLY=1 -DCIMBARD_NO_DEBUG=1 -DZSTD_DISABLE_ASM=1
  -I$SRC/lib -I$SRC/third_party_lib -I$SRC/third_party_lib/wirehair/include
  -I$SRC/third_party_lib/libcorrect/include -I$APP_ROOT/App
  -F$OPENCV_DIR -Wno-everything)

sources=(
  $SRC/lib/cimb_translator/*.cpp(N)
  $SRC/lib/extractor/*.cpp(N)
  $SRC/lib/cimbar_js/cimbar_recv_js.cpp
  $SRC/third_party_lib/wirehair/*.cpp(N)
  $SRC/third_party_lib/libcorrect/src/reed-solomon/*.c(N)
  $SRC/third_party_lib/zstd/common/*.c(N)
  $SRC/third_party_lib/zstd/decompress/*.c(N)
  $SRC/third_party_lib/zstd/compress/*.c(N)
  $APP_ROOT/App/NativeCimbarDecoder.mm
  $APP_ROOT/App/ReceivedFileStorage.mm
  $APP_ROOT/Tests/DecodeSelfTest.mm
)

objects=()
# 头文件改了也要重编：只比 .cpp/.mm 的时间会漏掉（10-27 因此把一次实验的结论弄错了）
newest_header=$(ls -t $SRC/lib/**/*.h(N) $SRC/lib/**/*.hpp(N) $APP_ROOT/App/*.h(N) 2>/dev/null | head -1)
for src in $sources; do
  obj=$OUT/obj/${${src#$REPO/}//\//_}.o
  objects+=$obj
  # 源文件和头文件都没变就不重编
  if [[ -f $obj && $obj -nt $src && ( -z $newest_header || $obj -nt $newest_header ) ]]; then continue; fi
  case $src in
    *.c)  xcrun clang -std=gnu11 $COMMON -c $src -o $obj ;;
    *.mm) xcrun clang++ -std=gnu++17 -fobjc-arc $COMMON -c $src -o $obj ;;
    *)    xcrun clang++ -std=gnu++17 $COMMON -c $src -o $obj ;;
  esac &
  # 限制并发
  while (( $(jobs -r | wc -l) >= 8 )); do sleep 0.2; done
done
wait

xcrun clang++ -target $TARGET -isysroot $SDK $objects -o $OUT/DecodeSelfTest \
  -F$OPENCV_DIR -framework opencv2 -framework Foundation -framework CoreVideo \
  -framework Accelerate -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lz
codesign --force --sign - $OUT/DecodeSelfTest >/dev/null 2>&1

xcrun simctl spawn ${SIMULATOR:-booted} $OUT/DecodeSelfTest "$@"
