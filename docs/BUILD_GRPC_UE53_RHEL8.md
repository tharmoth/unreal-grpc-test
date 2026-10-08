# How the gRPC build for Unreal Engine 5.3 works (manual guide)

This guide explains how [`scripts/build-grpc.sh`](../scripts/build-grpc.sh)
builds gRPC C++ with **Unreal Engine 5.3's own Linux toolchain**: clang
16.0.6, UE's sysroot (glibc 2.17), and UE's libc++. The result links into a
UE 5.3 project without ABI or duplicate-symbol problems. Use it to
understand the script, to do the steps by hand, or to debug a failed build.
To just run it, see [BUILD_ON_LINUX.md](BUILD_ON_LINUX.md).

It works on any x86_64 Linux host, including offline ones. The UE toolchain
brings its own sysroot, so the host's gcc and glibc don't affect the build.

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

## 1. Prerequisites

`bash`, `cmake` 3.22 or newer, and `make`. On RHEL 8: `sudo dnf install cmake make`.
RHEL 8.8+ ships CMake 3.26. You don't need a system compiler, Ninja, Python,
git, or internet access. Every C/C++ file is compiled by UE's clang.

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

If it's missing, download it on a machine with internet access and copy it
into that folder:
`https://cdn.unrealengine.com/Toolchain_Linux/native-linux-v22_clang-16.0.6-centos7.tar.gz`
(about 1.2 GB; it unpacks to `v22_clang-16.0.6-centos7/`).

Check it:

```bash
export UE_TC="$LINUX_MULTIARCH_ROOT/x86_64-unknown-linux-gnu"
"$UE_TC/bin/clang++" --version      # clang version 16.0.6
ls "$UE_TC/bin" | grep -E 'ld.lld|llvm-ar|x86_64-unknown-linux-gnu-ranlib'
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

# OpenSSL (UE 5.3: 1.1.1t, paths as in OpenSSL.Build.cs)
export UE_OPENSSL_INC="$UE_TP/OpenSSL/1.1.1t/include/Unix"
export UE_OPENSSL_LIB="$UE_TP/OpenSSL/1.1.1t/lib/Unix/x86_64-unknown-linux-gnu"
ls "$UE_OPENSSL_INC/openssl/ssl.h" "$UE_OPENSSL_LIB"/libssl.a "$UE_OPENSSL_LIB"/libcrypto.a

# zlib (UE 5.3: 1.2.13, as in zlib.Build.cs; ignore the old v1.2.8 folder)
ls "$UE_TP/zlib/1.2.13/include/zlib.h" "$UE_TP/zlib/1.2.13/lib/Unix/x86_64-unknown-linux-gnu/Release/libz.a"
export UE_ZLIB_INC="$UE_TP/zlib/1.2.13/include"
export UE_ZLIB_LIB="$UE_TP/zlib/1.2.13/lib/Unix/x86_64-unknown-linux-gnu/Release/libz.a"
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

## 3. What `build-grpc.sh` does

Usage: `build-grpc.sh <UnrealEngine dir> <grpc dir> [install dir]`. The gRPC
checkout needs five submodules (`abseil-cpp`, `cares/cares`, `grpc-proto`,
`protobuf`, `re2`); see [BUILD_ON_LINUX.md](BUILD_ON_LINUX.md#getting-the-grpc-source-onto-the-machine).

### 3a. Writes a CMake toolchain file

The script writes `grpc-ue53-build/ue53-toolchain.cmake`, which points CMake at:

- UE's `clang`/`clang++`, its sysroot (`CMAKE_SYSROOT`), `llvm-ar`, and lld
  (`-fuse-ld=lld`).
- **UE's libc++ instead of libstdc++.** At compile time it uses
  `-nostdinc++ -isystem <LibCxx>/include/c++/v1`. At link time,
  `CMAKE_CXX_STANDARD_LIBRARIES` is set to `-nodefaultlibs libc++.a
  libc++abi.a -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc`. This mirrors
  UnrealBuildTool's `LinuxToolChain`.
- `-fPIC` everywhere. UE editor builds load game modules as `.so` files.
- `-DPROTOBUF_NO_INLINE_CALL`. **UE 5.3's clang 16.0.6 segfaults** on
  protobuf's statement-level `[[clang::always_inline]]` in
  `parse_context.h`. This define is protobuf's supported way to turn that
  inlining hint off, and it doesn't change the ABI. Any UE module that
  includes protobuf headers needs it too (see section 6).
- `ranlib` comes from the toolchain's GNU binutils
  (`x86_64-unknown-linux-gnu-ranlib`). The toolchain has no `llvm-ranlib`,
  `llvm-nm` or `llvm-readelf`.

`CMAKE_SYSTEM_NAME` is deliberately **not** set. Setting it makes CMake
treat the build as a cross-compile, and gRPC then looks for a pre-installed
host `grpc_cpp_plugin` instead of using the one it builds.

### 3b. Configures gRPC

These options differ from gRPC's defaults:

| Option | Why |
|---|---|
| `CMAKE_BUILD_TYPE=Release` | Optimized build |
| `CMAKE_CXX_STANDARD=20` | Must match the UE project. abseil picks some types (e.g. `absl::strong_ordering`) based on the standard, so mixing standards gives mismatched types. |
| `gRPC_DOWNLOAD_ARCHIVES=OFF` | Never touch the network (missing optional protos are only needed for tests) |
| `gRPC_SSL_PROVIDER=package` + `OPENSSL_*` | Use **UE's OpenSSL 1.1.1t**. gRPC's bundled BoringSSL defines the same symbols and would clash with the engine's copy. |
| `gRPC_ZLIB_PROVIDER=package` + `ZLIB_*` | Use **UE's zlib 1.2.13**, for the same reason |
| `gRPC_BUILD_GRPC_<LANG>_PLUGIN=OFF` | Only the C++ code generator is needed |
| `RE2_BUILD_TESTING=OFF`, `CARES_BUILD_TOOLS=OFF` | Skip test and tool programs |

abseil, protobuf, re2 and c-ares are built from gRPC's submodules, which is
gRPC's default. UE 5.3's engine doesn't contain them.

In the configure output, check for:

- `The CXX compiler identification is Clang 16.0.6`
- `Found OpenSSL: …/ThirdParty/OpenSSL/1.1.1t/…`
- `Found ZLIB: …/ThirdParty/zlib/1.2.13/…`

### 3c. Builds, installs, and merges the libraries

The script runs `cmake --build` with `make -j$(nproc)`, then `cmake --install`.
gRPC installs about 100 static libraries (abseil alone is about 80), and UE's
Linux link step is sensitive to library order, so the script merges them
into one `lib/libgrpc_ue.a` with an `llvm-ar -M` script. It skips:

- `*_unsecure`, which duplicates the secure libraries
- `libprotoc` and `libgrpc_plugin_support`, which only the code generators use

---

## 4. Verifying a build

[`scripts/test-grpc-build.sh`](../scripts/test-grpc-build.sh) is the quick
check. It generates code with the new `protoc`, builds a test program, and
makes a plaintext and a TLS call over localhost. To inspect the libraries
by hand (`TC` = `.../v22_clang-16.0.6-centos7/x86_64-unknown-linux-gnu`,
run from the install dir):

```bash
# 1) Uses libc++ (std::__1), never libstdc++ (std::__cxx11)
"$TC/bin/x86_64-unknown-linux-gnu-nm" -C lib/libgrpc++.a | grep -c 'std::__1::'        # > 0
"$TC/bin/x86_64-unknown-linux-gnu-nm" -C lib/*.a | grep -c 'std::__cxx11::'            # must be 0

# 2) Compiled by UE's clang
"$TC/bin/x86_64-unknown-linux-gnu-readelf" -p .comment bin/protoc | grep -i clang   # 16.0.6

# 3) No BoringSSL / zlib definitions inside (they must come from UE)
"$TC/bin/x86_64-unknown-linux-gnu-nm" --defined-only lib/libgrpc_ue.a 2>/dev/null | grep -E ' T (SSL_CTX_new|EVP_DigestInit|deflate)$'   # must be empty

# 4) Host tools run on RHEL 8 and need nothing newer than glibc 2.17 / no libstdc++
./bin/protoc --version
./bin/grpc_cpp_plugin --help >/dev/null 2>&1; echo "plugin exit: $?"
ldd bin/protoc                       # no libstdc++.so
objdump -T bin/protoc | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1   # <= GLIBC_2.17
```

---

## 5. Troubleshooting the build

| Symptom | Fix |
|---|---|
| `clang frontend command failed with exit code 139` in `parse_context.h` | clang 16 bug with protobuf's `[[clang::always_inline]]`. Compile with `-DPROTOBUF_NO_INLINE_CALL`. |
| `fatal error: 'vector' file not found` | UE's LibCxx headers weren't found. Check `Engine/Source/ThirdParty/Unix/LibCxx/include/c++/v1`. |
| `undefined reference to std::__1::…` | The `libc++.a` path is wrong, or something was compiled without UE's libc++ headers. |
| `Could NOT find OpenSSL` / `ZLIB` | Wrong path. Delete the build directory before re-running, because CMake caches failed lookups. |
| gRPC looks for a host `grpc_cpp_plugin` | `CMAKE_SYSTEM_NAME` was set in a toolchain file. Remove it. |
| `CMake 3.22 or higher is required` | Install a newer CMake. The official tarball from cmake.org works offline. |

---

## 6. Using it from Unreal Engine 5.3

### 6a. Layout

```
YourProject/
  Source/ThirdParty/GrpcLibrary/          <- External module: UBT never compiles files here
    GrpcLibrary.Build.cs
    include/          <- copy of <install dir>/include, plus this repo's
                         ue/GrpcIncludesBegin.h and ue/GrpcIncludesEnd.h
    lib/Linux/        <- libgrpc_ue.a
    bin/Linux/        <- protoc, grpc_cpp_plugin (for codegen only)
    generated/        <- protoc output (*.pb.h, *.pb.cc, *.grpc.pb.h, *.grpc.pb.cc)
  Source/YourGame/Private/
    MyServiceProtos.cpp   <- compiles the generated .pb.cc files (see 6c)
```

The generated `.pb.cc` files **must not** live in your game module's source
tree. UBT would compile them directly with Unreal's `check`/`verify` macros
defined, and they fail inside Abseil's btree (see 6c).

### 6b. `GrpcLibrary.Build.cs`

```csharp
using System.IO;
using UnrealBuildTool;

public class GrpcLibrary : ModuleRules
{
    public GrpcLibrary(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        PublicSystemIncludePaths.Add(Path.Combine(ModuleDirectory, "include"));
        PublicSystemIncludePaths.Add(Path.Combine(ModuleDirectory, "generated"));

        if (Target.Platform == UnrealTargetPlatform.Linux)
        {
            PublicAdditionalLibraries.Add(Path.Combine(ModuleDirectory, "lib", "Linux", "libgrpc_ue.a"));
        }

        // Use the engine's OpenSSL and zlib (gRPC was built against them).
        AddEngineThirdPartyPrivateStaticDependencies(Target, "OpenSSL", "zlib");

        // REQUIRED: UE 5.3's clang 16.0.6 crashes (segfault) on protobuf's
        // statement-level [[clang::always_inline]] in parse_context.h, which
        // every generated .pb.h includes. This turns that inlining hint off;
        // gRPC was built with the same define.
        PublicDefinitions.Add("PROTOBUF_NO_INLINE_CALL=1");
    }
}
```

Then, in the module that calls gRPC (e.g. `YourGame.Build.cs`):

```csharp
PublicDependencyModuleNames.Add("GrpcLibrary");
// bUseRTTI = true;          // optional: a -fno-rtti -fno-exceptions .so test
//                          // built and ran fine; enable only if you hit RTTI errors
bEnableExceptions = false;     // gRPC/protobuf work without exceptions
// Generated .pb.cc files trip UE's stricter warnings:
bEnableUndefinedIdentifierWarnings = false;
```

### 6c. Including gRPC headers and compiling generated code

Unreal defines `check(expr)` and `verify(expr)` macros in every file of a
module. Abseil's btree, which every generated `.pb.cc` pulls in through
protobuf, declares a member function `verify()`. The macro rewrites it, and
you get errors like:

```
absl/container/internal/btree.h:1596:8: error: expected member name or ';' after declaration specifiers
absl/container/internal/btree_container.h:207:48: error: use of undeclared identifier 'get_allocator'
absl/container/btree_map.h:509:30: error: no member named 'btree_access' in namespace 'absl::container_internal'
```

The fix is to hide `check`/`verify` while gRPC/protobuf code is parsed.
[`ue/GrpcIncludesBegin.h`](../ue/GrpcIncludesBegin.h) and
[`ue/GrpcIncludesEnd.h`](../ue/GrpcIncludesEnd.h) do that (plus
`THIRD_PARTY_INCLUDES_START/END` and silencing gRPC's own deprecation
warnings). Put both in `GrpcLibrary/include/`.

**1. Wherever you include gRPC or generated headers:**

```cpp
#include "GrpcIncludesBegin.h"
#include <grpcpp/grpcpp.h>
#include "helloworld.grpc.pb.h"
#include "GrpcIncludesEnd.h"
// check()/verify() work normally again from here on
```

**2. Compile the generated sources through one wrapper `.cpp`** in your game
module ([`ue/ProtoSources.cpp.example`](../ue/ProtoSources.cpp.example)):

```cpp
// Source/YourGame/Private/HelloworldProtos.cpp
#include "GrpcIncludesBegin.h"
#include "helloworld.pb.cc"
#include "helloworld.grpc.pb.cc"
#include "GrpcIncludesEnd.h"
```

This was tested with gRPC's helloworld example under UE-style conditions:
`check`/`verify` force-included into every file, `-fno-rtti
-fno-exceptions`, built as a shared library. It compiled, linked with
`--no-undefined`, and got `Hello Unreal` back from gRPC's `greeter_server`.
Compiling the same `helloworld.pb.cc` directly gave 20 btree errors.

### 6d. Generating code from your `.proto`

Always use the `protoc` and `grpc_cpp_plugin` from **this build**. The
generated code must match the protobuf runtime version exactly. Generate
into the External module's `generated/` folder, not into your game module:

```bash
G=Source/ThirdParty/GrpcLibrary
$G/bin/Linux/protoc -I protos --cpp_out=$G/generated --grpc_out=$G/generated \
  --plugin=protoc-gen-grpc=$G/bin/Linux/grpc_cpp_plugin protos/helloworld.proto
```

Then add the new `.pb.cc` / `.grpc.pb.cc` files to your wrapper `.cpp`.

### 6e. Threading note

gRPC runs its own threads. Don't touch `UObject`s from gRPC callbacks;
marshal results back with `AsyncTask(ENamedThreads::GameThread, …)`. Prefer
the async/completion-queue API, or blocking calls on a worker thread
(`FRunnable` / `UE::Tasks`), so the game thread never blocks on the network.
