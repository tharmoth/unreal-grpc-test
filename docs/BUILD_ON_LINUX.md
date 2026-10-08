# Building gRPC for UE 5.3 on an offline Linux machine

[`scripts/build-grpc.sh`](../scripts/build-grpc.sh) builds gRPC with Unreal
Engine 5.3's own toolchain and libraries:

- clang 16.0.6 with UE's sysroot (glibc 2.17)
- UE's libc++
- UE's OpenSSL 1.1.1t and zlib 1.2.13
- C++20, Release mode, static, `-fPIC`

It needs no internet access, and nothing beyond `bash`, `cmake` (3.22 or
newer) and `make`. No Ninja, Python, git or curl.

## 1. What the offline machine needs

| Item | Notes |
|---|---|
| `cmake` ≥ 3.22 and `make` | On RHEL 8: `sudo dnf install cmake make`. RHEL 8.8+ ships CMake 3.26. |
| A UE 5.3 engine tree | `Setup.sh` must already have been run, so the folders below exist. |
| A gRPC checkout with submodules | See below. |
| `build-grpc.sh` (and optionally `test-grpc-build.sh` + `smoke_test/`) | Copy them from this repo's `scripts/` folder. |

The script uses these folders from the engine tree:

```
Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v22_clang-16.0.6-centos7/
Engine/Source/ThirdParty/Unix/LibCxx/
Engine/Source/ThirdParty/OpenSSL/1.1.1t/
Engine/Source/ThirdParty/zlib/1.2.13/
```

### Getting the gRPC source onto the machine

On any machine with internet access, clone gRPC and only the submodules
the build uses:

```bash
git clone --depth 1 --branch v1.84.0 https://github.com/grpc/grpc
git -C grpc submodule update --init --depth 1 -- \
    third_party/abseil-cpp third_party/cares/cares third_party/grpc-proto \
    third_party/protobuf third_party/re2
tar -czf grpc-v1.84.0.tar.gz --exclude=.git grpc   # about 30 MB; copy this over
```

A full `git clone --recurse-submodules` works too. It's just bigger.

Copy the folder as a tarball made on Linux, not file by file through
Windows. A Windows copy can break symlinks, executable bits and line endings.

## 2. Build

```bash
mkdir work && cd work
/path/to/build-grpc.sh /path/to/UnrealEngine /path/to/grpc
```

The output goes to `./grpc-ue53/`, or to a third argument if you give one.
The build tree goes to `./grpc-ue53-build/`, which you can delete afterwards.
A 4-core machine takes roughly half an hour.

| Output | What it is |
|---|---|
| `grpc-ue53/include/` | gRPC, protobuf and abseil headers |
| `grpc-ue53/lib/libgrpc_ue.a` | Everything merged into one static library. Link this from UE. |
| `grpc-ue53/bin/protoc`, `grpc-ue53/bin/grpc_cpp_plugin` | Code generators. Always use these for your `.proto` files. |

Compiler **warnings** during the build are normal; they're deprecation
notices inside gRPC/protobuf. The script stops at the first real error.

## 3. Optional: test the result

```bash
/path/to/test-grpc-build.sh /path/to/UnrealEngine ./grpc-ue53
```

The test generates code with the new `protoc`, builds a small program, and
makes one plaintext and one TLS call over localhost. It should end with:

```
    OK plaintext RPC -> "echo: plaintext"
    OK tls RPC -> "echo: tls"
    Smoke test PASSED
```

## 4. Use it in your UE 5.3 project

Copy `include/`, `lib/libgrpc_ue.a` and the two `bin/` tools into a
third-party module, e.g. `Source/ThirdParty/GrpcLibrary/`. Then follow
section 6 of [the manual](BUILD_GRPC_UE53_RHEL8.md#6-using-it-from-unreal-engine-53).

One thing is **required** in that module's `Build.cs`:

```csharp
PublicDefinitions.Add("PROTOBUF_NO_INLINE_CALL=1");
```

Without it, UE 5.3's clang 16 crashes (segfault) compiling any code that
includes protobuf headers. It's a clang bug; gRPC was built with the same define.

## Troubleshooting

| Problem | Fix |
|---|---|
| `Missing: .../v22_clang-16.0.6-centos7/...` | `Setup.sh` hasn't been run on that engine tree, or it isn't UE 5.3. |
| `Missing: .../third_party/<name>/CMakeLists.txt` | The gRPC copy lacks that submodule. Redo the clone step above. |
| `CMake 3.22 or higher is required` | Install a newer CMake. Its official Linux tarball from cmake.org also works offline. |
| `clang frontend command failed with exit code 139` | You're compiling protobuf headers without `-DPROTOBUF_NO_INLINE_CALL`. |
| Compiler `Killed` | Out of memory. Edit the `-j "$(nproc)"` in the script to a smaller number. |
