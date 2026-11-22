# Gentoo binary repository

The binhost publishes signed GPKG packages as `sys-libs/glibc` in slot `2.2`. It targets `=sys-libs/glibc-2.44-r4` on amd64 with both x86-64 and i386. Each profile is built and tested separately. The Dart binhost builder invokes Gentoo's ebuild and install phases with Clang, LLD, and compiler-rt. It reuses `build.dart` for patching glibc, compiling mimalloc, and selecting the hardening flags, including permissive CET on x86-64.

Before publication, each build installs its generated binpkg in a disposable Gentoo container and runs the shared and static libc and allocator probes for each ABI it ships. It also checks ELF hardening for the amd64 libc and loader and confirms the loader was built with Clang and LLD. The signing step runs without networking in a fresh container and regenerates the Portage index. Each release includes the corresponding sources and a `SHA256SUMS` file for the signed package and source archive. When updating the release, update the ebuild patch and CPV in `binhost.dart` together. Update the dated Gentoo stage and Portage image tags together and run a build-only dispatch before publishing.

## Set up publication before pushing

1. Open the repository's **Settings → Pages** and set **Build and deployment → Source** to **GitHub Actions**. Allow `main` to deploy to the `github-pages` environment if that environment is restricted.
2. Create a dedicated OpenPGP signing key for this binhost. Keep a secure copy of the key and record the public fingerprint through a separate trusted channel. GnuPG will prompt for a passphrase:

   ```sh
   gpg --quick-generate-key 'ekuOS Gentoo binhost' ed25519 sign 1y
   gpg --list-secret-keys --fingerprint 'ekuOS Gentoo binhost'
   ```

3. In **Settings → Secrets and variables → Actions**, create the repository secret `BINHOST_GPG_PRIVATE_KEY` with the ASCII-armored export of that one signing key. With an authenticated GitHub CLI, set it directly from GnuPG after setting `fingerprint` to the full fingerprint shown above:

   ```sh
   gpg --armor --export-secret-keys "$fingerprint" |
     gh secret set BINHOST_GPG_PRIVATE_KEY --repo ekuOS/glibc
   ```

4. If the key has a passphrase, register it as a separate Actions secret named `BINHOST_GPG_PASSPHRASE` (one line, with no trailing newline). With GitHub CLI, run `gh secret set BINHOST_GPG_PASSPHRASE --repo ekuOS/glibc` and enter it at the prompt. Leave this secret unset for a key without a passphrase. The runner uses GnuPG loopback pinentry in the offline signing container.

The workflow uses GitHub's built-in Pages deployment token. A push to `main` builds and deploys the repository. A manual dispatch builds and tests without signing or deploying by default, including on a development branch. Select `publish` on `main` to deploy.

## Configure Portage to prefer the binhost

Choose the path matching your Gentoo profile:

| Gentoo profile | Pages path |
| --- | --- |
| `default/linux/amd64/23.0/llvm/systemd` | `amd64/23.0/llvm/systemd/` |
| `default/linux/amd64/23.0/systemd` (standard multilib) | `amd64/23.0/multilib/systemd/` |

The i386 build links compiler-rt first and uses the static i386 `libgcc.a`
for binary128 builtins missing from LLVM 22. This does not change the
compiler or add a shared `libgcc` dependency.

Add this section under `/etc/portage/binrepos.conf`, either in the existing file or in a file inside that directory:

```ini
[ekuos-glibc]
priority = 9999
sync-uri = https://ekuos.github.io/glibc/amd64/23.0/llvm/systemd/
verify-signature = true
```

Download `signing-key.asc` from that URL and use `gpg --show-keys --fingerprint signing-key.asc` to compare the fingerprint with the value obtained from the maintainer. After verifying the fingerprint, initialize Portage's keyring and import the key:

```sh
sudo getuto
sudo gpg --homedir /etc/portage/gnupg --import signing-key.asc
printf '%s:6:\n' "$fingerprint" |
  sudo gpg --homedir /etc/portage/gnupg --import-ownertrust
sudo gpg --homedir /etc/portage/gnupg --batch --check-trustdb
```

On the target system, allow the exact version in `package.accept_keywords` when it is still testing:

```text
=sys-libs/glibc-2.44-r4 ~amd64
```

Allow glibc's experimental `clang` USE flag with `=sys-libs/glibc-2.44-r4 -clang` in `/etc/portage/profile/package.use.mask`. Then set the package's USE flags to match the published `Packages` index: `cet clang multiarch multilib ssp stack-realign static-libs systemd`. The binpkg uses the `gentoo` repository identity, so a local mask on `sys-libs/glibc::gentoo` also masks these packages. Preview the binary-only reinstall and confirm that Portage selects `ekuos-glibc` before applying it:

```sh
sudo emerge --pretend --verbose --getbinpkg --usepkgonly --binpkg-respect-use=y \
  --reinstall-atoms=sys-libs/glibc =sys-libs/glibc-2.44-r4
```

Then use `--ask --oneshot` in place of `--pretend --verbose` for installation. A higher binhost priority prefers ekuOS when both binhosts provide the same compatible CPV. A newer official CPV may still win during normal updates. To return to the official build, disable the ekuOS binrepo and reinstall the official package. Validate the replacement on a disposable Gentoo system before installing it on a production host.
