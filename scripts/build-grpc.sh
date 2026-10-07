#!/usr/bin/env bash
# Build gRPC (C++) for Unreal Engine 5.3 on Linux x86_64.
#
# Everything is compiled with UE 5.3's own toolchain (clang 16.0.6, CentOS 7
# sysroot / glibc 2.17), UE's libc++, and linked against UE's OpenSSL 1.1.1t
# and zlib 1.2.13, so the result links into a UE 5.3 module without ABI or
# duplicate-symbol problems.
#
# Usage:  scripts/build-grpc.sh            (see docs/BUILD_ON_LINUX.md)
#
# Environment overrides (all optional):
#   GRPC_VERSION          gRPC git tag                       (default v1.84.0)
#   CXX_STANDARD          C++ standard; must match your UE project (default 20)
#   LINUX_MULTIARCH_ROOT  An existing v22_clang-16.0.6-centos7 directory, e.g.
#                         <UE>/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v22_clang-16.0.6-centos7
#                         If unset, the toolchain is downloaded from Epic's CDN.
#   UE_THIRDPARTY_DIR     Directory containing OpenSSL/ and zlib/ (default: this repository).
#   UE_LIBCXX_ROOT        LibCxx directory (default: $UE_THIRDPARTY_DIR/LibCxx).
#                         To use a UE 5.3 engine tree directly instead of this repo's copies:
#                           UE_THIRDPARTY_DIR=<UE>/Engine/Source/ThirdParty
#                           UE_LIBCXX_ROOT=<UE>/Engine/Source/ThirdParty/Unix/LibCxx
#   WORK_DIR              Downloads, sources, build tree     (default <repo>/_work)
#   PREFIX                Install location                   (default <repo>/_install/grpc-<ver>-ue53-linux-x86_64)
#   JOBS                  Parallel build jobs                (default: nproc)
#   RUN_SMOKE_TEST        1 = build & run a client/server test (default 1)
#   CLEAN                 1 = wipe the gRPC build tree first (default 0)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GRPC_VERSION="${GRPC_VERSION:-v1.84.0}"
CXX_STANDARD="${CXX_STANDARD:-20}"
UE_THIRDPARTY_DIR="${UE_THIRDPARTY_DIR:-$REPO_ROOT}"
UE_LIBCXX_ROOT="${UE_LIBCXX_ROOT:-$UE_THIRDPARTY_DIR/LibCxx}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/_work}"
PREFIX="${PREFIX:-$REPO_ROOT/_install/grpc-${GRPC_VERSION}-ue53-linux-x86_64}"
JOBS="${JOBS:-$(nproc)}"
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-1}"
CLEAN="${CLEAN:-0}"

TOOLCHAIN_NAME="v22_clang-16.0.6-centos7"
TOOLCHAIN_URL="https://cdn.unrealengine.com/Toolchain_Linux/native-linux-${TOOLCHAIN_NAME}.tar.gz"
TOOLCHAIN_SHA256="ee7888e5e4209402c8d795fbec91a238ecd5de0d284422f77c5adfc0d15929be"

# Only these gRPC submodules are needed for this configuration (OpenSSL and
# zlib come from UE; tests, xDS proto regeneration, benchmarks are off).
GRPC_SUBMODULES=(third_party/abseil-cpp third_party/cares/cares third_party/grpc-proto third_party/protobuf third_party/re2)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# --------------------------------------------------------------------------
log "Checking host prerequisites"
for tool in git cmake tar curl sha256sum; do
  command -v "$tool" >/dev/null || die "'$tool' not found. See docs/BUILD_ON_LINUX.md (prerequisites)."
done
NINJA="$(command -v ninja || command -v ninja-build || true)"
[ -n "$NINJA" ] || die "'ninja' (or 'ninja-build') not found. See docs/BUILD_ON_LINUX.md (prerequisites)."
CMAKE_VER="$(cmake --version | head -1 | awk '{print $3}')"
version_ge "$CMAKE_VER" 3.22 || die "CMake $CMAKE_VER is too old; gRPC needs >= 3.22."
ok "cmake $CMAKE_VER, $(basename "$NINJA") $("$NINJA" --version)"

# --------------------------------------------------------------------------
log "Checking UE ThirdParty files"
UE_LIBCXX_LIB="$UE_LIBCXX_ROOT/lib/Unix/x86_64-unknown-linux-gnu"
UE_OPENSSL_INC="$UE_THIRDPARTY_DIR/OpenSSL/1.1.1t/include/Unix"
UE_OPENSSL_LIB="$UE_THIRDPARTY_DIR/OpenSSL/1.1.1t/lib/Unix/x86_64-unknown-linux-gnu"
UE_ZLIB_INC="$UE_THIRDPARTY_DIR/zlib/1.2.13/include"
UE_ZLIB_LIB="$UE_THIRDPARTY_DIR/zlib/1.2.13/lib/Unix/x86_64-unknown-linux-gnu/Release/libz.a"
for f in "$UE_LIBCXX_ROOT/include/c++/v1/vector" "$UE_LIBCXX_LIB/libc++.a" "$UE_LIBCXX_LIB/libc++abi.a" \
         "$UE_OPENSSL_INC/openssl/ssl.h" "$UE_OPENSSL_LIB/libssl.a" "$UE_OPENSSL_LIB/libcrypto.a" \
         "$UE_ZLIB_INC/zlib.h" "$UE_ZLIB_LIB"; do
  [ -f "$f" ] || die "Missing $f"
  # A Git LFS pointer instead of the real file is a common failure mode.
  if head -c 64 "$f" | grep -q 'git-lfs'; then die "$f is a Git LFS pointer; run 'git lfs pull'."; fi
done
ok "libc++, OpenSSL 1.1.1t and zlib 1.2.13 found under $UE_THIRDPARTY_DIR"

# --------------------------------------------------------------------------
log "Locating the UE 5.3 clang toolchain ($TOOLCHAIN_NAME)"
mkdir -p "$WORK_DIR"
if [ -z "${LINUX_MULTIARCH_ROOT:-}" ]; then
  LINUX_MULTIARCH_ROOT="$WORK_DIR/$TOOLCHAIN_NAME"
  if [ ! -x "$LINUX_MULTIARCH_ROOT/x86_64-unknown-linux-gnu/bin/clang++" ]; then
    TARBALL="$WORK_DIR/downloads/native-linux-${TOOLCHAIN_NAME}.tar.gz"
    mkdir -p "$WORK_DIR/downloads"
    if [ ! -f "$TARBALL" ] || ! echo "$TOOLCHAIN_SHA256  $TARBALL" | sha256sum -c --status; then
      echo "    Downloading $TOOLCHAIN_URL (~1.2 GB)"
      curl -fL# --retry 4 -o "$TARBALL.part" "$TOOLCHAIN_URL"
      mv "$TARBALL.part" "$TARBALL"
    fi
    echo "$TOOLCHAIN_SHA256  $TARBALL" | sha256sum -c --status || die "Toolchain checksum mismatch: $TARBALL"
    echo "    Extracting (x86_64 part only)"
    tar -xzf "$TARBALL" -C "$WORK_DIR" "$TOOLCHAIN_NAME/x86_64-unknown-linux-gnu"
  fi
fi
export UE_TOOLCHAIN_ROOT="$LINUX_MULTIARCH_ROOT/x86_64-unknown-linux-gnu"
export UE_LIBCXX_ROOT
TC="$UE_TOOLCHAIN_ROOT"
[ -x "$TC/bin/clang++" ] || die "No clang++ in $TC/bin"
"$TC/bin/clang++" --version | head -1 | grep -q 'clang version 16.0.6' \
  || die "Expected clang 16.0.6 in $TC (UE 5.3); got: $("$TC/bin/clang++" --version | head -1)"
ok "$("$TC/bin/clang++" --version | head -1)"
# GNU binutils shipped inside the toolchain (no host binutils needed).
BU="$TC/bin/x86_64-unknown-linux-gnu-"
NM="${BU}nm"; READELF="${BU}readelf"; OBJDUMP="${BU}objdump"; RANLIB="${BU}ranlib"

# --------------------------------------------------------------------------
log "Fetching gRPC $GRPC_VERSION"
SRC="$WORK_DIR/grpc-$GRPC_VERSION"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$GRPC_VERSION" https://github.com/grpc/grpc "$SRC"
fi
git -C "$SRC" submodule update --init --depth 1 --jobs 4 -- "${GRPC_SUBMODULES[@]}"
ok "$(git -C "$SRC" describe --tags) with submodules: ${GRPC_SUBMODULES[*]}"

# --------------------------------------------------------------------------
BUILD="$WORK_DIR/build-grpc-$GRPC_VERSION"
[ "$CLEAN" = 1 ] && rm -rf "$BUILD"
log "Configuring (C++$CXX_STANDARD, Release, static, PIC) in $BUILD"
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/cmake/ue53-linux-x86_64.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_CXX_STANDARD="$CXX_STANDARD" \
  -DCMAKE_CXX_STANDARD_REQUIRED=ON \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DgRPC_INSTALL=ON \
  -DgRPC_BUILD_TESTS=OFF \
  -DgRPC_DOWNLOAD_ARCHIVES=OFF \
  -DgRPC_ABSL_PROVIDER=module \
  -DgRPC_PROTOBUF_PROVIDER=module \
  -DgRPC_RE2_PROVIDER=module \
  -DgRPC_CARES_PROVIDER=module \
  -DgRPC_SSL_PROVIDER=package \
  -DOPENSSL_INCLUDE_DIR="$UE_OPENSSL_INC" \
  -DOPENSSL_SSL_LIBRARY="$UE_OPENSSL_LIB/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$UE_OPENSSL_LIB/libcrypto.a" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DgRPC_ZLIB_PROVIDER=package \
  -DZLIB_INCLUDE_DIR="$UE_ZLIB_INC" \
  -DZLIB_LIBRARY="$UE_ZLIB_LIB" \
  -DZLIB_USE_STATIC_LIBS=ON \
  -DgRPC_BUILD_CODEGEN=ON \
  -DgRPC_BUILD_GRPC_CPP_PLUGIN=ON \
  -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_PYTHON_PLUGIN=OFF \
  -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF \
  -DABSL_PROPAGATE_CXX_STD=ON \
  -DABSL_ENABLE_INSTALL=ON \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_INSTALL=ON \
  -DRE2_BUILD_TESTING=OFF \
  -DCARES_BUILD_TOOLS=OFF

log "Building with $JOBS jobs (this takes a while)"
cmake --build "$BUILD" -j "$JOBS"

log "Installing to $PREFIX"
rm -rf "$PREFIX"
cmake --install "$BUILD" >/dev/null
ok "installed"

# --------------------------------------------------------------------------
log "Merging static libraries into libgrpc_ue.a"
(
  cd "$PREFIX/lib"
  {
    echo "CREATE libgrpc_ue.a"
    for a in lib*.a; do
      case "$a" in
        # *_unsecure duplicate the secure libs; libprotoc/plugin_support are codegen-only.
        libgrpc_ue.a|libgrpc_unsecure.a|libgrpc++_unsecure.a|libprotoc.a|libgrpc_plugin_support.a) continue ;;
      esac
      echo "ADDLIB $a"
    done
    echo "SAVE"
    echo "END"
  } > merge.mri
  "$TC/bin/llvm-ar" -M < merge.mri
  "$RANLIB" libgrpc_ue.a
  rm merge.mri
)
ok "$(du -h "$PREFIX/lib/libgrpc_ue.a" | cut -f1) $PREFIX/lib/libgrpc_ue.a"

# --------------------------------------------------------------------------
log "Verifying the build"
n_libcxx=$("$NM" -C "$PREFIX/lib/libgrpc++.a" 2>/dev/null | grep -c 'std::__1::' || true)
[ "$n_libcxx" -gt 0 ] || die "libgrpc++.a has no libc++ (std::__1) symbols"
ok "uses UE libc++ (std::__1 symbols present)"
n_stdcxx=$("$NM" -C "$PREFIX"/lib/*.a 2>/dev/null | grep -c 'std::__cxx11::' || true)
[ "$n_stdcxx" -eq 0 ] || die "found $n_stdcxx libstdc++ (std::__cxx11) symbols"
ok "no libstdc++ (std::__cxx11) symbols"
dup=$("$NM" --defined-only "$PREFIX/lib/libgrpc_ue.a" 2>/dev/null | grep -E ' [TD] (SSL_CTX_new|EVP_DigestInit_ex|deflateInit_|inflate)$' || true)
[ -z "$dup" ] || die "OpenSSL/zlib symbols are defined inside libgrpc_ue.a (they must come from UE): $dup"
ok "no bundled OpenSSL/BoringSSL/zlib definitions"
for exe in protoc grpc_cpp_plugin; do
  [ -x "$PREFIX/bin/$exe" ] || die "missing $PREFIX/bin/$exe"
  glibc=$("$OBJDUMP" -T "$PREFIX/bin/$exe" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
  version_ge 2.17 "${glibc#GLIBC_}" || die "$exe needs $glibc (> 2.17)"
  ! "$READELF" -d "$PREFIX/bin/$exe" | grep -q 'libstdc++' || die "$exe links libstdc++"
  ok "$exe: max $glibc, no libstdc++"
done
ok "$("$PREFIX/bin/protoc" --version)"
"$READELF" -p .comment "$PREFIX/bin/protoc" | grep -q 'clang version 16.0.6' \
  || die "protoc was not compiled by UE's clang 16.0.6"
ok "compiled by UE clang 16.0.6"
nonpic=$("$READELF" -r "$PREFIX/lib/libgrpc_ue.a" | awk '/^Relocation section/{s=$3} /R_X86_64_(32|32S) /{if (s !~ /debug/) n++} END{print n+0}')
[ "$nonpic" -eq 0 ] || die "libgrpc_ue.a has $nonpic non-PIC relocations"
ok "libgrpc_ue.a is position-independent (safe for UE editor .so modules)"

# --------------------------------------------------------------------------
if [ "$RUN_SMOKE_TEST" = 1 ]; then
  log "Smoke test: codegen + client/server RPC over localhost"
  ST="$WORK_DIR/smoke-test"
  rm -rf "$ST" && mkdir -p "$ST"
  cp "$REPO_ROOT/scripts/smoke_test/smoke.proto" "$REPO_ROOT/scripts/smoke_test/smoke_test.cc" "$ST/"
  "$PREFIX/bin/protoc" -I "$ST" --cpp_out="$ST" --grpc_out="$ST" \
    --plugin=protoc-gen-grpc="$PREFIX/bin/grpc_cpp_plugin" "$ST/smoke.proto"
  "$TC/bin/clang++" --target=x86_64-unknown-linux-gnu --sysroot="$TC" \
    -std=c++"$CXX_STANDARD" -O2 -fPIC -DPROTOBUF_NO_INLINE_CALL -nostdinc++ -isystem "$UE_LIBCXX_ROOT/include/c++/v1" \
    -Wno-deprecated-declarations \
    -I "$PREFIX/include" -isystem "$UE_OPENSSL_INC" -I "$ST" \
    "$ST/smoke_test.cc" "$ST/smoke.pb.cc" "$ST/smoke.grpc.pb.cc" -o "$ST/smoke_test" \
    -fuse-ld=lld "$PREFIX/lib/libgrpc_ue.a" \
    "$UE_OPENSSL_LIB/libssl.a" "$UE_OPENSSL_LIB/libcrypto.a" "$UE_ZLIB_LIB" \
    -nodefaultlibs "$UE_LIBCXX_LIB/libc++.a" "$UE_LIBCXX_LIB/libc++abi.a" \
    -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc
  "$ST/smoke_test"
fi

# --------------------------------------------------------------------------
log "Done"
cat <<EOF
    gRPC $GRPC_VERSION for UE 5.3 (Linux x86_64, C++$CXX_STANDARD) is in:
      $PREFIX/include          headers
      $PREFIX/lib/libgrpc_ue.a single merged static library (link this from UE)
      $PREFIX/lib/*.a          the individual libraries
      $PREFIX/bin/protoc       code generators (use these for your .proto files)
      $PREFIX/bin/grpc_cpp_plugin
EOF
