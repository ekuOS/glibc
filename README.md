# ekuOS glibc builder

This Dart script builds the ekuOS glibc fork with **mimalloc (`MI_SECURE=4`)** as its default allocator. It fetches upstream sources, applies the bundled integration patch, and builds with Clang and LLVM. Both the shared and static libc include mimalloc directly, so no preload or separate mimalloc library is required.

## Usage

Run from the repository root:

```sh
dart run build.dart --jobs 8
```

| Directory | Contents |
| --- | --- |
| `./glibc/src` | Sourceware glibc `glibc-2.44` checkout with the integration patch and shim applied |
| `./glibc/build` | Out-of-tree glibc build, including `libc.so` and `libc.a` |
| `./mimmaloc/src` | Microsoft mimalloc `v3.7.0` checkout |
| `./mimmaloc/build` | Clang-compiled mimalloc object embedded in libc |

Both parent directories are ignored by Git. Upstream source trees are fetched on demand and are not vendored. The script applies `patches/001-use-mimalloc.patch` by default and copies the integration shim from `shim/eku-malloc.c` into the glibc source tree. It does not install the resulting library.

```sh
dart run build.dart --source /path/to/glibc --patches /path/to/extra-patches --output glibc/custom-build
dart run build.dart --headers /path/to/exported-kernel-headers/include
dart run build.dart --help
```

- Existing checkouts are reused without fetching or switching revisions. For an existing glibc checkout, `--tag` requires `HEAD` to match that tag. Omit `--tag` for an unpacked glibc 2.44 tarball.
- `--patches` adds `.patch` and `.diff` files after the bundled patch. Each directory is processed in filename order using `patch -p1`. The builder skips patches that apply only in reverse. If patches overlap and a rerun cannot recognize an applied patch, use a fresh source tree.
- Use a fresh output directory when switching source trees or toolchain versions. Relative paths are resolved from the current working directory. Source, output, and header paths must not contain spaces or shell metacharacters.

## Requirements

- Linux and Dart SDK 3 or later; no pub packages needed.
- Clang, Clang++, LLD, compiler-rt builtins, and the LLVM utilities `llvm-ar`, `llvm-nm`, `llvm-objcopy`, `llvm-objdump`, `llvm-ranlib`, `llvm-readelf`, and `llvm-strip`.
- GNU make, GNU patch, GNU awk, GNU sed, Bison, Python 3, Linux UAPI headers, and the host's C and C++ development files. Git is required for cloning and tag verification.

The integration patch targets glibc 2.44 on Linux. Other revisions or architectures may need additional changes. For `--headers`, use the `include` directory created by the kernel's `make headers_install`, not the kernel source tree.

## Build hardening

The builder enables strong stack protection, stack-clash protection, and `_FORTIFY_SOURCE=3` for glibc and the embedded mimalloc object. glibc's `--enable-bind-now` adds eager binding to its existing RELRO. To upgrade a build made before these flags were added, choose a fresh `--output` directory.

For x86-64 targets the builder enables IBT and shadow stack with `--enable-cet=permissive` and compiles mimalloc with matching CET properties. Startup dependencies without CET properties can leave the corresponding protection disabled. If a single-threaded process already using CET calls `dlopen` on a legacy library, glibc can disable the affected feature for that process and proceed. If the process is multithreaded and the affected feature is active, glibc can reject the load. [glibc CET configuration](https://sourceware.org/glibc/manual/latest/html_node/Configuring-and-compiling.html)

glibc 2.44 defaults to leaving CET inactive at runtime. To opt in to shadow stack for a compatible application on a supported Linux system, launch it with `GLIBC_TUNABLES=glibc.cpu.hwcaps=SHSTK`. [glibc runtime defaults](https://sourceware.org/pipermail/libc-stable/2025-August/002325.html)

Inspect the x86-64 outputs with `llvm-readelf -n glibc/build/libc.so glibc/build/elf/ld.so` for `IBT` and `SHSTK`. In `llvm-readelf -l -d glibc/build/libc.so`, look for `GNU_RELRO`, `NOW`, and a `GNU_STACK` segment without execute permission.

## Allocator compatibility

The fork keeps glibc's allocation entry points and symbol versions, including the alignment APIs and sized deallocation. ptmalloc-specific tunables no longer apply. `mallinfo` and `mallinfo2` return zeroed counters, `mallopt` rejects ptmalloc options, and `malloc_info` reports `ENOSYS` for valid options. `malloc_stats` prints mimalloc statistics; `malloc_trim` requests collection but cannot report whether memory was released. The ptmalloc debugging DSO (`libc_malloc_debug.so`) is not built, and ptmalloc-specific tests are not applicable to this fork.

## Verification

Run `dart run test.dart` after building, or pass `--output PATH` to select a different build directory. The runtime smoke tests exercise stdio, the C locale, and numeric address resolution in shared and static executables. The shared test verifies that the executable loaded the selected build's `libc.so`. The runner also checks ELF hardening, the allocator ABI, and SHSTK compatibility with legacy libraries at startup and during `dlopen`. Clang++ compiles the C++20 fixtures using the build's startup objects and libc. Static tests also require `libgcc_eh.a`, and the runtime tests use GNU `timeout`. SHSTK runtime checks are skipped on unsupported platforms.

The fork was built on x86-64 Linux with Clang and LLD 22.1.8. Dynamic and static smoke tests exercised allocation, alignment, cross-thread frees, and allocation in a `fork` child handler. The shared libc's exported symbol names and versions were also compared with unpatched glibc 2.44 on the same host. These checks do not replace the full glibc test suite.

To check the compiler and linker recorded in the resulting shared library, run `llvm-readelf -p .comment glibc/build/libc.so`.
