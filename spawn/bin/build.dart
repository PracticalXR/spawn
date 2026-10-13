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
      --target <kind>  Compiler target: js (default), wasm, or hybrid
      --only <names>   Comma-separated worker stems to compile
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
          .where(
            (f) =>
                options.only == null || options.only!.contains(_stem(f.path)),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (options.only case final requested?) {
    final missing = requested.difference(
      entrypoints.map((f) => _stem(f.path)).toSet(),
    );
    if (missing.isNotEmpty) {
      stderr.writeln('spawn:build: unknown worker(s): ${missing.join(', ')}');
      exitCode = 1;
      return;
    }
  }

  if (entrypoints.isEmpty) {
    stdout.writeln('spawn:build: no worker entrypoints in ${options.input}');
    return;
  }

  final outputDir = Directory(options.output);
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  final fingerprint = _mix(
    _fingerprintInputs(options.input),
    options.target == _Target.js
        ? 0
        : _hashString(
            _wasmBootstrap('_', fallback: options.target == _Target.hybrid),
          ),
  );
  var failures = 0;
  var built = 0;
  var skipped = 0;

  for (final entrypoint in entrypoints) {
    final stem = _stem(entrypoint.path);
    final output = File('${options.output}/$stem.dart.js');
    final stamp = File('${options.output}/$stem.dart.js.stamp');
    final want = _mix(
      _mix(fingerprint, _hashFile(entrypoint)),
      _hashString(options.target.name),
    );
    final fallback = File('${options.output}/$stem.dart.fallback.js');
    final requiredOutputs = switch (options.target) {
      _Target.js => <File>[output],
      _Target.wasm => <File>[
        output,
        File('${options.output}/$stem.dart.wasm'),
        File('${options.output}/$stem.dart.mjs'),
      ],
      _Target.hybrid => <File>[
        output,
        fallback,
        File('${options.output}/$stem.dart.wasm'),
        File('${options.output}/$stem.dart.mjs'),
      ],
    };

    if (!options.force &&
        requiredOutputs.every((file) => file.existsSync()) &&
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == want.toRadixString(16)) {
      stdout.writeln(
        '  $stem  up to date  '
        '(${options.target.name}, ${_size(_totalSize(requiredOutputs))})',
      );
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

    // A failed second compiler must not replace half of a previously working
    // hybrid worker. Compile the complete set before publishing any payload.
    final scratch = Directory.systemTemp.createTempSync('spawn-build-$stem-');
    final wasmOutput = File('${scratch.path}/$stem.dart.wasm');
    final stagedJs = File('${scratch.path}/$stem.dart.js');
    final stagedFallback = File('${scratch.path}/$stem.dart.fallback.js');
    final jsCommand = <String>[
      'compile',
      'js',
      '-O2',
      '-o',
      options.target == _Target.js ? stagedJs.path : stagedFallback.path,
      entrypoint.path,
    ];
    final wasmCommand = <String>[
      'compile',
      'wasm',
      '-O',
      '2',
      '--define=spawn.worker.payload=wasm',
      '-o',
      wasmOutput.path,
      entrypoint.path,
    ];
    try {
      var failedBuild = false;
      for (final command in <List<String>>[
        if (options.target != _Target.js) wasmCommand,
        if (options.target != _Target.wasm) jsCommand,
      ]) {
        if (options.verbose) {
          stdout.writeln(
            '  ${Platform.resolvedExecutable} ${command.join(' ')}',
          );
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
          failedBuild = true;
          break;
        }
      }
      if (failedBuild) continue;

      if (options.target != _Target.js) {
        // The stable classic-worker URL boots Wasm and queues messages until
        // Dart installs onmessage. Publish it last, after its companions.
        stagedJs.writeAsStringSync(
          _wasmBootstrap(stem, fallback: options.target == _Target.hybrid),
        );
      }

      // A missing stamp forces a rebuild after an interrupted publication.
      if (stamp.existsSync()) stamp.deleteSync();
      final stagedFiles = scratch.listSync().whereType<File>().toList();
      for (final staged in stagedFiles.where(
        (file) => file.path != stagedJs.path,
      )) {
        staged.copySync('${options.output}/${_fileName(staged.path)}');
      }
      stagedJs.copySync(output.path);
      stamp.writeAsStringSync(want.toRadixString(16));
    } finally {
      // The temp directory was created directly beneath systemTemp. Check its
      // resolved parent before any recursive cleanup on Windows.
      if (scratch.parent.resolveSymbolicLinksSync() ==
          Directory.systemTemp.resolveSymbolicLinksSync()) {
        scratch.deleteSync(recursive: true);
      } else {
        stderr.writeln('spawn: left unexpected scratch path ${scratch.path}');
        failures++;
      }
    }
    // dart2js also emits a source map and a deferred-parts manifest; leave
    // them next to the payload, they are only fetched when asked for.
    stdout.writeln(
      '  $stem  built  '
      '(${options.target.name}, ${_size(_totalSize(requiredOutputs))})',
    );
    built++;
  }

  stdout.writeln(
    'spawn:build: $built built, $skipped up to date'
    '${failures > 0 ? ', $failures failed' : ''}',
  );
  if (failures > 0) exitCode = 1;
}

class _Options {
  _Options(
    this.input,
    this.output,
    this.target,
    this.only,
    this.force,
    this.verbose,
    this.help,
  );

  factory _Options.parse(List<String> arguments) {
    var input = 'lib/workers';
    String? output;
    var target = _Target.js;
    Set<String>? only;
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
        case '--target':
          if (i + 1 < arguments.length) {
            target = _parseTarget(arguments[++i]);
          }
        case '--only':
          if (i + 1 < arguments.length) {
            only = arguments[++i].split(',').toSet();
          }
        case '-o':
        case '--output':
          if (i + 1 < arguments.length) output = arguments[++i];
        default:
          if (argument.startsWith('--output=')) {
            output = argument.substring('--output='.length);
          } else if (argument.startsWith('--target=')) {
            target = _parseTarget(argument.substring('--target='.length));
          } else if (argument.startsWith('--only=')) {
            only = argument.substring('--only='.length).split(',').toSet();
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
      target,
      only,
      force,
      verbose,
      help,
    );
  }

  final String input;
  final String output;
  final _Target target;
  final Set<String>? only;
  final bool force;
  final bool verbose;
  final bool help;
}

enum _Target { js, wasm, hybrid }

_Target _parseTarget(String value) => switch (value) {
  'js' => _Target.js,
  'wasm' => _Target.wasm,
  'hybrid' => _Target.hybrid,
  _ => throw ArgumentError.value(value, 'target', 'Must be js, wasm or hybrid'),
};

String _stem(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final slash = normalized.lastIndexOf('/');
  final name = slash < 0 ? normalized : normalized.substring(slash + 1);
  return name.substring(0, name.length - '.dart'.length);
}

String _fileName(String path) => path.replaceAll(r'\', '/').split('/').last;

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

int _hashString(String value) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

int _totalSize(Iterable<File> files) => files.fold<int>(
  0,
  (total, file) => total + (file.existsSync() ? file.lengthSync() : 0),
);

String _wasmBootstrap(String stem, {bool fallback = false}) =>
    '''
// Generated by spawn:build --target ${fallback ? 'hybrid' : 'wasm'}. Do not edit.
(() => {
  const pending = [];
  let dartOnMessage = null;

  self.onmessage = (event) => {
    if (dartOnMessage === null) {
      pending.push(event);
    } else {
      dartOnMessage(event);
    }
  };

  async function boot() {
    ${fallback ? '''
    // Probe the GC and SIMD features emitted by dart2wasm before fetching a
    // large payload. A failed probe goes straight to the compiled JS worker.
    if (typeof WebAssembly === 'undefined' ||
        !WebAssembly.validate(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,95,1,120,0])) ||
        !WebAssembly.validate(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,123,3,2,1,0,10,10,1,8,0,65,0,253,15,253,98,11]))) {
      throw new Error('spawn: Dart Wasm worker features unavailable');
    }
    ''' : ''}
    const loader = await import('./$stem.dart.mjs');
    const response = await fetch('./$stem.dart.wasm');
    if (!response.ok) {
      throw new Error(
        `spawn: failed to fetch Wasm worker payload (\${response.status})`,
      );
    }

    let compiled;
    try {
      compiled = await loader.compileStreaming(Promise.resolve(response.clone()));
    } catch (_) {
      // Servers should send application/wasm. Falling back to bytes keeps
      // local and embedded asset servers usable without weakening the worker
      // boundary.
      compiled = await loader.compile(await response.arrayBuffer());
    }
    const app = await compiled.instantiate({});
    app.invokeMain();

    dartOnMessage = self.onmessage;
    if (typeof dartOnMessage !== 'function') {
      throw new Error('spawn: Wasm worker did not install an onmessage handler');
    }
    for (const event of pending.splice(0)) dartOnMessage(event);
  }

  boot().catch((error) => {
    ${fallback ? '''
    try {
      // The JS payload is a separate compilation of this worker. It installs
      // its own onmessage handler; replay messages queued while Wasm started.
      importScripts('./$stem.dart.fallback.js');
      dartOnMessage = self.onmessage;
      if (typeof dartOnMessage !== 'function') {
        throw new Error('spawn: JS fallback did not install an onmessage handler');
      }
      for (const event of pending.splice(0)) dartOnMessage(event);
      return;
    } catch (fallbackError) {
      error = fallbackError;
    }
    ''' : ''}
    // A thrown worker error reaches Worker.onerror, which spawn reports as a
    // payload startup failure. An unhandled rejected Promise does not do so
    // consistently across browsers.
    setTimeout(() => { throw error; }, 0);
  });
})();
''';

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} kB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _indent(String text) => text.isEmpty
    ? ''
    : text.split('\n').map((line) => '      $line').join('\n');
