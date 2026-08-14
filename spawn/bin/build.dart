// Compiles a package's worker entrypoints into the payloads the web backend
// loads. Run it from the root of the package that owns the workers:
//
//     dart run spawn:build
//
// There is no build_runner, no code generation and no generated Dart source.
// The only artifact is the compiled payload itself.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String _usage = '''
Usage: dart run spawn:build [directory] [options]

Compiles every worker entrypoint in <directory> (default: lib/workers) to
<directory>/build/<name>.dart.js, skipping files whose inputs have not
changed since the last build.

Options:
  -o, --output <dir>   Where to write payloads (default: <directory>/build)
      --force          Rebuild even when nothing changed
      --verbose        Print the compiler command for each file
  -h, --help           Show this text
''';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.write(_usage);
    return;
  }

  final inputDir = Directory(options.input);
  if (!inputDir.existsSync()) {
    stderr.writeln(
      'spawn:build: no worker directory at "${options.input}".\n'
      'Worker entrypoints live in lib/workers/ - one file per worker, each '
      'with `void main() => runWorker(<handler>);`.',
    );
    exitCode = 1;
    return;
  }

  final entrypoints =
      inputDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (entrypoints.isEmpty) {
    stdout.writeln('spawn:build: no worker entrypoints in ${options.input}');
    return;
  }

  final outputDir = Directory(options.output);
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  final fingerprint = _fingerprintInputs(options.input);
  var failures = 0;
  var built = 0;
  var skipped = 0;

  for (final entrypoint in entrypoints) {
    final stem = _stem(entrypoint.path);
    final output = File('${options.output}/$stem.dart.js');
    final stamp = File('${options.output}/$stem.dart.js.stamp');
    final want = _mix(fingerprint, _hashFile(entrypoint));

    if (!options.force &&
        output.existsSync() &&
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == want.toRadixString(16)) {
      stdout.writeln('  $stem  up to date  (${_size(output.lengthSync())})');
      skipped++;
      continue;
    }

    if (!_declaresMain(entrypoint)) {
      // Not an entrypoint. Worker directories hold helper files too - a
      // conditional-import stub, a shared protocol - and failing the build on
      // them would force an artificial directory split.
      stdout.writeln('  $stem  skipped  (no `main`, not an entrypoint)');
      skipped++;
      continue;
    }

    final command = <String>[
      'compile',
      'js',
      '-O2',
      '-o',
      output.path,
      entrypoint.path,
    ];
    if (options.verbose) {
      stdout.writeln('  ${Platform.resolvedExecutable} ${command.join(' ')}');
    }
    final result = await Process.run(
      Platform.resolvedExecutable,
      command,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      stderr
        ..writeln('  $stem  FAILED')
        ..writeln(_indent('${result.stdout}'.trim()))
        ..writeln(_indent('${result.stderr}'.trim()));
      failures++;
      continue;
    }

    stamp.writeAsStringSync(want.toRadixString(16));
    // dart2js also emits a source map and a deferred-parts manifest; leave
    // them next to the payload, they are only fetched when asked for.
    stdout.writeln('  $stem  built  (${_size(output.lengthSync())})');
    built++;
  }

  stdout.writeln(
    'spawn:build: $built built, $skipped up to date'
    '${failures > 0 ? ', $failures failed' : ''}',
  );
  if (failures > 0) exitCode = 1;
}

class _Options {
  _Options(this.input, this.output, this.force, this.verbose, this.help);

  factory _Options.parse(List<String> arguments) {
    var input = 'lib/workers';
    String? output;
    var force = false;
    var verbose = false;
    var help = false;
    var sawInput = false;

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '-h':
        case '--help':
          help = true;
        case '--force':
          force = true;
        case '--verbose':
          verbose = true;
        case '-o':
        case '--output':
          if (i + 1 < arguments.length) output = arguments[++i];
        default:
          if (argument.startsWith('--output=')) {
            output = argument.substring('--output='.length);
          } else if (!argument.startsWith('-') && !sawInput) {
            input = argument;
            sawInput = true;
          }
      }
    }
    input = input.replaceAll(r'\', '/');
    while (input.endsWith('/')) {
      input = input.substring(0, input.length - 1);
    }
    return _Options(
      input,
      (output ?? '$input/build').replaceAll(r'\', '/'),
      force,
      verbose,
      help,
    );
  }

  final String input;
  final String output;
  final bool force;
  final bool verbose;
  final bool help;
}

String _stem(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final slash = normalized.lastIndexOf('/');
  final name = slash < 0 ? normalized : normalized.substring(slash + 1);
  return name.substring(0, name.length - '.dart'.length);
}

bool _declaresMain(File file) => RegExp(
  r'^\s*(void|Future<void>|Never)?\s*main\s*\(',
  multiLine: true,
).hasMatch(file.readAsStringSync());

/// Everything other than the entrypoint itself that can change its output.
///
/// A worker's payload depends on the whole library graph, not just its own
/// file. Hashing the package's `lib/`, the worker directory and the resolved
/// dependency versions catches the cases that matter without asking the
/// compiler for a dependency list.
int _fingerprintInputs(String workerDir) {
  var hash = 0x811C9DC5;
  for (final path in <String>[
    'pubspec.lock',
    '.dart_tool/package_config.json',
  ]) {
    final file = File(path);
    if (file.existsSync()) hash = _mix(hash, _hashFile(file));
  }
  for (final directory in <String>[
    ..._pathDependencyLibDirs(),
    'lib',
    workerDir,
  ]) {
    final dir = Directory(directory);
    if (!dir.existsSync()) continue;
    final files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.replaceAll(r'\', '/').contains('/build/'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      hash = _mix(hash, _hashFile(file));
    }
  }
  return hash;
}

/// The `lib/` directory of every path dependency, from the package config.
///
/// Only path dependencies: a hosted package cannot change without its version
/// changing, which `pubspec.lock` already covers.
List<String> _pathDependencyLibDirs() {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return const <String>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(config.readAsStringSync());
  } on FormatException {
    return const <String>[];
  }
  if (decoded is! Map<String, Object?>) return const <String>[];
  final packages = decoded['packages'];
  if (packages is! List<Object?>) return const <String>[];

  final dirs = <String>[];
  for (final entry in packages) {
    if (entry is! Map<String, Object?>) continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String) continue;
    // A path dependency's rootUri is RELATIVE, resolved against .dart_tool/.
    // Only hosted and git packages get an absolute file: URI, and those are
    // exactly the ones that cannot change without their version changing.
    final String root;
    if (rootUri.startsWith('file:')) {
      root = Uri.parse(rootUri).toFilePath();
    } else if (rootUri.startsWith('..') || rootUri.startsWith('./')) {
      root = Uri.directory('.dart_tool/').resolve(rootUri).toFilePath();
    } else {
      continue;
    }
    final normalized = root
        .replaceAll(r'\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalized.contains('/hosted/') || normalized.contains('/git/')) {
      continue;
    }
    if (Directory('$normalized/lib').existsSync()) {
      dirs.add('$normalized/lib');
    }
  }
  return dirs;
}

/// FNV-1a over the file's bytes. Not a security hash - a change detector.
int _hashFile(File file) {
  final Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException {
    return 0;
  }
  var hash = 0x811C9DC5;
  for (var i = 0; i < bytes.length; i++) {
    hash = ((hash ^ bytes[i]) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

int _mix(int a, int b) => ((a ^ b) * 0x01000193) & 0xFFFFFFFF;

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} kB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _indent(String text) => text.isEmpty
    ? ''
    : text.split('\n').map((line) => '      $line').join('\n');
