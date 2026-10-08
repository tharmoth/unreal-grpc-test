# unreal-grpc-test

Builds gRPC for an Unreal Engine 5.3 C++ project on Linux (RHEL 8), using
UE's own toolchain (clang 16.0.6, UE libc++, C++20) and UE's OpenSSL and
zlib. Works offline. It needs only `bash`, `cmake` ≥ 3.22 and `make`, plus
local copies of the UE 5.3 engine and the gRPC source.

```bash
scripts/build-grpc.sh /path/to/UnrealEngine /path/to/grpc     # -> ./grpc-ue53/
scripts/test-grpc-build.sh /path/to/UnrealEngine ./grpc-ue53  # optional check
```

**Prebuilt:** [`dist/grpc-v1.84.0-ue53-linux-x86_64.tar.gz`](dist/) (24.5 MB)
is the output of that script, so you can skip building:
`tar -xzf dist/grpc-v1.84.0-ue53-linux-x86_64.tar.gz`. It has the same
layout as `./grpc-ue53/`, and its `README.txt` lists exactly how it was
built and checksums.

| Path | Contents |
|---|---|
| [docs/BUILD_ON_LINUX.md](docs/BUILD_ON_LINUX.md) | How to run the build, including on a machine without internet |
| [docs/BUILD_GRPC_UE53_RHEL8.md](docs/BUILD_GRPC_UE53_RHEL8.md) | What the script does and why, plus how to use the result in UE |
| `dist/` | Prebuilt package (gRPC v1.84.0, UE 5.3, Linux x86_64) |
| `scripts/build-grpc.sh` | The build (one self-contained file) |
| `scripts/test-grpc-build.sh`, `scripts/smoke_test/` | Optional client/server test of a finished build |
| [docs/PLAN.md](docs/PLAN.md), [docs/WINDOWS_RHEL8_TEST_ENV.md](docs/WINDOWS_RHEL8_TEST_ENV.md) | Background: the original plan; a RHEL 8-like WSL setup |
| `LibCxx/`, `OpenSSL/`, `zlib/` | Copies of UE 5.3's Linux files. Not used by the scripts, which read them from the engine tree (Epic EULA; keep this repo private). |
