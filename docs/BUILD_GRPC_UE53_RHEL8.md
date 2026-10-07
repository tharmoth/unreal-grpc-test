# Building gRPC for Unreal Engine 5.3 on RHEL 8 (manual guide)

This guide builds gRPC C++ as static libraries with **Unreal Engine 5.3's own
Linux toolchain**: clang 16.0.6, UE's sysroot, and UE's libc++. The result
links into a UE 5.3 project without ABI or duplicate-symbol problems.

It's written for RHEL 8 but works on any x86_64 Linux host. The UE toolchain
brings its own sysroot, so the host's gcc and glibc don't affect the build.

> Paths marked *verify* are the usual UE 5.3 layout. Run the `find` commands
> shown to confirm them on your install.

---

## 0. Why not just `dnf install grpc` / build with system gcc?

UE on Linux doesn't use the system C++ library. It compiles against
**libc++** (`std::__1::…`) from `Engine/Source/ThirdParty/Unix/LibCxx`, and
it targets the glibc 2.17 sysroot that ships with its clang. A gRPC built
with RHEL's gcc uses **libstdc++** (`std::__cxx11::…`). Mixing the two gives
unresolved symbols like `grpc::CreateChannel(std::__cxx11::basic_string…)` at
link time, or memory corruption at runtime. UE also already contains OpenSSL
and zlib, and gRPC's bundled BoringSSL and zlib clash with them.

---

## 1. Prerequisites on RHEL 8

```bash
sudo dnf install -y git python3 make perl tar xz
# CMake >= 3.22 is required by gRPC 1.84. RHEL 8.8+ AppStream ships 3.26:
sudo dnf install -y cmake
cmake --version          # if < 3.22: python3 -m pip install --user "cmake>=3.22,<4"
# Ninja (from EPEL, or pip):
sudo dnf install -y ninja-build || python3 -m pip install --user ninja
```

You don't need a system compiler. Every C/C++ file is compiled by UE's clang.

---

## 2. Locate the UE 5.3 pieces

Set `UE_ROOT` to your engine directory, the one containing `Engine/`:

```bash
export UE_ROOT=$HOME/UnrealEngine          # adjust
```

### 2a. The clang toolchain (`v22_clang-16.0.6-centos7`)

If you built UE from source, `Setup.sh` already downloaded it:

```bash
ls "$UE_ROOT/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/"
# expect: v22_clang-16.0.6-centos7
export LINUX_MULTIARCH_ROOT="$UE_ROOT/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v22_clang-16.0.6-centos7"
```

Otherwise, download it from Epic and unpack it:

```bash
mkdir -p ~/ue-toolchain && cd ~/ue-toolchain
curl -LO https://cdn.unrealengine.com/Toolchain_Linux/native-linux-v22_clang-16.0.6-centos7.tar.gz
tar xf native-linux-v22_clang-16.0.6-centos7.tar.gz
export LINUX_MULTIARCH_ROOT=~/ue-toolchain/v22_clang-16.0.6-centos7
```

Check it:

```bash
export UE_TC="$LINUX_MULTIARCH_ROOT/x86_64-unknown-linux-gnu"
"$UE_TC/bin/clang++" --version      # clang version 16.0.6
ls "$UE_TC/bin" | grep -E 'ld.lld|llvm-ar|llvm-ranlib'
ls "$UE_TC/usr/lib64" 2>/dev/null | head   # the sysroot
```

### 2b. UE's libc++, OpenSSL, and zlib

The clang toolchain does **not** include libc++. Its sysroot only has
CentOS 7's libstdc++. libc++ comes from the engine tree, which `Setup.sh` /
`Setup.bat` populates. If you can't find it, see "Troubleshooting: LibCxx is
missing" at the end of this section.

```bash
export UE_TP="$UE_ROOT/Engine/Source/ThirdParty"

# libc++ (headers + static libs)
export UE_LIBCXX="$UE_TP/Unix/LibCxx"
ls "$UE_LIBCXX/include/c++/v1/vector"
export UE_LIBCXX_LIB="$UE_LIBCXX/lib/Unix/x86_64-unknown-linux-gnu"
ls "$UE_LIBCXX_LIB"/libc++.a "$UE_LIBCXX_LIB"/libc++abi.a

# OpenSSL (UE 5.3: 1.1.1t — verify)
find "$UE_TP/OpenSSL" -path '*x86_64-unknown-linux-gnu*' \( -name 'libssl.a' -o -name 'libcrypto.a' -o -name 'ssl.h' \)
export UE_OPENSSL_INC="$UE_TP/OpenSSL/1.1.1t/include/Unix/x86_64-unknown-linux-gnu"   # verify
export UE_OPENSSL_LIB="$UE_TP/OpenSSL/1.1.1t/lib/Unix/x86_64-unknown-linux-gnu"       # verify

# zlib (UE 5.3: 1.2.13 — verify)
find "$UE_TP/zlib" \( -name 'libz*.a' -path '*Unix*' \) -o -name 'zlib.h'
export UE_ZLIB_INC="$UE_TP/zlib/1.2.13/include"                                       # verify
export UE_ZLIB_LIB="$UE_TP/zlib/1.2.13/lib/Unix/x86_64-unknown-linux-gnu/Release/libz.a"  # verify
```

If any `find` shows a different path, use that path in the `export` lines.

#### Troubleshooting: LibCxx is missing

1. **Search the whole tree.** The folder may be somewhere other than where
   this guide expects (older engines used `ThirdParty/Linux/LibCxx`):
   ```bash
   find "$UE_ROOT/Engine" -name 'LibCxx.Build.cs' -o -name 'libc++.a' -o -name 'libc++abi.a'
   ```
   On Windows (PowerShell, from the engine root):
   ```powershell
   Get-ChildItem Engine -Recurse -Include LibCxx.Build.cs,libc++.a,libc++abi.a -ErrorAction SilentlyContinue | Select-Object FullName
   ```
2. **Check whether `Setup` was supposed to download it:**
   ```powershell
   Select-String -Path Engine\Build\Commit.gitdeps.xml -Pattern 'LibCxx' | Select-Object -First 5
   echo $env:UE_GITDEPS_ARGS
   ```
   If the manifest lists LibCxx files but they aren't on disk, Linux files
   were excluded. That happens when `Setup.bat` was run with
   `--exclude=Linux` / `--exclude=Unix`, or when `UE_GITDEPS_ARGS` contains
   an exclude. Clear the exclude and run `Setup.bat` again.

   If the only matches are license files (e.g. `libcxx_v18.1.0.license`),
   nothing is being excluded. The checkout simply doesn't ship LibCxx
   binaries, so check which engine version you have. A libc++ 18.1.0
   license means a newer engine than 5.3: clang/libc++ 18.1.0 came out
   in March 2024, after 5.3 shipped.
   ```powershell
   Get-Content Engine\Build\Build.version            # MajorVersion / MinorVersion
   Get-Content Engine\Config\Linux\Linux_SDK.json   # expect v22_clang-16.0.6-centos7 for 5.3
   git branch --show-current; git describe --tags
   ```
   For 5.3, check out the `5.3` branch (or a `5.3.x-release` tag), run
   `Setup.bat`, and search again.
3. **Other sources:**
   - Run `Setup.sh` on the Linux machine. It always fetches the Linux files.
   - Use a Launcher install of 5.3 with *Target Platforms → Linux* enabled.
4. **Last resort:** build libc++ yourself from LLVM sources. This is less
   safe. If the headers gRPC was compiled with are newer than the `libc++.a`
   UE links, you can get undefined `std::__1::…` symbols at the final UE link.

### 2c. Copying these pieces from a Windows UE 5.3 install

The `LibCxx`, `OpenSSL`, and `zlib` Linux files are identical on every host
OS. They're prebuilt Linux (ELF) archives that Epic ships for cross-compiling.
You can copy them from a Windows install, with three conditions:

- **The Linux files must be installed.** For a Launcher install, enable
  *Options → Target Platforms → Linux* on the 5.3 engine entry. For a
  source build, `Setup.bat` fetches them unless you excluded Linux.
  Check that `lib\Unix\x86_64-unknown-linux-gnu\libc++.a` exists under
  `Engine\Source\ThirdParty\Unix\LibCxx`.
- **Same engine version** (5.3.x) as the project you'll ship.
- **Copy them as an archive**, e.g. `tar -czf ue53-linux-deps.tar.gz …` (Windows 10+
  ships `tar`) or a zip. If you commit them through git on Windows, add a
  `.gitattributes` with `* -text` first so headers don't get CRLF line endings.

**The compiler is different.** The Windows "Linux cross-compile toolchain"
(`v22_clang-16.0.6-centos7.exe`) contains Windows `clang.exe` binaries, which
won't run on RHEL. Use the native Linux toolchain from step 2a instead. Its
sysroot matches the Windows one, but you need the Linux-hosted compiler.

---

## 3. Get the gRPC source

```bash
mkdir -p ~/grpc-ue && cd ~/grpc-ue
git clone --branch v1.84.0 --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/grpc/grpc
```

---

## 4. Write a CMake toolchain file for UE 5.3

Save as `~/grpc-ue/ue53-linux-x86_64.cmake`:

```cmake
# CMake toolchain: Unreal Engine 5.3 Linux (clang 16.0.6 + UE libc++)
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(UE_TC        "$ENV{LINUX_MULTIARCH_ROOT}/x86_64-unknown-linux-gnu")
set(UE_LIBCXX    "$ENV{UE_LIBCXX}")
set(UE_LIBCXX_LIB "$ENV{UE_LIBCXX_LIB}")

set(CMAKE_SYSROOT "${UE_TC}")
set(CMAKE_C_COMPILER   "${UE_TC}/bin/clang")
set(CMAKE_CXX_COMPILER "${UE_TC}/bin/clang++")
set(CMAKE_C_COMPILER_TARGET   x86_64-unknown-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET x86_64-unknown-linux-gnu)
set(CMAKE_AR     "${UE_TC}/bin/llvm-ar"     CACHE FILEPATH "")
set(CMAKE_RANLIB "${UE_TC}/bin/llvm-ranlib" CACHE FILEPATH "")

# Compile against UE's libc++ headers instead of the sysroot's libstdc++.
set(CMAKE_C_FLAGS_INIT   "-fPIC")
set(CMAKE_CXX_FLAGS_INIT "-fPIC -nostdinc++ -isystem ${UE_LIBCXX}/include/c++/v1")

# Link with lld and UE's static libc++ (same as UnrealBuildTool's LinuxToolChain).
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_CXX_STANDARD_LIBRARIES
    "-nodefaultlibs ${UE_LIBCXX_LIB}/libc++.a ${UE_LIBCXX_LIB}/libc++abi.a -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc")

# Allow find_* to see paths outside the sysroot (UE OpenSSL/zlib live there).
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
```

---

## 5. Configure, build, install

```bash
cd ~/grpc-ue
export PREFIX=~/grpc-ue/install

cmake -S grpc -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/grpc-ue/ue53-linux-x86_64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DgRPC_INSTALL=ON \
  -DgRPC_BUILD_TESTS=OFF \
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
  -DRE2_BUILD_TESTING=OFF

cmake --build build -j"$(nproc)"
cmake --install build
```

Check that CMake really picked up UE's compiler and OpenSSL. In the configure
output, look for:

- `The CXX compiler identification is Clang 16.0.6`, with the path pointing into `v22_clang-16.0.6-centos7`
- `Found OpenSSL: …/ThirdParty/OpenSSL/…`
- `Found ZLIB: …/ThirdParty/zlib/…`

The build takes about 15–40 minutes, depending on the number of cores.

### Troubleshooting the build

| Symptom | Fix |
|---|---|
| `fatal error: 'vector' file not found` | `UE_LIBCXX` is wrong or not exported in this shell. |
| `undefined reference to std::__1::…` while linking `protoc` | `UE_LIBCXX_LIB` is wrong, so the `libc++.a` path in `CMAKE_CXX_STANDARD_LIBRARIES` doesn't exist. |
| `undefined reference to dlopen` / `clock_gettime` | Make sure `-ldl -lrt` are in `CMAKE_CXX_STANDARD_LIBRARIES`. |
| `Could NOT find OpenSSL` | Fix `UE_OPENSSL_*`. Re-run with a clean `build/` directory, because CMake caches failed lookups. |
| OpenSSL link errors mentioning `dlopen`/`pthread` | Append `-ldl -lpthread` to `OPENSSL_CRYPTO_LIBRARY`, e.g. `-DOPENSSL_CRYPTO_LIBRARY="$UE_OPENSSL_LIB/libcrypto.a;-ldl;-lpthread"`. |
| CMake too old | `python3 -m pip install --user "cmake>=3.22,<4"` and make sure `~/.local/bin` is first in `PATH`. |

---

## 6. (Recommended) Merge everything into one archive

gRPC installs about 100 small `.a` files (abseil alone accounts for about 80 of them). UE's
Linux link step is sensitive to library order, so merge them into one archive:

```bash
cd "$PREFIX/lib"
{
  echo "CREATE libgrpc_ue.a"
  for a in lib*.a; do
    case "$a" in
      libgrpc_ue.a|libgrpc_unsecure.a|libgrpc++_unsecure.a|libprotoc.a|libgrpc_plugin_support.a) continue;;
    esac
    echo "ADDLIB $a"
  done
  echo "SAVE"; echo "END"
} > merge.mri
"$UE_TC/bin/llvm-ar" -M < merge.mri
"$UE_TC/bin/llvm-ranlib" libgrpc_ue.a
ls -lh libgrpc_ue.a
```

(The `*_unsecure` variants are skipped because they duplicate symbols from
the secure libraries. `libprotoc` and `libgrpc_plugin_support` are skipped
because only the code generators use them.)

---

## 7. Verify the build

```bash
cd "$PREFIX"

# 1) Uses libc++ (std::__1), never libstdc++ (std::__cxx11)
"$UE_TC/bin/llvm-nm" -C lib/libgrpc++.a | grep -c 'std::__1::'        # > 0
"$UE_TC/bin/llvm-nm" -C lib/*.a | grep -c 'std::__cxx11::'            # must be 0

# 2) Compiled by UE's clang
"$UE_TC/bin/llvm-readelf" -p .comment bin/protoc | grep -i clang   # 16.0.6

# 3) No BoringSSL / zlib definitions inside (they must come from UE)
"$UE_TC/bin/llvm-nm" --defined-only lib/libgrpc_ue.a 2>/dev/null | grep -E ' T (SSL_CTX_new|EVP_DigestInit|deflate)$'   # must be empty

# 4) Host tools run on RHEL 8 and need nothing newer than glibc 2.17 / no libstdc++
./bin/protoc --version
./bin/grpc_cpp_plugin --help >/dev/null 2>&1; echo "plugin exit: $?"
ldd bin/protoc                       # no libstdc++.so
objdump -T bin/protoc | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1   # <= GLIBC_2.17
```

### Smoke test: greeter client/server

```bash
cd ~/grpc-ue && mkdir -p smoke && cd smoke
cp ../grpc/examples/protos/helloworld.proto .
"$PREFIX/bin/protoc" -I. --cpp_out=. --grpc_out=. \
  --plugin=protoc-gen-grpc="$PREFIX/bin/grpc_cpp_plugin" helloworld.proto

CXX="$UE_TC/bin/clang++ --target=x86_64-unknown-linux-gnu --sysroot=$UE_TC \
  -std=c++17 -fPIC -nostdinc++ -isystem $UE_LIBCXX/include/c++/v1 -I$PREFIX/include -I."
LIBS="-fuse-ld=lld $PREFIX/lib/libgrpc_ue.a $UE_OPENSSL_LIB/libssl.a $UE_OPENSSL_LIB/libcrypto.a $UE_ZLIB_LIB \
  -nodefaultlibs $UE_LIBCXX_LIB/libc++.a $UE_LIBCXX_LIB/libc++abi.a -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc"

for p in server client; do
  $CXX ../grpc/examples/cpp/helloworld/greeter_$p.cc helloworld.pb.cc helloworld.grpc.pb.cc -o greeter_$p $LIBS
done
./greeter_server & sleep 1; ./greeter_client; kill %1
# expected: "Greeter received: Hello world"
```

If the greeter examples in your gRPC tag depend on `absl/flags`, they're
already inside `libgrpc_ue.a`. If linking reports missing `absl::flags`
symbols, make sure `libabsl_flags*.a` were installed and merged.

---

## 8. Using it from Unreal Engine 5.3

### 8a. Layout

```
YourProject/
  Source/ThirdParty/GrpcLibrary/
    GrpcLibrary.Build.cs
    include/          <- copy of $PREFIX/include
    lib/Linux/        <- libgrpc_ue.a
    bin/Linux/        <- protoc, grpc_cpp_plugin (for codegen only)
```

### 8b. `GrpcLibrary.Build.cs`

```csharp
using System.IO;
using UnrealBuildTool;

public class GrpcLibrary : ModuleRules
{
    public GrpcLibrary(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        PublicSystemIncludePaths.Add(Path.Combine(ModuleDirectory, "include"));

        if (Target.Platform == UnrealTargetPlatform.Linux)
        {
            PublicAdditionalLibraries.Add(Path.Combine(ModuleDirectory, "lib", "Linux", "libgrpc_ue.a"));
        }

        // Use the engine's OpenSSL and zlib (gRPC was built against them).
        AddEngineThirdPartyPrivateStaticDependencies(Target, "OpenSSL", "zlib");
    }
}
```

Then, in the module that calls gRPC (e.g. `YourGame.Build.cs`):

```csharp
PublicDependencyModuleNames.Add("GrpcLibrary");
bUseRTTI = true;               // generated protobuf code uses typeid/dynamic_cast
bEnableExceptions = false;     // gRPC/protobuf work without exceptions
// Generated .pb.cc files trip UE's stricter warnings:
bEnableUndefinedIdentifierWarnings = false;
```

### 8c. Including gRPC headers

Unreal defines macros (`check`, `verify`, `TEXT`, ...) that collide with
identifiers in protobuf, abseil, and gRPC. Wrap every include, including your
generated `*.pb.h` / `*.grpc.pb.h` files:

```cpp
// GrpcIncludes.h
#pragma once

THIRD_PARTY_INCLUDES_START
#pragma push_macro("check")
#pragma push_macro("verify")
#undef check
#undef verify

#include <grpcpp/grpcpp.h>
#include "MyService.grpc.pb.h"

#pragma pop_macro("verify")
#pragma pop_macro("check")
THIRD_PARTY_INCLUDES_END
```

Compile the generated `.pb.cc` files as part of a UE module, wrapping them
the same way: either rename them to `.cpp` with the wrapper at the top and
bottom, or include them from a wrapper `.cpp`.

### 8d. Generating code from your `.proto`

Always use the `protoc` and `grpc_cpp_plugin` from **this build**. The
generated code must match the protobuf runtime version exactly.

```bash
Source/ThirdParty/GrpcLibrary/bin/Linux/protoc -I protos \
  --cpp_out=Source/YourGame/Generated --grpc_out=Source/YourGame/Generated \
  --plugin=protoc-gen-grpc=Source/ThirdParty/GrpcLibrary/bin/Linux/grpc_cpp_plugin \
  protos/my_service.proto
```

### 8e. Threading note

gRPC runs its own threads. Don't touch `UObject`s from gRPC callbacks;
marshal results back with `AsyncTask(ENamedThreads::GameThread, …)`. Prefer
the async/completion-queue API, or blocking calls on a worker thread
(`FRunnable` / `UE::Tasks`), so the game thread never blocks on the network.
