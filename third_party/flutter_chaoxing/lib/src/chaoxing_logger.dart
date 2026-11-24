/// Sink for best-effort diagnostic messages emitted by the Chaoxing clients.
///
/// The official client logs non-fatal failures (a failed SSO hop, a profile
/// lookup that did not resolve) without surfacing them to the user. A pure Dart
/// package cannot call `debugPrint`, so the host application injects its own
/// sink — typically `debugPrint` in Flutter, or `print`/a logger in a CLI.
///
/// When null (the default) diagnostics are discarded.
typedef ChaoxingLogger = void Function(String message);
