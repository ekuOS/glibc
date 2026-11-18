#!/usr/bin/env dart

import 'dart:io';

import 'tests/custom.dart';

const usage =
    'Usage: dart run test.dart [--output PATH]\n'
    'Run the fork tests against an existing build (default: glibc/build).';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--help') {
    stdout.writeln(usage);
    return;
  }
  if (args.isNotEmpty &&
      (args.length != 2 ||
          args.first != '--output' ||
          args.last.isEmpty ||
          args.last.startsWith('--'))) {
    stderr.writeln(usage);
    exitCode = 2;
    return;
  }
  try {
    final output = Directory(args.isEmpty ? 'glibc/build' : args.last);
    exitCode = await runCustomTests(output) ? 0 : 1;
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}
