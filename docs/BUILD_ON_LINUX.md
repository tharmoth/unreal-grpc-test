# Building gRPC for UE 5.3 on your RHEL 8 machine

This is the quick path: one script builds gRPC with Unreal Engine 5.3's own
Linux toolchain and libraries, checks the result, and runs a client/server
test. For a step-by-step explanation of what the script does (or to do it by
hand), see [BUILD_GRPC_UE53_RHEL8.md](BUILD_GRPC_UE53_RHEL8.md).

**What you get** (in `_install/grpc-v1.84.0-ue53-linux-x86_64/`):

| Path | What it is |
|---|---|
| `include/` | gRPC, protobuf and abseil headers |
| `lib/libgrpc_ue.a` | Everything merged into one static library. Link this from UE. |
| `lib/*.a` | The individual static libraries, if you'd rather link those |
| `bin/protoc`, `bin/grpc_cpp_plugin` | Code generators for your `.proto` files |

It's built with:

- UE 5.3's clang 16.0.6
- UE's libc++ 15
- C++20
- Release mode, position-independent (`-fPIC`)

It links against UE's own OpenSSL 1.1.1t and zlib 1.2.13; neither is bundled into it.

---

## 1. Prerequisites (one-time)

You don't need a system C/C++ compiler. The script downloads UE's.

```bash
sudo dnf install -y git curl tar gzip
sudo dnf install -y cmake            # RHEL 8.8+ ships CMake 3.26; gRPC needs >= 3.22
cmake --version
```

**Ninja.** It's in CodeReady Builder or EPEL. Pick one:

```bash
# Option A: CodeReady Builder (registered RHEL)
sudo subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms
sudo dnf install -y ninja-build

# Option B: EPEL
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf install -y ninja-build
```

**If CMake is older than 3.22, or you can't add repos**, install both tools
for your user only with pip. RHEL 8's default `python3` is 3.6, which is too
old for current wheels, so use 3.11:

```bash
sudo dnf install -y python3.11 python3.11-pip
python3.11 -m pip install --user ninja "cmake>=3.22,<4"
export PATH="$HOME/.local/bin:$PATH"     # add to ~/.bashrc
```

**Network:** the machine needs HTTPS access to `github.com` (gRPC sources)
and `cdn.unrealengine.com` (the UE toolchain, about 1.2 GB). If it's offline, see
[Offline / air-gapped machines](#offline--air-gapped-machines).

**Disk:** about __DISK__ GB free under the repository folder.

---

## 2. Get this repository

The repository is private, so clone with your GitHub credentials (a personal
access token as the password, `gh auth login`, or an SSH key):

```bash
git clone --branch claude/gifted-allen-nvdr7t https://github.com/tharmoth/unreal-grpc-test.git
cd unreal-grpc-test
```

The repository already contains the UE 5.3 files the build needs, copied
from `Engine/Source/ThirdParty`:

- `LibCxx/`: libc++ headers and static libraries
- `OpenSSL/1.1.1t/`
- `zlib/1.2.13/`

---

## 3. Build

```bash
./scripts/build-grpc.sh 2>&1 | tee build.log
```

That's it. The script:

1. Checks the tools and the UE files above.
2. Downloads the UE 5.3 toolchain (`v22_clang-16.0.6-centos7`) and checks
   its SHA-256 checksum. This step is skipped if you point it at an existing
   one; see the options below.
3. Clones gRPC `v1.84.0` with only the submodules it needs (abseil,
   protobuf, re2, c-ares).
4. Configures, builds and installs it with
   [`cmake/ue53-linux-x86_64.cmake`](../cmake/ue53-linux-x86_64.cmake).
5. Merges all the static libraries into `libgrpc_ue.a`.
6. Verifies the result. It stops with `ERROR:` if any check fails:
   - It uses libc++ (`std::__1`) and has no libstdc++ (`std::__cxx11`) symbols.
   - No OpenSSL/BoringSSL or zlib code is bundled; those come from UE.
   - `protoc` and `grpc_cpp_plugin` need nothing newer than glibc 2.17 and
     were compiled by UE's clang 16.0.6.
   - `libgrpc_ue.a` is position-independent, so it's safe for editor `.so` modules.
7. Builds a small test program with your new `protoc`. It starts a server
   and makes one plaintext and one TLS call over localhost. TLS goes through
   UE's OpenSSL.

On a 4-core machine the build takes about __TIME__. A successful run ends with:

```
==> Smoke test: codegen + client/server RPC over localhost
__SMOKE__
==> Done
```

Run it again any time. Downloads and the gRPC checkout are reused, and the
build is incremental. Use `CLEAN=1` to rebuild from scratch.

### Options

Set these as environment variables, e.g. `JOBS=8 ./scripts/build-grpc.sh`.

| Variable | Default | Purpose |
|---|---|---|
| `GRPC_VERSION` | `v1.84.0` | gRPC tag to build |
| `CXX_STANDARD` | `20` | Must match your UE project (UE 5.3 defaults to C++20) |
| `LINUX_MULTIARCH_ROOT` | *(download)* | Use an existing toolchain instead of downloading, e.g. `<UE>/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v22_clang-16.0.6-centos7` |
| `UE_THIRDPARTY_DIR` | this repo | Folder containing `OpenSSL/` and `zlib/`, e.g. `<UE>/Engine/Source/ThirdParty` |
| `UE_LIBCXX_ROOT` | `$UE_THIRDPARTY_DIR/LibCxx` | e.g. `<UE>/Engine/Source/ThirdParty/Unix/LibCxx` |
| `PREFIX` | `_install/grpc-<ver>-ue53-linux-x86_64` | Install location |
| `WORK_DIR` | `_work` | Downloads, sources, build tree (safe to delete afterwards) |
| `JOBS` | `nproc` | Parallel compile jobs. Lower it if the machine runs out of RAM. |
| `RUN_SMOKE_TEST` | `1` | `0` skips the test program |
| `CLEAN` | `0` | `1` deletes the build tree first |

`_work/` and `_install/` are git-ignored.

### Offline / air-gapped machines

On a machine with internet access, fetch everything into `_work/` with
the build step stopped early. The simplest way is to run the whole script
there. Then copy the full repository folder, including `_work/`, to the
offline machine and run the script again. It reuses:

- `_work/downloads/native-linux-v22_clang-16.0.6-centos7.tar.gz`
  (checksum-verified)
- `_work/grpc-v1.84.0/` (the gRPC checkout with submodules)

---

## 4. Use it in your UE 5.3 project

Copy the output into a third-party module in your project:

```bash
OUT=_install/grpc-v1.84.0-ue53-linux-x86_64
DEST=/path/to/YourProject/Source/ThirdParty/GrpcLibrary
mkdir -p "$DEST/lib/Linux" "$DEST/bin/Linux"
cp -r "$OUT/include" "$DEST/"
cp "$OUT/lib/libgrpc_ue.a" "$DEST/lib/Linux/"
cp "$OUT/bin/protoc" "$OUT/bin/grpc_cpp_plugin" "$DEST/bin/Linux/"
```

Then follow section 8 of [the manual](BUILD_GRPC_UE53_RHEL8.md#8-using-it-from-unreal-engine-53)
for the `Build.cs`, the include wrapper for UE's `check`/`verify` macros,
and generating code from your `.proto` files. Always use **this** `protoc`
and `grpc_cpp_plugin`; generated code must match the protobuf runtime
version exactly.

---

## Troubleshooting

| Message | Fix |
|---|---|
| `'ninja' (or 'ninja-build') not found` / `CMake ... is too old` | See [Prerequisites](#1-prerequisites-one-time). |
| `Missing .../LibCxx/...` or `... is a Git LFS pointer` | The repository checkout is incomplete. Run `git status` / `git lfs pull`, or point `UE_THIRDPARTY_DIR` / `UE_LIBCXX_ROOT` at a UE 5.3 engine tree. |
| `Toolchain checksum mismatch` | The download was corrupted or truncated. Delete `_work/downloads/*.tar.gz` and run again. |
| `Expected clang 16.0.6` | `LINUX_MULTIARCH_ROOT` points at a different toolchain. UE 5.3 needs `v22_clang-16.0.6-centos7`. |
| `curl: (6)`/`(7)`/`(35)` while downloading | No route to `cdn.unrealengine.com`. Check the proxy (`https_proxy`), or use the offline steps. |
| Compiler killed / `c++: fatal error: Killed signal` | Out of memory. Re-run with `JOBS=2`. |
| Smoke test fails with `UNAVAILABLE` | Something is blocking localhost connections (unusual). Check `firewalld`/SELinux policy for loopback. The libraries themselves are fine. Re-run with `RUN_SMOKE_TEST=0` to finish. |
