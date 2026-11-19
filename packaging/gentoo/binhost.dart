import 'dart:convert';
import 'dart:io';

import '../../build.dart' as glibc;

const project = '/input';
const repo = '/var/db/repos/gentoo';
const version = '2.44-r4';
const package = 'sys-libs/glibc';
const atom = '=$package-$version';
const ebuildName = 'glibc-$version.ebuild';
const sourceVersion = '2.44';
const llvmPackages = [
  'llvm-core/clang',
  'llvm-core/lld',
  'llvm-core/llvm',
  'llvm-runtimes/compiler-rt',
];

String requiredEnv(String key) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) {
    throw glibc.BuildFailure('Missing $key');
  }
  return value;
}

Future<String> capture(
  String executable,
  List<String> arguments, {
  String? cwd,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw glibc.BuildFailure(
      '$executable ${arguments.join(' ')} failed (exit ${result.exitCode})\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return (result.stdout as String).trimRight();
}

Future<String> digest(String algorithm, String file) async =>
    (await capture(algorithm, ['--', file])).split(' ').first;

Future<String> manifestEntry(String kind, String name, File file) async {
  final size = await file.length();
  final blake = await digest('b2sum', file.path);
  final sha = await digest('sha512sum', file.path);
  return '$kind $name $size BLAKE2B $blake SHA512 $sha';
}

Future<void> patchEbuild(String pkgdir, File mimalloc) async {
  final patch = await glibc.buildPath('$project/packaging/gentoo');
  await glibc.run('patch', [
    '--batch',
    '--forward',
    '--fuzz=0',
    '-p1',
    '-i',
    '$patch/glibc-ebuild.patch',
  ], cwd: pkgdir);

  final aux = Directory('$pkgdir/files/ekuos');
  await aux.create();
  final bundled = await Directory('$project/patches')
      .list()
      .where(
        (entry) =>
            entry is File &&
            (entry.path.endsWith('.patch') || entry.path.endsWith('.diff')),
      )
      .cast<File>()
      .toList();
  for (final file in [...bundled, File('$project/shim/eku-malloc.c')]) {
    await file.copy('${aux.path}/${file.uri.pathSegments.last}');
  }

  final manifest = File('$pkgdir/Manifest');
  final lines = await manifest.readAsLines();
  final added = [
    await manifestEntry('EBUILD', ebuildName, File('$pkgdir/$ebuildName')),
    await manifestEntry('DIST', mimalloc.uri.pathSegments.last, mimalloc),
    await for (final file in aux.list().cast<File>())
      await manifestEntry('AUX', 'ekuos/${file.uri.pathSegments.last}', file),
  ];
  // Retain the official Manifest hashes for all unmodified files.
  await manifest.writeAsString(
    [
      ...lines.where((line) => !line.startsWith('EBUILD $ebuildName ')),
      ...added,
      '',
    ].join('\n'),
  );
}

Future<void> writePortageSetting(String path, String content) async {
  final file = File('/etc/portage/$path');
  await file.parent.create(recursive: true);
  await file.writeAsString('$content\n');
}

Future<void> checkInstalledPackage(
  Directory scratch,
  List<String> abis,
  Map<String, String> environment,
) async {
  for (final abi in abis) {
    final libdir = abi == '64' ? 'lib64' : 'lib';
    final libc = await File('/usr/$libdir/libc.so.6').resolveSymbolicLinks();
    final unwind = await capture('clang', [
      '-m$abi',
      '-print-file-name=libgcc_eh.a',
    ], environment: environment);
    if (!await File(unwind).exists()) {
      throw glibc.BuildFailure('Missing libgcc_eh.a for x86-$abi');
    }
    for (final fixture in ['libc', 'allocator']) {
      for (final static in [false, true]) {
        final mode = static ? 'static' : 'shared';
        final binary = '${scratch.path}/$fixture-$abi-$mode';
        await glibc.run('clang++', [
          glibc.clangDriverOption,
          '-m$abi',
          '-std=c++20',
          '-O2',
          '-fno-builtin',
          '-fno-exceptions',
          '-fno-rtti',
          '-pthread',
          '-fuse-ld=lld',
          '--rtlib=compiler-rt',
          if (static) ...['-static', '-nostdlib++'],
          '$project/tests/$fixture.cpp',
          if (static) ...[
            '-Wl,--start-group',
            '-lc',
            unwind,
            '-Wl,--end-group',
          ],
          '-o',
          binary,
        ], environment: environment);
        await glibc.run('timeout', [
          '--kill-after=5s',
          '30s',
          binary,
          if (!static && fixture == 'libc') libc,
        ]);
        stdout.writeln('PASS Gentoo binpkg $fixture ($mode, x86-$abi)');
      }
    }
  }
  // Gentoo preserves the loader's symbols but may strip libc's .comment.
  const loader = '/lib64/ld-linux-x86-64.so.2';
  final toolchain = await capture('llvm-readelf', [
    '-p',
    '.comment',
    loader,
  ], environment: environment);
  if (!toolchain.contains('Linker: LLD') ||
      !toolchain.contains('clang version')) {
    throw glibc.BuildFailure('$loader was not built with Clang and LLD');
  }
  for (final elf in ['/usr/lib64/libc.so.6', loader]) {
    final properties = await capture('llvm-readelf', [
      '-n',
      '-l',
      '-d',
      elf,
    ], environment: environment);
    if (!properties.contains('IBT, SHSTK') ||
        !properties.contains('GNU_RELRO') ||
        !RegExp(r'\(FLAGS(?:_1)?\)[^\n]*\b(?:BIND_NOW|NOW)\b')
            .hasMatch(properties) ||
        !RegExp(
          r'^\s*GNU_STACK(?:[ \t]+0x[0-9a-f]+){5}[ \t]+[RW ]+[ \t]+0x[0-9a-f]+$',
          multiLine: true,
        ).hasMatch(properties)) {
      throw glibc.BuildFailure('Unexpected ELF hardening for $elf');
    }
  }
}

Future<void> archiveSources(
  String output,
  Directory scratch,
  String pkgdir,
  File mimalloc,
  bool systemd,
) async {
  final sources = '${scratch.path}/source';
  final distfiles = '$sources/distfiles';
  await Directory('$sources/packaging').create(recursive: true);
  await Directory(distfiles).create();
  final ebuild = await File('$pkgdir/$ebuildName').readAsString();
  String variable(String name) =>
      RegExp('^$name=(.+)\$', multiLine: true).firstMatch(ebuild)!.group(1)!;
  final distdir = mimalloc.parent.path;
  final signature = File('$distdir/glibc-$sourceVersion.tar.xz.sig');
  for (final file in [
    mimalloc,
    File('$distdir/glibc-$sourceVersion.tar.xz'),
    File(
      '$distdir/glibc-$sourceVersion-patches-${variable('PATCH_VER')}.tar.xz',
    ),
    if (await signature.exists()) signature,
    if (systemd)
      File('$distdir/glibc-systemd-${variable('GLIBC_SYSTEMD_VER')}.tar.gz'),
  ]) {
    await file.copy('$distfiles/${file.uri.pathSegments.last}');
  }
  await glibc.run('cp', ['-a', pkgdir, '$sources/gentoo-glibc']);
  await glibc.run('cp', [
    '-a',
    '$project/packaging/gentoo',
    '$sources/packaging/',
  ]);
  await glibc.run('cp', [
    '-a',
    for (final name in [
      'LICENSE',
      'build.dart',
      'test.dart',
      'patches',
      'shim',
      'tests',
    ])
      '$project/$name',
    '$project/.github/workflows/binhost.yml',
    '$sources/',
  ]);
  await glibc.run('tar', ['-C', sources, '-cJf', '$output/source.tar.xz', '.']);
}

Future<Map<String, String>> installToolchain(List<String> abis) async {
  await glibc.run('emerge', [
    '--oneshot',
    '--getbinpkg',
    '--usepkgonly',
    '--noreplace',
    ...llvmPackages,
  ]);
  await glibc.run('env-update', []);
  final profile = await File('/etc/profile.env').readAsString();
  final path = RegExp(
    r"^export ROOTPATH='([^']+)'$",
    multiLine: true,
  ).firstMatch(profile)?.group(1);
  if (path == null)
    throw const glibc.BuildFailure('Cannot read Gentoo LLVM toolchain path');
  final environment = {
    ...Platform.environment,
    'PATH': path,
    'MAKEOPTS': '-j${Platform.numberOfProcessors}',
  };
  await glibc.run('clang', ['--version'], environment: environment);
  await glibc.run('ld.lld', ['--version'], environment: environment);

  Future<File> builtins(String abi) async => File(
    await capture('clang', [
      glibc.clangDriverOption,
      '-m$abi',
      '--rtlib=compiler-rt',
      '-print-libgcc-file-name',
    ], environment: environment),
  );

  if (abis.contains('32') && !await (await builtins('32')).exists()) {
    final resource = await capture('clang', [
      '-print-resource-dir',
    ], environment: environment);
    final slot = Directory(resource).uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    final runtime = 'llvm-runtimes/compiler-rt:$slot';
    await writePortageSetting(
      'package.use/ekuos-compiler-rt',
      '$runtime abi_x86_32 abi_x86_64 clang',
    );
    await glibc.run('emerge', [
      '--oneshot',
      '--getbinpkg',
      '--usepkg-exclude=$runtime',
      runtime,
    ], environment: environment);
  }
  for (final abi in abis) {
    final runtime = await builtins(abi);
    if (!await runtime.exists()) {
      throw glibc.BuildFailure(
        'Missing compiler-rt for x86-$abi: ${runtime.path}',
      );
    }
  }
  return environment;
}

Future<void> buildPackage(String output) async {
  final profile = requiredEnv('GENTOO_PROFILE');
  final use = requiredEnv('GLIBC_USE');
  final abis = requiredEnv('GLIBC_ABIS').split(' ');
  if (await Link('/etc/portage/make.profile').resolveSymbolicLinks() !=
          '$repo/profiles/$profile' ||
      await capture('portageq', ['envvar', 'CHOST']) != 'x86_64-pc-linux-gnu') {
    throw const glibc.BuildFailure(
      'Gentoo stage does not match the target profile or CHOST',
    );
  }
  final llvmEnvironment = await installToolchain(abis);

  final pkgdir = '$repo/$package';
  final distdir = await capture('portageq', ['envvar', 'DISTDIR']);
  final mimallocVersion = glibc.mimallocTag.substring(1);
  final mimalloc = File('$distdir/mimalloc-$mimallocVersion.tar.gz');
  await mimalloc.parent.create(recursive: true);
  await glibc.run('curl', [
    '--fail',
    '--location',
    '--retry',
    '3',
    'https://codeload.github.com/microsoft/mimalloc/tar.gz/refs/tags/${glibc.mimallocTag}',
    '--output',
    mimalloc.path,
  ]);
  await patchEbuild(pkgdir, mimalloc);
  await writePortageSetting(
    'package.accept_keywords/ekuos-glibc',
    '$atom ~amd64',
  );
  // Gentoo masks this experimental flag on the stock GCC profiles.
  await writePortageSetting('profile/package.use.mask', '$atom -clang');
  await writePortageSetting(
    'package.use/ekuos-glibc',
    '$atom cet clang multiarch ssp static-libs $use',
  );

  final flags =
      '-O2 -pipe -march=x86-64 -mtune=generic ${glibc.stackClashProtection}';
  final environment = {
    ...llvmEnvironment,
    ...glibc.toolchain,
    'PKGDIR': output,
    'BINPKG_FORMAT': 'gpkg',
    'FEATURES': '-getbinpkg -binpkg-signing -binpkg-request-signature',
    'CFLAGS': flags,
    'CXXFLAGS': flags,
  };
  await Directory(output).create(recursive: true);
  await glibc.run('emerge', [
    '--oneshot',
    '--onlydeps',
    atom,
  ], environment: environment);
  await glibc.run('emerge', [
    '--oneshot',
    '--buildpkgonly',
    atom,
  ], environment: environment);
  // Exercise the binary install and post-install hooks in the disposable build root.
  await File('/etc/locale.gen').writeAsString('en_US.UTF-8 UTF-8\n');
  await glibc.run('emerge', [
    '--oneshot',
    '--usepkgonly',
    '--binpkg-respect-use=y',
    '--reinstall-atoms=$package',
    atom,
  ], environment: environment);

  final scratch = await Directory.systemTemp.createTemp('ekuos-binhost-');
  try {
    await checkInstalledPackage(scratch, abis, llvmEnvironment);
    await archiveSources(
      output,
      scratch,
      pkgdir,
      mimalloc,
      use.split(' ').contains('systemd'),
    );
  } finally {
    await scratch.delete(recursive: true);
  }
}

Future<void> importSigningKey(String signing) async {
  // The first line is the optional passphrase. The remaining stdin is the
  // armored private key. Neither secret is passed as an argument or env var.
  final input = await stdin.transform(utf8.decoder).join();
  final boundary = input.indexOf('\n');
  if (boundary < 0 ||
      !input
          .substring(boundary + 1)
          .trimLeft()
          .startsWith('-----BEGIN PGP PRIVATE KEY BLOCK-----')) {
    throw const glibc.BuildFailure(
      'Expected a passphrase line and an armored private key',
    );
  }
  if (boundary > 0) {
    // The signing home is mode 0700 and is deleted after signing.
    final passphraseFile = await File('$signing/passphrase').create();
    await glibc.run('chmod', ['600', passphraseFile.path]);
    await passphraseFile.writeAsString('${input.substring(0, boundary)}\n');
    await File('$signing/gpg.conf').writeAsString(
      'pinentry-mode loopback\npassphrase-file ${passphraseFile.path}\n',
    );
  }
  final process = await Process.start('gpg', [
    '--homedir',
    signing,
    '--batch',
    '--import',
  ]);
  // Do not print import output: malformed input must not leak key material.
  final output = Future.wait([
    process.stdout.drain<void>(),
    process.stderr.drain<void>(),
  ]);
  process.stdin.write(input.substring(boundary + 1));
  await process.stdin.close();
  await output;
  if (await process.exitCode != 0) {
    throw const glibc.BuildFailure('Could not import the binhost signing key');
  }
}

Future<void> signPackage(String output) async {
  final scratch = await Directory.systemTemp.createTemp('ekuos-signing-');
  final signing = '${scratch.path}/sign';
  final verification = '${scratch.path}/verify';
  try {
    await glibc.run('chmod', ['755', scratch.path]);
    await glibc.run('install', ['-d', '-m700', signing, verification]);
    await Directory('/run/lock').create(recursive: true);
    await importSigningKey(signing);
    final listing = await capture('gpg', [
      '--homedir',
      signing,
      '--batch',
      '--with-colons',
      '--list-secret-keys',
    ]);
    final fingerprints = RegExp(
      r'^sec:[^\n]*\nfpr:(?:[^:\n]*:){8}([^:\n]+):',
      multiLine: true,
    ).allMatches(listing).map((match) => match.group(1)!).toList();
    if (fingerprints.length != 1) {
      throw const glibc.BuildFailure(
        'Expected exactly one binhost signing key',
      );
    }
    final fingerprint = fingerprints.single;
    final publicKey = File('$output/signing-key.asc');
    final exported = await capture('gpg', [
      '--homedir',
      signing,
      '--batch',
      '--armor',
      '--export',
      fingerprint,
    ]);
    await publicKey.writeAsString('$exported\n');
    await File('$output/signing-key.fingerprint')
        .writeAsString('$fingerprint\n');
    final ownerTrust = await File('${scratch.path}/ownertrust')
        .writeAsString('$fingerprint:6:\n');
    await glibc.run('gpg', [
      '--homedir',
      verification,
      '--batch',
      '--import',
      publicKey.path,
    ]);
    await glibc.run('gpg', [
      '--homedir',
      verification,
      '--batch',
      '--import-ownertrust',
      ownerTrust.path,
    ]);
    await glibc.run('gpg', [
      '--homedir',
      verification,
      '--batch',
      '--check-trustdb',
    ]);
    await glibc.run('chmod', ['-R', 'a+rX', verification]);
    await glibc.run('chmod', ['755', verification]);

    final pkg = Directory('$output/$package');
    final packages = await pkg
        .list()
        .where(
          (file) =>
              file is File &&
              RegExp('^glibc-$version-\\d+\\.gpkg\\.tar\$')
                  .hasMatch(file.uri.pathSegments.last),
        )
        .toList();
    if (packages.length != 1) {
      throw const glibc.BuildFailure('Expected exactly one glibc GPKG');
    }
    final packagePath = packages.single.path;
    final relativePath = packagePath.substring(output.length + 1);
    final environment = {
      ...Platform.environment,
      'PKGDIR': output,
      'BINPKG_FORMAT': 'gpkg',
      'BINPKG_GPG_SIGNING_GPG_HOME': signing,
      'BINPKG_GPG_VERIFY_GPG_HOME': verification,
      'BINPKG_GPG_SIGNING_KEY': fingerprint,
      'FEATURES': 'binpkg-request-signature',
    };
    // Portage verifies signatures while regenerating the index below.
    await glibc.run('gpkg-sign', [
      '--allow-unsigned',
      packagePath,
    ], environment: environment);
    await glibc.run('chmod', ['a+r', packagePath]);
    // Do not carry the unsigned package's cached digest into the signed index.
    for (final name in ['Packages', 'Packages.gz']) {
      final index = File('$output/$name');
      if (await index.exists()) await index.delete();
    }
    await glibc.run('emaint', ['binhost', '--fix'], environment: environment);
    await glibc.run('emaint', ['binhost', '--check'], environment: environment);
    final index = await File('$output/Packages').readAsLines();
    for (final entry in [
      'PACKAGES: 1',
      'CPV: $package-$version',
      'SLOT: 2.2',
      'REPO: gentoo',
      'PATH: $relativePath',
    ]) {
      if (!index.contains(entry)) {
        throw glibc.BuildFailure('Missing Portage index entry: $entry');
      }
    }
    final sums = await capture('sha256sum', [
      relativePath,
      'source.tar.xz',
    ], cwd: output);
    await File('$output/SHA256SUMS').writeAsString('$sums\n');
    await glibc.run('chmod', ['-R', 'a+rX', output]);
  } finally {
    await scratch.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  try {
    switch (args.firstOrNull) {
      case 'prepare' when args.length == 4:
        await glibc.prepareAllocator(
          args[1],
          Directory(args[2]),
          File(args[3]),
        );
      case 'mimalloc' when args.length >= 4:
        await glibc.compileMimalloc(
          args[1],
          args[2],
          enableCet: args[3] == 'yes',
          compilerFlags: args.skip(4).toList(),
        );
      case 'soft-float':
        stdout.writeln(
          await glibc.softFloatRuntimeSupport(args.skip(1).toList()),
        );
      case 'hardening' when args.length == 1:
        stdout.writeln('${glibc.bindNow} ${glibc.fortify}');
      case 'cet' when args.length == 1:
        stdout.writeln(glibc.permissiveCet);
      case 'build' when args.length == 1:
        await buildPackage('/output/${requiredEnv('BINHOST_PATH')}');
      case 'sign' when args.length == 1:
        await signPackage('/output/${requiredEnv('BINHOST_PATH')}');
      default:
        throw const glibc.BuildFailure('Usage: ekuos-binhost build|sign');
    }
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}
