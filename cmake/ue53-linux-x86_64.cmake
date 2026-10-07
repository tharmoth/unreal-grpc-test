# CMake toolchain file: Unreal Engine 5.3 Linux x86_64.
#
# Compiles with UE's bundled clang 16.0.6 (v22_clang-16.0.6-centos7) against
# its CentOS 7 sysroot (glibc 2.17), and uses UE's libc++ instead of the
# sysroot's libstdc++, the same way UnrealBuildTool's LinuxToolChain does.
#
# Required environment variables (read from the environment so they also
# reach CMake's try_compile() sub-projects):
#   UE_TOOLCHAIN_ROOT  .../v22_clang-16.0.6-centos7/x86_64-unknown-linux-gnu
#   UE_LIBCXX_ROOT     .../ThirdParty/Unix/LibCxx  (has include/c++/v1 and lib/Unix/...)

# Host and target are both Linux x86_64, so CMAKE_SYSTEM_NAME is deliberately
# NOT set: that would mark the build as cross-compiling, and gRPC would then
# look for a pre-installed host grpc_cpp_plugin instead of using the one it
# builds. The sysroot below still isolates the build from the host's libraries.

if(NOT DEFINED ENV{UE_TOOLCHAIN_ROOT} OR NOT DEFINED ENV{UE_LIBCXX_ROOT})
  message(FATAL_ERROR "Set UE_TOOLCHAIN_ROOT and UE_LIBCXX_ROOT before using this toolchain file.")
endif()

set(_ue_tc "$ENV{UE_TOOLCHAIN_ROOT}")
set(_ue_libcxx "$ENV{UE_LIBCXX_ROOT}")
set(_ue_libcxx_lib "${_ue_libcxx}/lib/Unix/x86_64-unknown-linux-gnu")

set(CMAKE_SYSROOT "${_ue_tc}")
set(CMAKE_C_COMPILER "${_ue_tc}/bin/clang")
set(CMAKE_CXX_COMPILER "${_ue_tc}/bin/clang++")
set(CMAKE_C_COMPILER_TARGET x86_64-unknown-linux-gnu)
set(CMAKE_CXX_COMPILER_TARGET x86_64-unknown-linux-gnu)
# The toolchain ships llvm-ar/llvm-objcopy plus GNU binutils 2.31 under the
# x86_64-unknown-linux-gnu- prefix (there is no llvm-ranlib/llvm-nm).
set(_ue_binutils "${_ue_tc}/bin/x86_64-unknown-linux-gnu-")
set(CMAKE_AR "${_ue_tc}/bin/llvm-ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "${_ue_binutils}ranlib" CACHE FILEPATH "")
set(CMAKE_NM "${_ue_binutils}nm" CACHE FILEPATH "")
set(CMAKE_OBJCOPY "${_ue_tc}/bin/llvm-objcopy" CACHE FILEPATH "")
set(CMAKE_OBJDUMP "${_ue_binutils}objdump" CACHE FILEPATH "")
set(CMAKE_READELF "${_ue_binutils}readelf" CACHE FILEPATH "")
set(CMAKE_STRIP "${_ue_binutils}strip" CACHE FILEPATH "")

# UE game/editor modules are shared objects, so everything must be PIC.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_FLAGS_INIT "-fPIC")
# Use UE's libc++ headers instead of the sysroot's libstdc++.
# PROTOBUF_NO_INLINE_CALL: UE 5.3's clang 16.0.6 segfaults on protobuf's
# statement-level [[clang::always_inline]] (parse_context.h). Disabling that
# inlining hint is protobuf's supported workaround and does not change the ABI.
# Every UE module that includes protobuf/gRPC headers needs the same define.
set(CMAKE_CXX_FLAGS_INIT "-fPIC -nostdinc++ -isystem ${_ue_libcxx}/include/c++/v1 -DPROTOBUF_NO_INLINE_CALL")

# Link with lld and UE's static libc++/libc++abi.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_CXX_STANDARD_LIBRARIES
    "-nodefaultlibs ${_ue_libcxx_lib}/libc++.a ${_ue_libcxx_lib}/libc++abi.a -lm -lc -lpthread -ldl -lrt -lgcc_s -lgcc")

# Programs (python, perl, ...) come from the host; libraries/headers may live
# in the sysroot or outside it (UE's OpenSSL and zlib).
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
