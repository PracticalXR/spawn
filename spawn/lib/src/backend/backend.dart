/// Selects the backend for the platform being compiled for.
///
/// `dart.library.js_interop` is only available to dart2js and dart2wasm, so
/// the VM, AOT and Flutter native builds take the isolate backend and never
/// see the web one - and the reverse.
library;

export 'native.dart'
    if (dart.library.js_interop) 'web.dart'
    show connect, platformCaps, runWorkerEntrypoint;
