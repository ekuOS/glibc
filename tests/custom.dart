import 'dart:io';

class TestFailure implements Exception {
  const TestFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<String> command(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw TestFailure(
      '$executable ${arguments.join(' ')} (exit ${result.exitCode})\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return result.stdout as String;
}

class BuildTests {
  BuildTests(this.output, this.scratch);

  final String output;
  final String scratch;
  final Uri fixtures = Platform.script.resolve('tests/');
  final environment = Map<String, String>.of(Platform.environment)
    ..removeWhere((key, _) => key.startsWith('LD_') || key == 'GLIBC_TUNABLES');

  String get libc => '$output/libc.so';
  String get loader => '$output/elf/ld.so';

  Future<void> checkElf(bool cet) async {
    for (final elf in [libc, loader]) {
      final info = await command('llvm-readelf', ['-l', '-d', '-n', elf]);
      if (!RegExp(r'^\s*GNU_RELRO\s', multiLine: true).hasMatch(info) ||
          !RegExp(r'\(FLAGS(?:_1)?\)[^\n]*\b(?:BIND_NOW|NOW)\b')
              .hasMatch(info)) {
        throw TestFailure('$elf is missing full RELRO');
      }
      final stack = RegExp(
        r'^\s*GNU_STACK(?:[ \t]+0x[0-9a-f]+){5}[ \t]+[RW ]+[ \t]+0x[0-9a-f]+$',
        multiLine: true,
      );
      if (!stack.hasMatch(info)) {
        throw TestFailure('$elf is missing a non-executable GNU_STACK');
      }
      if (cet && !RegExp(r'x86 feature:.*\bIBT\b.*\bSHSTK\b').hasMatch(info)) {
        throw TestFailure('$elf is missing IBT or SHSTK ELF properties');
      }
    }
  }

  Future<String> compile(
    String source,
    String name, {
    bool static = false,
    bool cet = false,
    bool shared = false,
  }) async {
    final binary = '$scratch/$name';
    // Keep the fixtures linked against the selected glibc without a C++ runtime.
    const clang = [
      '-std=c++20',
      '-fno-exceptions',
      '-fno-rtti',
      '-fuse-ld=lld',
      '-nostdlib',
    ];
    final input = fixtures.resolve(source).toFilePath();
    if (shared) {
      await command('clang++', [
        ...clang,
        '-shared',
        '-fPIC',
        '-fcf-protection=none',
        input,
        '-o',
        binary,
      ]);
      return binary;
    }
    final crt = '$output/csu';
    final builtins = static
        ? (await command('clang', [
            '--rtlib=compiler-rt',
            '-print-libgcc-file-name',
          ])).trim()
        : null;
    final unwind = static
        ? (await command('clang', ['-print-file-name=libgcc_eh.a'])).trim()
        : null;
    if (unwind != null && !await File(unwind).exists()) {
      throw const TestFailure('Static tests require libgcc_eh.a');
    }
    await command('clang++', [
      ...clang,
      '-O2',
      '-fno-builtin',
      '-pthread',
      '-U_FORTIFY_SOURCE',
      if (cet) ...['-fcf-protection=full', '-mshstk'],
      if (static) ...[
        '-static',
        '-fno-pie',
        '$crt/crt1.o',
      ] else ...[
        '-fPIE',
        '-pie',
        '-Wl,--dynamic-linker,$loader',
        '-Wl,-rpath,$output',
        '$crt/Scrt1.o',
      ],
      '$crt/crti.o',
      input,
      if (builtins != null) ...[
        '-Wl,--start-group',
        '$output/libc.a',
        builtins,
        unwind!,
        '-Wl,--end-group',
      ] else ...[
        libc,
        '$output/libc_nonshared.a',
      ],
      '$crt/crtn.o',
      '-o',
      binary,
    ]);
    return binary;
  }

  Future<bool> runProbe(
    String binary, {
    List<String> arguments = const [],
    Map<String, String> overrides = const {},
    bool allowUnsupported = false,
  }) async {
    final result = await Process.run(
      'timeout',
      ['--kill-after=5s', '30s', binary, ...arguments],
      environment: {...environment, ...overrides},
      includeParentEnvironment: false,
    );
    if (allowUnsupported && result.exitCode == 77) return false;
    if (result.exitCode != 0) {
      throw TestFailure(
        '$binary ${arguments.join(' ')} (exit ${result.exitCode})\n'
        '${result.stdout}${result.stderr}',
      );
    }
    return true;
  }
}

Future<bool> runCustomTests(Directory directory) async {
  if (!Platform.isLinux) throw const TestFailure('Linux is required');
  if (!await directory.exists()) {
    throw TestFailure(
      'Missing build directory ${directory.path}. Build glibc first.',
    );
  }
  final output = await directory.absolute.resolveSymbolicLinks();
  for (final file in [
    'libc.so',
    'libc.so.6',
    'libc.a',
    'libc_nonshared.a',
    'elf/ld.so',
  ]) {
    if (!await File('$output/$file').exists()) {
      throw TestFailure('Missing $output/$file. Build glibc first.');
    }
  }

  final scratch = await Directory.systemTemp.createTemp('ekuos-glibc-tests-');
  try {
    final suite = BuildTests(output, scratch.path);
    final header = await command('llvm-readelf', ['-h', suite.libc]);
    final cet = RegExp(
      r'Machine:.*X86-64',
      caseSensitive: false,
    ).hasMatch(header);
    var failures = 0;
    Future<void> test(String name, Future<String?> Function() body) async {
      try {
        final skipped = await body();
        stdout.writeln(
          skipped == null ? 'PASS $name' : 'SKIP $name ($skipped)',
        );
      } on Exception catch (error) {
        failures++;
        stderr.writeln('FAIL $name\n$error');
      }
    }

    await test('ELF hardening', () async {
      await suite.checkElf(cet);
      return null;
    });
    for (final isStatic in [false, true]) {
      final mode = isStatic ? 'static' : 'shared';
      await test('Allocator ABI ($mode)', () async {
        final binary = await suite.compile(
          'allocator.cpp',
          mode,
          static: isStatic,
        );
        await suite.runProbe(binary);
        return null;
      });
    }
    await test('SHSTK compatibility with legacy libraries', () async {
      if (!cet) return 'requires an x86-64 build';
      final legacy = await suite.compile(
        'legacy.cpp',
        'legacy.so',
        shared: true,
      );
      final binary = await suite.compile('cet.cpp', 'cet', cet: true);
      const shstk = {'GLIBC_TUNABLES': 'glibc.cpu.hwcaps=SHSTK'};
      await suite.runProbe(
        binary,
        arguments: ['startup', legacy],
        overrides: {...shstk, 'LD_PRELOAD': legacy},
      );
      final available = await suite.runProbe(
        binary,
        arguments: ['single', legacy],
        overrides: shstk,
        allowUnsupported: true,
      );
      if (!available) return 'kernel shadow stack unavailable';
      await suite.runProbe(
        binary,
        arguments: ['threaded', legacy],
        overrides: shstk,
      );
      return null;
    });
    return failures == 0;
  } finally {
    await scratch.delete(recursive: true);
  }
}
