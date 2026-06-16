import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../replay_channel.dart';

/// Captures `dart:io` HTTP traffic and forwards a metadata record per request
/// to the native engine.
///
/// Why this exists: the native SDKs intercept OkHttp / URLSession, but Dart's
/// `HttpClient` (and `package:http` / Dio, which sit on top of it) opens its
/// own sockets — that traffic is invisible to the native interceptors. So we
/// install an [HttpOverrides] that wraps every client and records the
/// method / url / status / duration (and redacted headers) once the response
/// arrives.
///
/// Safety: the response body is teed through a [StreamView] pass-through (see
/// [_RecordingHttpClientResponse]) — a capped copy is retained while every byte
/// flows to the host unchanged, so it cannot truncate or corrupt the host app's
/// HTTP. Body capture is gated by the workspace's `captureNetworkBodies` toggle
/// on the native side. It's opt-in (`ReplayConfig.recordNetwork`, default off),
/// and requests to the ingest host are skipped so the SDK never records its own
/// uploads.
class ReplayNetworkCapture {
  ReplayNetworkCapture._();

  static bool _installed = false;

  /// Header names that are redacted to `[redacted]` rather than recorded.
  static const Set<String> _sensitiveHeaders = <String>{
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'www-authenticate',
    'x-api-key',
    'x-auth-token',
  };

  static void install({Set<String> ignoreHosts = const <String>{}}) {
    if (_installed) return;
    _installed = true;
    HttpOverrides.global =
        _ReplayHttpOverrides(HttpOverrides.current, ignoreHosts);
  }

  /// Test-only: a standalone override that wraps a *real* client (no previous
  /// override), so an integration test can drive real loopback traffic.
  @visibleForTesting
  static HttpOverrides debugOverrides(Set<String> ignoreHosts) =>
      _ReplayHttpOverrides(null, ignoreHosts);

  @visibleForTesting
  static void debugReset() => _installed = false;

  static Map<String, String> redactHeaders(HttpHeaders? headers) {
    final Map<String, String> out = <String, String>{};
    headers?.forEach((String name, List<String> values) {
      out[name] = _sensitiveHeaders.contains(name.toLowerCase())
          ? '[redacted]'
          : values.join(', ');
    });
    return out;
  }

  static void report({
    required String method,
    required Uri url,
    required int status,
    required int durationMs,
    HttpHeaders? requestHeaders,
    HttpHeaders? responseHeaders,
    String? responseBody,
  }) {
    // Fire-and-forget; never let recording throw into the caller's request.
    // The body is gated by the workspace's `captureNetworkBodies` toggle on the
    // native side (ReplayCore.sendNetwork), so it's dropped before leaving the
    // device when disabled.
    ReplayChannel.instance.invoke('recordNetwork', <String, dynamic>{
      'url': url.toString(),
      'method': method.toUpperCase(),
      'request': jsonEncode(<String, dynamic>{
        'headers': redactHeaders(requestHeaders),
      }),
      'response': jsonEncode(<String, dynamic>{
        'headers': redactHeaders(responseHeaders),
        'body': responseBody,
      }),
      'status': status,
      'durationMs': durationMs < 0 ? 0 : durationMs,
    });
  }
}

class _ReplayHttpOverrides extends HttpOverrides {
  _ReplayHttpOverrides(this._previous, this._ignoreHosts);

  final HttpOverrides? _previous;
  final Set<String> _ignoreHosts;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _RecordingHttpClient(inner, _ignoreHosts);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}

/// Wraps an [HttpClient], routing every request method through [openUrl] so a
/// single recording path covers them all. All non-request members forward to
/// the inner client unchanged.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this._inner, this._ignoreHosts);

  final HttpClient _inner;
  final Set<String> _ignoreHosts;

  Future<HttpClientRequest> _wrap(String method, Uri url,
      Future<HttpClientRequest> request) async {
    final HttpClientRequest req = await request;
    if (_ignoreHosts.contains(url.host)) return req; // skip our own uploads
    return _RecordingHttpClientRequest(req, method, url);
  }

  // ── Request methods (all funnel through openUrl/open) ────────────────────

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _wrap(method, url, _inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) {
    final Uri url = Uri(scheme: 'http', host: host, port: port, path: path);
    return openUrl(method, url);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);

  // ── Everything else forwards verbatim ────────────────────────────────────

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Wraps an [HttpClientRequest], timing the call and recording metadata when
/// the response arrives. The response object is returned untouched, so the
/// host reads the body exactly as it would without us.
class _RecordingHttpClientRequest implements HttpClientRequest {
  _RecordingHttpClientRequest(this._inner, this._method, this._url);

  final HttpClientRequest _inner;
  final String _method;
  final Uri _url;

  @override
  Future<HttpClientResponse> close() {
    final Stopwatch sw = Stopwatch()..start();
    final HttpHeaders requestHeaders = _inner.headers;
    return _inner.close().then((HttpClientResponse response) {
      sw.stop();
      // Wrap the response so we can tee a capped copy of the body as the host
      // reads it, then report once the stream completes. StreamView delegates
      // every Stream method to our teeing stream, so the host's consumption
      // (listen / transform / toList / pipe) is never altered or corrupted.
      return _RecordingHttpClientResponse(
        response, _method, _url, requestHeaders, sw.elapsedMilliseconds);
    });
  }

  @override
  Future<HttpClientResponse> get done => _inner.done;

  // ── HttpClientRequest surface ────────────────────────────────────────────

  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  // ── IOSink surface ───────────────────────────────────────────────────────

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}

/// Wraps an [HttpClientResponse] and tees a capped copy of the body as the host
/// reads it, reporting the full network record once the stream completes.
///
/// Extends [StreamView] so every `Stream` method (listen / transform / toList /
/// pipe / cast …) is delegated to the teeing stream — the host's body
/// consumption is byte-for-byte identical to the unwrapped response, and the
/// `finally` guarantees a report even if the host cancels mid-stream.
class _RecordingHttpClientResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _RecordingHttpClientResponse(
    this._inner,
    String method,
    Uri url,
    HttpHeaders requestHeaders,
    int durationMs,
  ) : super(_tee(_inner, method, url, requestHeaders, durationMs));

  final HttpClientResponse _inner;

  /// Max body bytes retained — keeps memory bounded on large downloads.
  static const int _cap = 8192;

  static Stream<List<int>> _tee(
    HttpClientResponse inner,
    String method,
    Uri url,
    HttpHeaders requestHeaders,
    int durationMs,
  ) async* {
    final List<int> bytes = <int>[];
    var reported = false;
    void report() {
      if (reported) return;
      reported = true;
      String? body;
      try {
        body = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        body = null;
      }
      ReplayNetworkCapture.report(
        method: method,
        url: url,
        status: inner.statusCode,
        durationMs: durationMs,
        requestHeaders: requestHeaders,
        responseHeaders: inner.headers,
        responseBody: body,
      );
    }

    try {
      await for (final List<int> chunk in inner) {
        final int remaining = _cap - bytes.length;
        if (remaining > 0) {
          bytes.addAll(
              chunk.length <= remaining ? chunk : chunk.sublist(0, remaining));
        }
        yield chunk;
      }
    } finally {
      // Fires on normal completion, error, or early cancellation by the host.
      report();
    }
  }

  // ── HttpClientResponse surface → inner ───────────────────────────────────
  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  int get contentLength => _inner.contentLength;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);
}
