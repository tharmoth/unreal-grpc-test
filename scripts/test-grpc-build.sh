#!/usr/bin/env bash
# Optional: check a build-grpc.sh result by generating code with its protoc and
# running a plaintext + TLS client/server round trip over localhost.
#
# Usage: test-grpc-build.sh <UnrealEngine dir> [install dir]
set -euo pipefail

UE=$(realpath "${1:?usage: $0 <UnrealEngine dir> [install dir]}")
PREFIX=$(realpath "${2:-$PWD/grpc-ue53}")
HERE=$(dirname "$(realpath "$0")")/smoke_test
OUT="$PWD/grpc-ue53-test"

TC="$UE/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v22_clang-16.0.6-centos7/x86_64-unknown-linux-gnu"
TP="$UE/Engine/Source/ThirdParty"
LIBCXX="$TP/Unix/LibCxx"
LIBCXX_LIB="$LIBCXX/lib/Unix/x86_64-unknown-linux-gnu"
SSL="$TP/OpenSSL/1.1.1t"

mkdir -p "$OUT"
"$PREFIX/bin/protoc" -I "$HERE" --cpp_out="$OUT" --grpc_out="$OUT" \
  --plugin=protoc-gen-grpc="$PREFIX/bin/grpc_cpp_plugin" "$HERE/smoke.proto"
"$TC/bin/clang++" --sysroot="$TC" -std=c++20 -O2 -fPIC -DPROTOBUF_NO_INLINE_CALL \
  -Wno-deprecated-declarations -nostdinc++ -isystem "$LIBCXX/include/c++/v1" \
  -I "$PREFIX/include" -isystem "$SSL/include/Unix" -I "$OUT" \
  "$HERE/smoke_test.cc" "$OUT/smoke.pb.cc" "$OUT/smoke.grpc.pb.cc" -o "$OUT/smoke_test" \
  -fuse-ld=lld "$PREFIX/lib/libgrpc_ue.a" \
  "$SSL/lib/Unix/x86_64-unknown-linux-gnu/libssl.a" "$SSL/lib/Unix/x86_64-unknown-linux-gnu/libcrypto.a" \
  "$TP/zlib/1.2.13/lib/Unix/x86_64-unknown-linux-gnu/Release/libz.a" \
  -nodefaultlibs "$LIBCXX_LIB/libc++.a" "$LIBCXX_LIB/libc++abi.a" -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc
"$OUT/smoke_test"
