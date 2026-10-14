import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// Uses only an app-owned Chrome profile, never the user's default profile.
class BrowserSession {
  final Directory profile;
  final String? executable;
  final bool headless;
  final Duration requestGap;
  WebSocket? _socket;
  Process? _process;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  DateTime? _lastRequest;
  String? _frameId;
  bool get connected => _socket != null;

  BrowserSession({
    Directory? profile,
    this.executable,
    this.headless = false,
    this.requestGap = const Duration(seconds: 4),
  }) : profile = profile ?? Directory(p.join(
      Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['HOME'] ?? Directory.current.path,
      'BiliNovelPacker', 'browser-profile'));

  static String findChrome() {
    final override = Platform.environment['BILI_CHROME'];
    final candidates = [
      if (override != null) override,
      if (Platform.isWindows) ...[
        p.join(Platform.environment['PROGRAMFILES'] ?? r'C:\Program Files',
            'Google', 'Chrome', 'Application', 'chrome.exe'),
        p.join(Platform.environment['PROGRAMFILES(X86)'] ?? r'C:\Program Files (x86)',
            'Google', 'Chrome', 'Application', 'chrome.exe'),
        p.join(Platform.environment['LOCALAPPDATA'] ?? '',
            'Google', 'Chrome', 'Application', 'chrome.exe'),
      ],
      if (Platform.isMacOS)
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      if (Platform.isLinux) ...[
        '/usr/bin/google-chrome', '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
      ],
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    throw StateError('找不到 Chrome。请安装 Chrome，或设置 BILI_CHROME 为 chrome.exe 路径。');
  }

  Future<void> start({bool mobile = true}) async {
    if (connected) return;
    await profile.create(recursive: true);
    final activePort = File(p.join(profile.path, 'DevToolsActivePort'));
    if (await activePort.exists()) {
      throw StateError('下载器专用 Chrome 尚未关闭。请关闭该窗口后重试；'
          '如已关闭，可删除专用目录中的 DevToolsActivePort 文件。');
    }
    _process = await Process.start(executable ?? findChrome(), [
      '--user-data-dir=${profile.absolute.path}',
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=0',
      '--no-first-run', '--no-default-browser-check',
      if (headless) '--headless=new',
      'about:blank',
    ]);
    _process!.stdout.drain<void>();
    _process!.stderr.drain<void>();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!await activePort.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Chrome 启动超时。请关闭下载器专用 Chrome 后重试。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final lines = await activePort.readAsLines();
      final port = int.parse(lines.first);
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      late List<dynamic> targets;
      try {
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
        final response = await request.close();
        targets = jsonDecode(await utf8.decoder.bind(response).join()) as List;
      } finally {
        client.close(force: true);
      }
      final target = targets.firstWhere((t) => t['type'] == 'page');
      final ws = Uri.parse(target['webSocketDebuggerUrl'] as String);
      if (!['127.0.0.1', 'localhost'].contains(ws.host)) {
        throw StateError('Chrome 调试连接必须为本机地址。');
      }
      _socket = await WebSocket.connect(ws.toString())
          .timeout(const Duration(seconds: 5));
      _socket!.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = message['id'];
        if (id is int) {
          final completer = _pending.remove(id);
          if (completer == null) return;
          if (message['error'] != null) {
            completer.completeError(StateError(
                'Chrome 命令失败: ${message['error']['message']}'));
          } else {
            completer.complete(Map<String, dynamic>.from(message['result'] ?? {}));
          }
        } else {
          _events.add(message);
        }
      }, onDone: () {
        _socket = null;
        _failPending(StateError('下载器 Chrome 已关闭；缓存已保留，可重启继续。'));
      }, onError: (Object error) {
        _failPending(StateError('Chrome 连接断开，缓存已保留。'));
      });
      await command('Page.enable');
      await command('Network.enable');
      if (mobile) {
        final version = await command('Browser.getVersion');
        final ua = (version['userAgent'] as String)
            .replaceAll('HeadlessChrome', 'Chrome')
            .replaceFirst(RegExp(r'\([^)]*\)'), '(Linux; Android 13; Mobile)');
        await command('Network.setUserAgentOverride', {
          'userAgent': '$ua Mobile', 'platform': 'Android',
        });
        await command('Emulation.setDeviceMetricsOverride', {
          'width': 430, 'height': 900, 'deviceScaleFactor': 1, 'mobile': true,
        });
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> command(String method,
      [Map<String, dynamic> params = const {}]) async {
    final socket = _socket;
    if (socket == null) throw StateError('Chrome 未连接。');
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } finally {
      _pending.remove(id);
    }
  }

  Future<dynamic> evaluate(String expression) async {
    final response = await command('Runtime.evaluate', {
      'expression': expression, 'returnByValue': true, 'awaitPromise': true,
    });
    if (response['exceptionDetails'] != null) {
      throw StateError('页面脚本执行失败。');
    }
    return response['result']?['value'];
  }

  Future<void> _pace() async {
    final last = _lastRequest;
    if (last != null) {
      final wait = requestGap - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
  }

  Future<String> readHtml(String url) async {
    await _pace();
    final loaded = Completer<void>();
    int? mainStatus;
    final subscription = _events.stream.listen((e) {
      if (e['method'] == 'Network.responseReceived' && e['params']?['type'] == 'Document') {
        mainStatus = (e['params']['response']['status'] as num).toInt();
      }
      if (e['method'] == 'Page.loadEventFired' && !loaded.isCompleted) {
        loaded.complete();
      }
    });
    try {
      final result = await command('Page.navigate', {'url': url});
      if (result['errorText'] != null) {
        throw StateError('页面连接失败: ${result['errorText']}');
      }
      _frameId = result['frameId'] as String?;
      await loaded.future.timeout(const Duration(seconds: 45));
      if (mainStatus == 429) throw StateError('网站限流（HTTP 429）。请等待后再运行，缓存已保留。');
      if (mainStatus != null && mainStatus! >= 500) {
        throw StateError('网站服务器错误（HTTP $mainStatus），请稍后重试。');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      return await evaluate('document.documentElement.outerHTML') as String;
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> prepareLogin(String url) async {
    await start();
    await readHtml(url);
    stdout.writeln('\n已打开下载器专用 Chrome（登录状态保存在本机）。');
    stdout.writeln('请在这个窗口登录哔哩轻小说，并完成网页要求的验证。');
    stdout.writeln('普通 Chrome 中 linovelib.com 的登录不会自动转到 bilinovel.com。');
    stdout.writeln('确认窗口内能正常阅读后，回到这里按 Enter 继续。');
    stdin.readLineSync();
  }

  Future<Uint8List> readImage(String url) async {
    await _pace();
    final result = await command('Network.loadNetworkResource', {
      'frameId': _frameId,
      'url': url,
      'options': {'disableCache': false, 'includeCredentials': true},
    });
    final resource = result['resource'] as Map<String, dynamic>;
    final stream = resource['stream'] as String?;
    if (resource['success'] != true || stream == null) {
      throw StateError('图片请求失败，HTTP ${resource['httpStatusCode']}');
    }
    final bytes = BytesBuilder(copy: false);
    try {
      while (true) {
        final chunk = await command('IO.read', {'handle': stream, 'size': 65536});
        final data = chunk['data'] as String? ?? '';
        bytes.add(chunk['base64Encoded'] == true ? base64Decode(data) : utf8.encode(data));
        if (bytes.length > 30 * 1024 * 1024) {
          throw StateError('单张图片超过 30 MB，已跳过。');
        }
        if (chunk['eof'] == true) break;
      }
    } finally {
      await command('IO.close', {'handle': stream});
    }
    return bytes.takeBytes();
  }

  Future<void> close() async {
    final socket = _socket;
    if (socket != null) {
      try { await command('Browser.close').timeout(const Duration(seconds: 3)); }
      catch (_) { /* Chrome may disconnect before responding. */ }
      await socket.close();
    }
    _socket = null;
    final process = _process;
    if (process != null) {
      try { await process.exitCode.timeout(const Duration(seconds: 5)); }
      catch (_) { process.kill(); }
    }
    _process = null;
    _failPending(StateError('下载器已退出。'));
    final activePort = File(p.join(profile.path, 'DevToolsActivePort'));
    if (await activePort.exists()) await activePort.delete();
  }
}
