# Gentoo binary repository

The binhost publishes signed GPKG packages as `sys-libs/glibc` in slot `2.2`. Both builds target `=sys-libs/glibc-2.44-r4` with `CHOST=x86_64-pc-linux-gnu` and an x86-64 baseline. The Dart binhost builder invokes Gentoo's ebuild and install phases with Clang, LLD, and compiler-rt. It reuses `build.dart` for the mimalloc object in each ABI and enables permissive CET for amd64.

Before publication, each build installs its generated binpkg in a disposable Gentoo container and runs the libc and allocator probes for each ABI it ships. It also checks the amd64 ELF CET properties. The signing step runs without networking in a fresh container and regenerates the Portage index. Each release includes the corresponding sources and a `SHA256SUMS` file for the signed package and source archive. When updating the release, update the ebuild patch and CPV in the workflow together.

## Set up publication before pushing

1. Open the repository's **Settings → Pages** and set **Build and deployment → Source** to **GitHub Actions**. Allow `main` to deploy to the `github-pages` environment if that environment is restricted.
2. Create a dedicated OpenPGP signing key for this binhost. Use a key that can sign without an interactive passphrase in the disposable runner. Keep a secure copy of the key and record the public fingerprint through a separate trusted channel. For example:

   ```sh
   gpg --batch --pinentry-mode loopback --passphrase '' \
     --quick-generate-key 'ekuOS Gentoo binhost' ed25519 sign 1y
   gpg --list-secret-keys --fingerprint 'ekuOS Gentoo binhost'
   ```

3. In **Settings → Secrets and variables → Actions**, create the repository secret `BINHOST_GPG_PRIVATE_KEY` with the ASCII-armored export of that one signing key. With an authenticated GitHub CLI, set it directly from GnuPG after setting `fingerprint` to the full fingerprint shown above:

   ```sh
   gpg --armor --export-secret-keys "$fingerprint" |
     gh secret set BINHOST_GPG_PRIVATE_KEY --repo ekuOS/glibc
   ```

The workflow uses GitHub's built-in Pages deployment token. A push to `main` or a manual dispatch on `main` builds and deploys the repository.

## Configure Portage to prefer the binhost

Use the deployment's Pages URL with the path for your profile. The default project URL is `https://ekuos.github.io/glibc/`.

| Gentoo profile | ABIs | Binhost path |
| --- | --- | --- |
| `default/linux/amd64/23.0` (OpenRC) | amd64, x86 | `amd64/23.0/openrc/` |
| `default/linux/amd64/23.0/no-multilib/systemd` | amd64 | `amd64/23.0/no-multilib/systemd/` |

Add this section under `/etc/portage/binrepos.conf`, either in the existing file or in a file inside that directory:

```ini
[ekuos-glibc]
priority = 9999
sync-uri = https://ekuos.github.io/glibc/amd64/23.0/openrc/
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

Set the package's USE flags to match the published `Packages` index. Both builds explicitly enable `cet clang multiarch ssp static-libs`. OpenRC adds `multilib -systemd` and no-multilib systemd adds `-multilib systemd`. The binpkg uses the `gentoo` repository identity, so a local mask on `sys-libs/glibc::gentoo` also masks these packages. Preview the binary-only reinstall and confirm that Portage selects `ekuos-glibc` before applying it:

```sh
sudo emerge --pretend --verbose --getbinpkg --usepkgonly --binpkg-respect-use=y \
  --reinstall-atoms=sys-libs/glibc =sys-libs/glibc-2.44-r4
```

Then use `--ask --oneshot` in place of `--pretend --verbose` for installation. A higher binhost priority prefers ekuOS when both binhosts provide the same compatible CPV. A newer official CPV may still win during normal updates. To return to the official build, disable the ekuOS binrepo and reinstall the official package. Validate the replacement on a disposable Gentoo system before installing it on a production host.
