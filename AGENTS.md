# ekuOS glibc development policy

- Write repository scripts in Dart. Keep short CI commands directly in the GitHub Actions workflow. Use the Gentoo ebuild for Portage phases and call Dart for project-owned build logic.
- Build glibc and its embedded mimalloc with Clang, LLD, and compiler-rt in both the standalone build and the Gentoo binpkg. Share allocator compilation and hardening settings with `build.dart`.
- Use permissive CET on supported x86-64 targets and preserve compatibility with libraries that lack CET properties. Check ELF hardening on x86-64 even when the runner lacks CET. Skip SHSTK runtime tests when the CPU or kernel lacks userspace SHSTK.
- Run `dart run test.dart` against the built libc in CI. Keep the allocator ABI and shared and static runtime tests. Use the fork's test suite for CI.

## Gentoo binhost

- Build and test the Portage package in GitHub Actions and publish the signed GPKG files and `Packages` indexes on GitHub Pages. Preserve the official `sys-libs/glibc` package identity and slot. Users opt in through a higher-priority `binrepos.conf` entry for matching package versions and USE flags.
- Keep separate binrepo paths for distinct Gentoo profiles and ABIs. Validate each package by installing it in a disposable Gentoo environment before signing and publishing.
- Reference actions, images, and upstream sources by their release tags. Recalculate local distfile and publication hashes for each run, and retain Gentoo's Manifest verification for official distfiles.
- Before pushing a change that enables publication, tell the maintainer to set the Pages source to **GitHub Actions**, allow `main` to deploy if protection rules apply, and register the dedicated OpenPGP private key as the `BINHOST_GPG_PRIVATE_KEY` Actions secret.
