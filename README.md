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

## Allocator compatibility

The fork keeps glibc's allocation entry points and symbol versions, including the alignment APIs and sized deallocation. ptmalloc-specific tunables no longer apply. `mallinfo` and `mallinfo2` return zeroed counters, `mallopt` rejects ptmalloc options, and `malloc_info` reports `ENOSYS` for valid options. `malloc_stats` prints mimalloc statistics; `malloc_trim` requests collection but cannot report whether memory was released. The ptmalloc debugging DSO (`libc_malloc_debug.so`) is not built, and ptmalloc-specific tests are not applicable to this fork.

## Verification

The fork was built on x86-64 Linux with Clang and LLD 22.1.8. Dynamic and static smoke tests exercised allocation, alignment, cross-thread frees, and allocation in a `fork` child handler. The shared libc's exported symbol names and versions were also compared with unpatched glibc 2.44 on the same host. These checks do not replace the full glibc test suite.

To check the compiler and linker recorded in the resulting shared library, run `llvm-readelf -p .comment glibc/build/libc.so`.
