# Plan: build gRPC with the Unreal Engine 5.3 Linux toolchain

Status: **draft for review**. Nothing has been built yet.

## Goal

Produce a static build of gRPC (C++), plus its `protoc` and `grpc_cpp_plugin`
code generators, that links cleanly into an Unreal Engine 5.3 C++ project on
RHEL 8. "Built with Unreal's C++" means:

| What | UE 5.3 value |
|---|---|
| Compiler | UE's bundled clang 16.0.6 (toolchain `v22_clang-16.0.6-centos7`) |
| Sysroot / glibc | The sysroot inside that toolchain (CentOS 7, glibc 2.17) |
| C++ standard library | UE's **libc++** from `Engine/Source/ThirdParty/Unix/LibCxx`, not the system libstdc++ |
| Linker | `ld.lld` from the same toolchain |
| Code model | `-fPIC` (editor builds load game modules as `.so` files) |

If any of these differ from what UE uses, the link fails or the program
crashes at runtime. The most common mismatch is libstdc++ vs libc++, where
`std::string` and other types have different layouts.

## Key decisions (please confirm or change)

1. **gRPC version: `v1.84.0`**, the latest stable tag today. It needs CMake 3.22 or newer and a
   C++17 compiler. If your backend already uses a gRPC/protobuf version, the
   wire protocol is compatible across versions, so the frontend doesn't need to match it.
2. **TLS: use UE's own OpenSSL**, not gRPC's bundled BoringSSL. UE 5.3 already
   links OpenSSL 1.1.1 into the engine. BoringSSL defines the same symbols
   (`SSL_*`, `EVP_*`, ...), so bundling both causes duplicate-symbol link
   errors or, worse, runtime crashes when the wrong copy is called.
   (`-DgRPC_SSL_PROVIDER=package`)
3. **zlib: use UE's own zlib** for the same reason. (`-DgRPC_ZLIB_PROVIDER=package`)
4. **abseil, protobuf, re2, c-ares: use gRPC's bundled copies** (`module`).
   UE 5.3's core engine doesn't ship these. Step 6 checks for symbol clashes
   with any plugins you enable.
5. **C++17** for the gRPC build. This is the standard gRPC tests against.
   Code compiled with it links fine into UE 5.3 modules, which default to C++20.
6. **Static libraries, Release, `-fPIC`**, with RTTI and exceptions left at gRPC's
   defaults (enabled). UE modules compile with `-fno-rtti -fno-exceptions`. That's
   safe because the gRPC code is compiled separately. The UE wrapper module
   that includes generated `.pb.h` headers sets `bUseRTTI = true`.
7. **Build `protoc` and `grpc_cpp_plugin` with the same toolchain.** They then run on
   RHEL 8 (and anything with glibc ≥ 2.17), and they're guaranteed to match
   the protobuf runtime version.
8. **Deliver one merged archive** (`libgrpc_ue.a`) alongside the individual
   `.a` files. Unreal's Linux linker is sensitive to static-library order, and
   abseil alone produces about 80 archives. One archive avoids that problem.

## Steps I'll run

1. **Stage inputs.** Unpack the UE toolchain and the UE ThirdParty folders
   (see "What I need from you") into a scratch area outside the repo. Neither
   goes into git.
2. **Fetch gRPC.** `git clone --branch v1.84.0 --recurse-submodules --shallow-submodules`.
3. **Write a CMake toolchain file** (`cmake/ue53-linux-x86_64.cmake`). It points CMake
   at the UE clang, sysroot, `llvm-ar`/`ld.lld`, and UE's libc++ headers and
   archives (`-nostdinc++ -isystem …/LibCxx/include/c++/v1`, then
   `-nodefaultlibs libc++.a libc++abi.a -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc` at
   link time). This mirrors what UnrealBuildTool's `LinuxToolChain` does.
4. **Configure and build** with Ninja:
   - `gRPC_SSL_PROVIDER=package` → UE OpenSSL (explicit `OPENSSL_*` paths)
   - `gRPC_ZLIB_PROVIDER=package` → UE zlib (explicit `ZLIB_*` paths)
   - `gRPC_BUILD_TESTS=OFF`, every codegen plugin except C++ turned off
   - `CMAKE_BUILD_TYPE=Release`, `CMAKE_POSITION_INDEPENDENT_CODE=ON`
   - `CMAKE_INSTALL_PREFIX=<repo>/ThirdParty/grpc` (or a release tarball, see below)
5. **Merge archives** into `libgrpc_ue.a` with an `llvm-ar` MRI script.
6. **Verify the ABI and dependencies:**
   - `nm -C` on every archive: zero `std::__cxx11::` (libstdc++) symbols, and
     `std::__1::` (libc++) present.
   - `readelf -s` / `objdump -p` on `protoc`: needs no GLIBC symbol newer than 2.17,
     and no `libstdc++.so`.
   - No `SSL_`/`EVP_`/`deflate` definitions inside the gRPC archives, so they
     resolve to UE's copies.
   - The `readelf -p .comment` compiler string shows clang 16.0.6 (UE), not the host clang.
7. **Smoke test.** Use the built `protoc` + `grpc_cpp_plugin` to generate the
   `helloworld.proto` greeter, build a client and server with the same
   toolchain and libc++, and run them against each other over localhost.
   This checks codegen, linking, and runtime together.
8. **UE integration skeleton (optional, after you approve).** Add an external
   `ThirdParty/GrpcLibrary` module with a `Build.cs`, plus the
   `THIRD_PARTY_INCLUDES_START` / `#pragma push_macro("check")` wrapper header
   UE needs. I can't compile it here because I don't have the UE 5.3 engine,
   so you'd test that part.
9. **Commit and push** the toolchain file, a `build-grpc.sh` script that
   reproduces steps 2–6, and the docs to `claude/gifted-allen-nvdr7t`. The
   built binaries are about 100–200 MB, which is too large for plain git, so
   I'll ask you which of these to use:
   (a) commit with Git LFS,
   (b) attach as a GitHub release asset on this private repo, or
   (c) don't commit them, and you run `build-grpc.sh` yourself.

## What I can't do here

- **Download the UE toolchain.** `cdn.unrealengine.com` is blocked by this
  environment's network policy (403).
- **Get UE's libc++, OpenSSL, and zlib.** They're part of the UE 5.3 install,
  which is EULA-gated and needs your Epic-linked account and `Setup.sh`.
  A Windows UE 5.3 install works as the source too, as long as its Linux
  target-platform files are installed (see the guide, section 2c). The
  compiler itself has to be the Linux-hosted toolchain, though.
- **Test on a real RHEL 8 machine.** This container runs Ubuntu 24.04 with no
  Docker daemon. That's OK for building: the UE toolchain brings its own
  sysroot, so the host distro doesn't affect the output, and the glibc-2.17
  target runs on RHEL 8. A final run on your RHEL 8 box is still worthwhile.
- **Compile the Unreal-side module**, which needs the full engine.

## Risks / things that may need iteration

- **Exact ThirdParty paths/versions.** I'm working from known UE 5.3 layouts
  (e.g. `OpenSSL/1.1.1t`, `zlib/1.2.13`), but the build script locates them
  with `find`, so it doesn't rely on that guess being right.
- **Symbol clashes with UE plugins.** If you enable plugins that embed
  abseil or protobuf (e.g. some WebRTC/PixelStreaming builds), you may see
  duplicate symbols. The fallback is to build abseil/protobuf with a custom
  inline namespace.
- **UE macro collisions** (`check`, `verify`, `TEXT`, ...) in gRPC/protobuf
  headers. The wrapper header (step 8) handles the known ones.
- **RTTI.** If protobuf's generated code needs RTTI in your module, set
  `bUseRTTI = true` in that module only.
