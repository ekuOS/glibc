#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

const defaultRepo = 'https://sourceware.org/git/glibc.git';
const defaultTag = 'glibc-2.44';
const mimallocRepo = 'https://github.com/microsoft/mimalloc.git';
const mimallocTag = 'v3.7.0';
const usage =
    '''glibc builder (Linux, Dart SDK 3+; Clang/LLVM only)

Usage: dart run build.dart [build] [options]

  --source PATH    Source directory (default: glibc/src; clone if absent/empty)
  --tag TAG        Exact Git tag (default for new clones: $defaultTag)
  --repo URL       Git repository (default: $defaultRepo)
  --patches PATH   Extra glibc patches to apply after the bundled patch
  --output PATH    Out-of-tree build directory (default: glibc/build)
  --headers PATH   Optional exported Linux UAPI headers directory
  --jobs NUMBER    Parallel jobs (default: available CPU count)
  --help           Show this help

Relative paths are resolved against the current directory. Existing sources
are reused without fetching or switching revisions. No installation is run.
''';

class BuildFailure implements Exception {
  const BuildFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

class Options {
  String source = 'glibc/src';
  String repo = defaultRepo;
  String? tag;
  String? patches;
  String output = 'glibc/build';
  String? headers;
  int jobs = Platform.numberOfProcessors;

  static Options parse(List<String> args) {
    final options = Options();
    for (
      var i = args.isNotEmpty && args.first == 'build' ? 1 : 0;
      i < args.length;
      i++
    ) {
      final name = args[i];
      if (!const {
        '--source',
        '--repo',
        '--tag',
        '--patches',
        '--output',
        '--headers',
        '--jobs',
      }.contains(name)) {
        throw BuildFailure('Unknown option: $name');
      }
      if (++i == args.length || args[i].isEmpty || args[i].startsWith('--')) {
        throw BuildFailure('Missing value for $name');
      }
      final value = args[i];
      switch (name) {
        case '--source':
          options.source = value;
        case '--repo':
          options.repo = value;
        case '--tag':
          options.tag = value;
        case '--patches':
          options.patches = value;
        case '--output':
          options.output = value;
        case '--headers':
          options.headers = value;
        case '--jobs':
          options.jobs = int.tryParse(value) ?? 0;
          if (options.jobs < 1) {
            throw const BuildFailure('--jobs must be positive');
          }
      }
    }
    return options;
  }
}

// Configure also probes with compile-only commands and -Werror.
const linkerOptions =
    '--start-no-unused-arguments -fuse-ld=lld '
    '--rtlib=compiler-rt --end-no-unused-arguments';
const stackClashProtection = '-fstack-clash-protection';
const cCompiler = 'clang $linkerOptions';
const cxxCompiler = 'clang++ $linkerOptions';
const toolchain = {
  'CC': cCompiler,
  'CXX': cxxCompiler,
  'CPP': '$cCompiler -E',
  'BUILD_CC': cCompiler,
  'TEST_CC': cCompiler,
  'TEST_CXX': cxxCompiler,
  'LD': 'ld.lld',
  'AR': 'llvm-ar',
  'NM': 'llvm-nm',
  'OBJCOPY': 'llvm-objcopy',
  'OBJDUMP': 'llvm-objdump',
  'RANLIB': 'llvm-ranlib',
  'READELF': 'llvm-readelf',
  'STRIP': 'llvm-strip',
};

final watch = Stopwatch()..start();

void log(String message) =>
    stdout.writeln('[${watch.elapsed.inSeconds}s] $message');

Future<void> run(
  String command,
  List<String> args, {
  String? cwd,
  Map<String, String>? environment,
}) async {
  log([command, ...args].map(jsonEncode).join(' '));
  final process = await Process.start(
    command,
    args,
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: environment == null,
    mode: ProcessStartMode.inheritStdio,
  );
  final status = await process.exitCode;
  if (status != 0) throw BuildFailure('$command failed (exit $status)');
}

// Resolve symlinked parents even when the final directory does not exist yet.
Future<String> resolvedPath(Directory directory) async {
  final path = directory.path;
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return directory.resolveSymbolicLinks();
  }
  final parent = await resolvedPath(directory.parent);
  final name = directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
  return '${parent == '/' ? '' : parent}/$name';
}

Future<String> buildPath(String path) async {
  final absolute = Directory(path).absolute;
  final resolved = await resolvedPath(
    Directory(absolute.uri.normalizePath().toFilePath()),
  );
  if (!RegExp(r'^[/a-zA-Z0-9_.+-]+$').hasMatch(resolved)) {
    throw BuildFailure(
      'Source, output, and headers paths need shell-safe characters: $resolved',
    );
  }
  return resolved;
}

bool containsPath(String parent, String child) =>
    parent == '/' || parent == child || child.startsWith('$parent/');

Future<void> prepareSource(
  String source,
  String repo,
  String? requestedTag,
  String cloneTag,
) async {
  final directory = Directory(source);
  final clone = !await directory.exists() || await directory.list().isEmpty;
  final tag = requestedTag ?? (clone ? cloneTag : null);
  if (tag != null) {
    final valid = await Process.run('git', [
      'check-ref-format',
      'refs/tags/$tag',
    ]);
    if (tag.startsWith('-') || valid.exitCode != 0) {
      throw BuildFailure('Invalid Git tag: $tag');
    }
  }
  if (clone) {
    await run('git', [
      'clone',
      '--depth',
      '1',
      '--single-branch',
      '--branch',
      tag!,
      '--',
      repo,
      source,
    ]);
  } else {
    log('Reusing source tree: $source');
  }
  if (tag != null) {
    final revision = await Process.run('git', [
      'rev-parse',
      '--show-toplevel',
      'HEAD',
      'refs/tags/$tag^{commit}',
    ], workingDirectory: source);
    final lines = const LineSplitter().convert(revision.stdout as String);
    if (revision.exitCode != 0 ||
        lines.length != 3 ||
        lines[0] != source ||
        lines[1] != lines[2]) {
      throw BuildFailure('Source HEAD does not match Git tag $tag: $source');
    }
  }
}

Future<void> applyPatches(Directory directory, String source) async {
  final patches = await directory
      .list(followLinks: false)
      .where(
        (entry) =>
            entry is File &&
            (entry.path.endsWith('.patch') || entry.path.endsWith('.diff')),
      )
      .toList();
  patches.sort((a, b) => a.path.compareTo(b.path));
  if (patches.isEmpty) log('No .patch or .diff files in ${directory.path}');
  for (final patch in patches) {
    final args = [
      '--force',
      '--fuzz=0',
      '-p1',
      '--reject-file=-',
      '-i',
      patch.path,
    ];
    final check = await Process.run('patch', [
      ...args,
      '--dry-run',
    ], workingDirectory: source);
    if (check.exitCode == 0) {
      await run('patch', args, cwd: source);
      continue;
    }
    final reverse = await Process.run('patch', [
      ...args,
      '--reverse',
      '--dry-run',
    ], workingDirectory: source);
    if (reverse.exitCode != 0) {
      throw BuildFailure(
        'Patch check failed: ${patch.path}\n${check.stdout}${check.stderr}',
      );
    }
    log('Already applied: ${patch.path}');
  }
}

Future<String> softFloatRuntimeSupport([
  List<String> compilerFlags = const [],
]) async {
  final runtime = await Process.run('clang', [
    ...compilerFlags,
    '--rtlib=compiler-rt',
    '-print-libgcc-file-name',
  ]);
  final archive = (runtime.stdout as String).trim();
  if (runtime.exitCode != 0 || !await File(archive).exists()) {
    throw const BuildFailure('Clang compiler-rt builtins archive not found');
  }
  // glibc 2.44's configure link probe can pick up this symbol from the
  // host libc. Check compiler-rt itself instead.
  final symbols = await Process.run('llvm-nm', [
    '--defined-only',
    '--format=posix',
    archive,
  ]);
  if (symbols.exitCode != 0) {
    throw BuildFailure('Cannot inspect compiler-rt: ${symbols.stderr}');
  }
  return RegExp(
        r'^__sfp_handle_exceptions\s+[TW]\s',
        multiLine: true,
      ).hasMatch(symbols.stdout as String)
      ? 'yes'
      : 'no';
}

Future<void> compileMimalloc(
  String source,
  String object, {
  List<String> compilerFlags = const [],
  required bool enableCet,
}) async {
  await File(object).parent.create(recursive: true);
  await run('clang', [
    ...compilerFlags,
    '-std=gnu11',
    '-O2',
    '-fPIC',
    '-fvisibility=hidden',
    '-ftls-model=initial-exec',
    '-fstack-protector-strong',
    stackClashProtection,
    '-U_FORTIFY_SOURCE',
    '-D_FORTIFY_SOURCE=3',
    // The linker keeps CET properties only when all input objects have them.
    if (enableCet) '-fcf-protection=full',
    '-pthread',
    '-DNDEBUG',
    '-DMI_SECURE=4',
    '-DMI_NO_PTHREAD_ATFORK=1',
    '-DMI_SKIP_COLLECT_ON_EXIT=1',
    '-DMI_USE_ENVIRON=0',
    '-Dgetenv=secure_getenv',
    '-I$source/include',
    '-c',
    '$source/src/static.c',
    '-o',
    '$object.tmp',
  ]);
  await File('$object.tmp').rename(object);
}

Future<void> build(Options options) async {
  final source = await buildPath(options.source);
  final output = await buildPath(options.output);
  final mimalloc = await buildPath('mimmaloc');
  final paths = [source, output, mimalloc];
  for (var i = 0; i < paths.length; i++) {
    for (final other in paths.skip(i + 1)) {
      if (containsPath(paths[i], other) || containsPath(other, paths[i])) {
        throw BuildFailure(
          'Source and build paths overlap: ${paths[i]}, $other',
        );
      }
    }
  }
  final headers = options.headers == null
      ? null
      : await buildPath(options.headers!);
  if (headers != null && !await File('$headers/linux/version.h').exists()) {
    throw BuildFailure('Exported Linux headers not found: $headers');
  }
  final bundled = Directory.fromUri(Platform.script.resolve('patches/'));
  final shim = File.fromUri(Platform.script.resolve('shim/eku-malloc.c'));
  if (!await File('${bundled.path}/001-use-mimalloc.patch').exists() ||
      !await shim.exists()) {
    throw const BuildFailure('The bundled mimalloc patch or shim is missing');
  }
  final patches = options.patches == null
      ? null
      : Directory(options.patches!).absolute;
  if (patches != null && !await patches.exists()) {
    throw BuildFailure('Patch directory not found: ${patches.path}');
  }

  final environment = Map<String, String>.of(Platform.environment)
    ..removeWhere(
      (key, _) => const {
        'MAKEFLAGS',
        'GNUMAKEFLAGS',
        'MFLAGS',
        'MAKEOVERRIDES',
        'MAKEFILES',
      }.contains(key),
    )
    ..addAll(toolchain)
    ..['CONFIG_SITE'] = '/dev/null';
  for (final tool in {
    'clang',
    'clang++',
    ...toolchain.values.where((v) => !v.contains(' ')),
  }) {
    final result = await Process.run(tool, ['--version']);
    if (result.exitCode != 0) throw BuildFailure('Cannot run $tool --version');
  }

  final target = await Process.run('clang', ['-dumpmachine']);
  if (target.exitCode != 0 || (target.stdout as String).trim().isEmpty) {
    throw BuildFailure('Cannot determine Clang target: ${target.stderr}');
  }
  final enableCet =
      (target.stdout as String).trim().split('-').first == 'x86_64';
  final cflags = environment['CFLAGS'] ?? '-g -O2';
  environment['CFLAGS'] = '$cflags $stackClashProtection';
  environment['libc_cv_sfp_handle_exceptions'] =
      await softFloatRuntimeSupport();
  await prepareSource(source, options.repo, options.tag, defaultTag);
  if (!await File('$source/configure').exists() ||
      !await File('$source/Makeconfig').exists()) {
    throw BuildFailure('Not a glibc source tree: $source');
  }
  await applyPatches(bundled, source);
  final stagedShim = File('$source/malloc/eku-malloc.c');
  final shimContents = await shim.readAsString();
  if (!await stagedShim.exists() ||
      await stagedShim.readAsString() != shimContents) {
    await stagedShim.writeAsString(shimContents);
  }
  if (patches != null &&
      await patches.resolveSymbolicLinks() !=
          await bundled.resolveSymbolicLinks()) {
    await applyPatches(patches, source);
  }

  final miSource = '$mimalloc/src';
  final miBuild = '$mimalloc/build';
  final miObject = '$miBuild/mimalloc.o';
  await prepareSource(miSource, mimallocRepo, mimallocTag, mimallocTag);
  await compileMimalloc(miSource, miObject, enableCet: enableCet);
  await Directory(output).create(recursive: true);
  await run(
    '$source/configure',
    [
      '--prefix=/usr',
      '--disable-werror',
      '--disable-static-c++-link-check',
      '--enable-stack-protector=strong',
      '--enable-fortify-source=3',
      '--enable-bind-now',
      if (enableCet) '--enable-cet=permissive',
      if (headers != null) '--with-headers=$headers',
    ],
    cwd: output,
    environment: environment,
  );
  await run(
    'make',
    [
      '-j${options.jobs}',
      for (final entry in toolchain.entries) '${entry.key}=${entry.value}',
      'ekuos-mimalloc-object=$miObject',
      'all',
    ],
    cwd: output,
    environment: environment,
  );
  log('Build complete: $output');
}

Future<void> main(List<String> args) async {
  try {
    if (args.contains('--help')) {
      stdout.write(usage);
      return;
    }
    if (!Platform.isLinux) throw const BuildFailure('Linux is required');
    await build(Options.parse(args));
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}
