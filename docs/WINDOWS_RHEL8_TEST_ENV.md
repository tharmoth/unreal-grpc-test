# A RHEL 8 environment on Windows (for fetching UE Linux files and testing)

## Recommendation

Use **WSL2 with AlmaLinux 8**. AlmaLinux 8 is a 1:1 binary-compatible rebuild
of RHEL 8, with the same glibc (2.28) and the same packages. It installs in
one command, shares files with Windows, and is fast enough to run UE's
`Setup.sh` and the gRPC build and tests.

| Option | Good for | Downsides |
|---|---|---|
| **WSL2 + AlmaLinux 8** (recommended) | Getting the UE Linux files, building gRPC, headless runtime tests | Not literally "RHEL". No practical GPU for the UE editor. |
| WSL2 + UBI 8 container (`podman`) | A final check on genuine RHEL 8 userspace | Only a userspace, not a full OS |
| Hyper-V VM with real RHEL 8.10 | An exact RHEL 8 match, if your org requires it | Needs Windows Pro and a free Red Hat Developer subscription. Slower to set up. No GPU for the UE editor. |
| Real RHEL 8 machine / dual-boot | The final in-editor or with-graphics test | Separate hardware or partitioning |

Red Hat's official "RHEL for WSL" images exist only for RHEL 9.6+ / 10, not
RHEL 8. That's why AlmaLinux 8 is the WSL choice here.

---

## 1. Install WSL2 + AlmaLinux 8

In an **admin** PowerShell:

```powershell
wsl --install                 # only if WSL isn't installed yet; reboot afterwards
wsl --list --online           # confirm the exact name, e.g. "AlmaLinux-8"
wsl --install AlmaLinux-8
```

Leave plenty of disk space. A shallow UE 5.3 clone plus its Linux
dependencies needs roughly 60–100 GB. The WSL disk lives on `C:` by default.
To put it elsewhere: `wsl --manage AlmaLinux-8 --move D:\WSL\Alma8`.

Inside the distro:

```bash
sudo dnf install -y git python3 tar xz which findutils
cat /etc/os-release | head -3      # AlmaLinux 8.x
```

Keep work inside the Linux filesystem (`~/…`), not `/mnt/c/…`. It's much
faster, and Linux permissions and symlinks behave correctly there.

---

## 2. Get UE 5.3's Linux files (LibCxx, OpenSSL, zlib) with `Setup.sh`

You need your GitHub account linked to Epic (same as on Windows) and a
GitHub personal access token to use as the git password.

```bash
cd ~
# Use the same 5.3.x tag as your Windows engine (check Engine/Build/Build.version):
git clone --depth 1 --branch 5.3.2-release https://github.com/EpicGames/UnrealEngine.git UE53
cd UE53
# Skip platforms you don't need to save space:
./Setup.sh --exclude=Win64 --exclude=Mac --exclude=Android --exclude=IOS
```

Check, then package only what the gRPC build needs:

```bash
find Engine/Source/ThirdParty -name 'libc++.a' -o -name 'libc++abi.a' -o -name 'LibCxx.Build.cs'
tar -czf ~/ue53-linux-deps.tar.gz \
    Engine/Source/ThirdParty/Unix/LibCxx \
    Engine/Source/ThirdParty/OpenSSL \
    Engine/Source/ThirdParty/zlib
ls -lh ~/ue53-linux-deps.tar.gz
```

From Windows, the file is at `\\wsl$\AlmaLinux-8\home\<you>\ue53-linux-deps.tar.gz`.

---

## 3. Test properly

1. **Build-level (recommended first).** Follow
   [BUILD_GRPC_UE53_RHEL8.md](BUILD_GRPC_UE53_RHEL8.md) steps 5–7 inside
   AlmaLinux 8, or copy in the build I produce. The verification checks and
   the greeter client/server smoke test then run on a RHEL 8-compatible
   runtime.
2. **Against your real backend.** Point a test client at your backend. WSL2
   can reach your LAN, and `localhost` on Windows forwards to WSL by default.
3. **Inside Unreal, headless.** Don't run the UE editor under WSL. GPU/Vulkan
   support there isn't practical for UE. Instead:
   - On Windows, install the UE 5.3 Linux cross-compile toolchain
     (`v22_clang-16.0.6-centos7`) and the Linux target platform.
   - Package a Linux build (or a Linux dedicated server target) of a small
     test project that makes a gRPC call.
   - Copy it into WSL and run it with `-nullrhi -log`, then check that the RPC succeeds.
4. **Genuine RHEL 8 userspace (optional).** Inside AlmaLinux:
   ```bash
   sudo dnf install -y podman
   podman run --rm -it -v ~/smoke:/smoke:Z registry.access.redhat.com/ubi8/ubi /smoke/greeter_client
   ```
5. **Final graphics test.** Run the packaged game on a real RHEL 8 machine.
