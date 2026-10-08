#!/usr/bin/env bash
# Build gRPC for Unreal Engine 5.3 (Linux x86_64) with UE's own clang 16
# toolchain, libc++, OpenSSL and zlib. Works offline.
#
# Needs: bash, cmake >= 3.22, make, a UE 5.3 engine tree (Setup.sh already
# run) and a gRPC checkout with its submodules.
#
# Usage: build-grpc.sh <UnrealEngine dir> <grpc dir> [install dir]
set -euo pipefail

usage="usage: $0 <UnrealEngine dir> <grpc dir> [install dir]"
UE=$(realpath "${1:?$usage}")
GRPC=$(realpath "${2:?$usage}")
PREFIX=$(realpath -m "${3:-$PWD/grpc-ue53}")
BUILD="$PWD/grpc-ue53-build"

TC="$UE/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v22_clang-16.0.6-centos7/x86_64-unknown-linux-gnu"
TP="$UE/Engine/Source/ThirdParty"
LIBCXX="$TP/Unix/LibCxx"
LIBCXX_LIB="$LIBCXX/lib/Unix/x86_64-unknown-linux-gnu"
SSL_INC="$TP/OpenSSL/1.1.1t/include/Unix"
SSL_LIB="$TP/OpenSSL/1.1.1t/lib/Unix/x86_64-unknown-linux-gnu"
ZLIB_INC="$TP/zlib/1.2.13/include"
ZLIB_LIB="$TP/zlib/1.2.13/lib/Unix/x86_64-unknown-linux-gnu/Release/libz.a"

for f in "$TC/bin/clang++" "$LIBCXX/include/c++/v1/vector" "$LIBCXX_LIB/libc++.a" \
         "$SSL_LIB/libssl.a" "$ZLIB_LIB" "$GRPC/CMakeLists.txt" \
         "$GRPC"/third_party/{abseil-cpp,cares/cares,protobuf,re2}/CMakeLists.txt \
         "$GRPC/third_party/grpc-proto/grpc"; do
  [ -e "$f" ] || { echo "Missing: $f" >&2; exit 1; }
done

# CMake toolchain file: UE's clang + sysroot (glibc 2.17), UE's libc++ instead
# of libstdc++, lld. CMAKE_SYSTEM_NAME is deliberately not set (that would make
# gRPC look for a pre-installed host grpc_cpp_plugin).
# PROTOBUF_NO_INLINE_CALL works around a clang 16 crash in protobuf's
# parse_context.h; UE modules that include protobuf headers need it too.
mkdir -p "$BUILD"
cat > "$BUILD/ue53-toolchain.cmake" <<EOF
set(CMAKE_SYSROOT "$TC")
set(CMAKE_C_COMPILER "$TC/bin/clang")
set(CMAKE_CXX_COMPILER "$TC/bin/clang++")
set(CMAKE_C_COMPILER_TARGET x86_64-unknown-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET x86_64-unknown-linux-gnu)
set(CMAKE_AR "$TC/bin/llvm-ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "$TC/bin/x86_64-unknown-linux-gnu-ranlib" CACHE FILEPATH "")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_FLAGS_INIT "-fPIC")
set(CMAKE_CXX_FLAGS_INIT "-fPIC -nostdinc++ -isystem $LIBCXX/include/c++/v1 -DPROTOBUF_NO_INLINE_CALL")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_CXX_STANDARD_LIBRARIES "-nodefaultlibs $LIBCXX_LIB/libc++.a $LIBCXX_LIB/libc++abi.a -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
EOF

cmake -S "$GRPC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/ue53-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DgRPC_DOWNLOAD_ARCHIVES=OFF \
  -DgRPC_SSL_PROVIDER=package \
  -DOPENSSL_INCLUDE_DIR="$SSL_INC" \
  -DOPENSSL_SSL_LIBRARY="$SSL_LIB/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$SSL_LIB/libcrypto.a" \
  -DgRPC_ZLIB_PROVIDER=package \
  -DZLIB_INCLUDE_DIR="$ZLIB_INC" \
  -DZLIB_LIBRARY="$ZLIB_LIB" \
  -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_PYTHON_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF \
  -DRE2_BUILD_TESTING=OFF \
  -DCARES_BUILD_TOOLS=OFF
cmake --build "$BUILD" -j "$(nproc)"
cmake --install "$BUILD"

# Merge the ~100 static libraries into one archive for UE to link.
cd "$PREFIX/lib"
{
  echo "CREATE libgrpc_ue.a"
  for a in lib*.a; do
    case "$a" in  # skip duplicates of the secure libs and codegen-only libs
      libgrpc_ue.a|libgrpc_unsecure.a|libgrpc++_unsecure.a|libprotoc.a|libgrpc_plugin_support.a) ;;
      *) echo "ADDLIB $a" ;;
    esac
  done
  echo "SAVE"
} | "$TC/bin/llvm-ar" -M
"$TC/bin/x86_64-unknown-linux-gnu-ranlib" libgrpc_ue.a

echo "Done: $PREFIX/{include, lib/libgrpc_ue.a, bin/protoc, bin/grpc_cpp_plugin}"
