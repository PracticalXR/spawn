# spawn

Background execution for Dart that works everywhere: isolates on native, Web
Workers on the web, one API.

| Package | Description |
|---|---|
| [`spawn`](spawn/) | The core package. Pure Dart, zero runtime dependencies. |

Planned siblings, not yet implemented:

| Package | Description |
|---|---|
| `spawn_flutter` | Platform `ServiceProvider`s — the Android foreground service host and the iOS background session. Ships as a Flutter plugin because that is the only way Kotlin service classes and manifest entries reach an app build. |
| `spawn_jobs` | Deferred, OS-scheduled work (`WorkManager` / `BGTaskScheduler`). `JobEntry` already parses in `spawn` so worker files need no migration. |

See [spawn/README.md](spawn/README.md) to get started, and
[spawn/doc/wire_format.md](spawn/doc/wire_format.md) for the byte format every
message has, whether or not the bytes are produced.

## Development

```console
$ cd spawn
$ dart pub get
$ dart analyze                        # zero infos is the bar
$ dart test                           # VM
$ dart run spawn:build test/workers   # build the browser payload first
$ dart test -p chrome                 # browser
```

The browser suite needs its worker payload compiled before it runs. That is
not a quirk of the tests — it is the same step any app takes, and running the
suite without it is how you find out the debug fallback works.

## License

MIT
