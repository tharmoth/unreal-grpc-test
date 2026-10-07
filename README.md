# unreal-grpc-test

gRPC for an Unreal Engine 5.3 C++ frontend on RHEL 8, built with UE's own
Linux toolchain (clang 16.0.6, UE libc++, C++20) and linked against UE's
OpenSSL 1.1.1t and zlib 1.2.13.

**To build:** `./scripts/build-grpc.sh`. See [docs/BUILD_ON_LINUX.md](docs/BUILD_ON_LINUX.md).

| Path | Contents |
|---|---|
| [docs/BUILD_ON_LINUX.md](docs/BUILD_ON_LINUX.md) | Quick start: build on your RHEL 8 machine with the script |
| [docs/BUILD_GRPC_UE53_RHEL8.md](docs/BUILD_GRPC_UE53_RHEL8.md) | What the script does, step by step, plus how to use the result in UE |
| [docs/PLAN.md](docs/PLAN.md) | The original plan and design decisions |
| [docs/WINDOWS_RHEL8_TEST_ENV.md](docs/WINDOWS_RHEL8_TEST_ENV.md) | A RHEL 8-compatible environment on Windows (WSL2 + AlmaLinux 8) |
| `scripts/build-grpc.sh` | The build script |
| `scripts/smoke_test/` | Client/server test program the script builds and runs |
| `cmake/ue53-linux-x86_64.cmake` | CMake toolchain file for UE 5.3's compiler and libc++ |
| `LibCxx/`, `OpenSSL/`, `zlib/` | Linux x86_64 files copied from UE 5.3's `Engine/Source/ThirdParty` (Epic EULA, keep this repo private) |
