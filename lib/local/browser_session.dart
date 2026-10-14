import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// Uses only an app-owned Chrome profile, never the user's default profile.
class BrowserSession {
  final Directory profile;
  final String? executable;
  bool headless;
  bool _mobile = true;
  final Duration requestGap;
  WebSocket? _socket;
  Process? _process;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  DateTime? _lastRequest;
  final Map<String, _ImageCapture> _imageByUrl = {};
  final Map<String, _ImageCapture> _imageByRequest = {};
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
    _mobile = mobile;
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
    var startupDiagnostics = '';
    _process!.stderr.listen((bytes) {
      startupDiagnostics += utf8.decode(bytes, allowMalformed: true);
      if (startupDiagnostics.length > 4096) {
        startupDiagnostics = startupDiagnostics.substring(startupDiagnostics.length - 4096);
      }
    });
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await activePort.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Chrome 启动超时（45 秒）。请关闭下载器专用 Chrome 后重试。'
              '${startupDiagnostics.isEmpty ? "" : "\nChrome 启动诊断: $startupDiagnostics"}');
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
          _captureImageEvent(message);
          _events.add(message);
        }
      }, onDone: () {
        _socket = null;
        _failPending(StateError('下载器 Chrome 已关闭；缓存已保留，可重启继续。'));
      }, onError: (Object error) {
        _failPending(StateError('Chrome 连接断开，缓存已保留。'));
      });
      await command('Page.enable');
      await command('Network.enable', {
        'maxTotalBufferSize': 64 * 1024 * 1024,
        'maxResourceBufferSize': 30 * 1024 * 1024,
      });
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
    stdout.writeln('正在打开 Chrome 验证窗口，请稍候...');
    await start();
    await readHtml(url);
    stdout.writeln('\n已打开下载器专用 Chrome（登录状态保存在本机）。');
    stdout.writeln('请在这个窗口登录哔哩轻小说，并完成网页要求的验证。');
    stdout.writeln('普通 Chrome 中 linovelib.com 的登录不会自动转到 bilinovel.com。');
    stdout.writeln('确认窗口内能正常阅读后，回到这里按 Enter 继续。');
    stdin.readLineSync();
    stdout.writeln('验证完成，正在关闭可见窗口并切换后台 headless 下载...');
    await restartHeadless(url);
  }

  Future<void> restartHeadless(String url) async {
    final urls = <String>{url, ..._imageByUrl.keys.take(32)};
    // Preserve session-only cookies in memory when closing the verification window.
    final response = await command('Network.getCookies', {'urls': urls.toList()});
    final cookies = (response['cookies'] as List<dynamic>? ?? []).map((cookie) {
      final source = Map<String, dynamic>.from(cookie as Map);
      return <String, dynamic>{
        for (final key in ['name', 'value', 'domain', 'path', 'secure',
          'httpOnly', 'sameSite', 'expires', 'priority', 'sourceScheme',
          'sourcePort', 'partitionKey'])
          if (source.containsKey(key)) key: source[key],
      };
    }).toList();
    final mobile = _mobile;
    await close();
    headless = true;
    await start(mobile: mobile);
    if (cookies.isNotEmpty) await command('Network.setCookies', {'cookies': cookies});
    // Confirm the new browser can render the target before starting the job.
    await readHtml(url);
    stdout.writeln('已切换后台下载，不会再显示 Chrome 窗口。');
  }

  void _captureImageEvent(Map<String, dynamic> event) {
    final params = event['params'] as Map<String, dynamic>?;
    if (params == null) return;
    final id = params['requestId'] as String?;
    if (id == null) return;
    if (event['method'] == 'Network.requestWillBeSent' && params['type'] == 'Image') {
      final url = params['request']['url'] as String;
      final capture = _imageByRequest.putIfAbsent(id, () => _ImageCapture(id));
      _imageByUrl[url] = capture;
    } else if (event['method'] == 'Network.responseReceived' && params['type'] == 'Image') {
      final response = params['response'] as Map<String, dynamic>;
      final capture = _imageByRequest.putIfAbsent(id, () => _ImageCapture(id));
      capture.status = (response['status'] as num).toInt();
      _imageByUrl[response['url'] as String] = capture;
    } else if (event['method'] == 'Network.loadingFinished') {
      final capture = _imageByRequest.remove(id);
      if (capture != null) unawaited(_captureImageBody(capture));
    } else if (event['method'] == 'Network.loadingFailed') {
      final capture = _imageByRequest.remove(id);
      if (capture != null && !capture.body.isCompleted) capture.body.complete(null);
    }
    // Keep a bounded window of rendered images across paginated chapter pages.
    while (_imageByUrl.length > 32) {
      _imageByUrl.remove(_imageByUrl.keys.first);
    }
  }

  Future<void> _captureImageBody(_ImageCapture capture) async {
    Uint8List? data;
    try {
      if (capture.status != null && capture.status! >= 200 && capture.status! < 300) {
        final response = await command('Network.getResponseBody', {'requestId': capture.id});
        final body = response['body'] as String? ?? '';
        // Image bodies must be decoded as bytes; never UTF-8 encode binary response text.
        if (response['base64Encoded'] == true) {
          data = base64Decode(body);
          if (data.isEmpty || data.length > 30 * 1024 * 1024) data = null;
        }
      }
    } catch (_) { /* A navigated-away response may have been evicted from Chrome. */ }
    if (!capture.body.isCompleted) capture.body.complete(data);
  }

  Future<Uint8List> readImage(String url) async {
    final uri = Uri.parse(url);
    if (!['http', 'https'].contains(uri.scheme)) {
      throw ArgumentError('不支持的图片地址。');
    }
    final previouslyLoaded = _imageByUrl[url];
    if (previouslyLoaded != null) {
      final bytes = await previouslyLoaded.body.future
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (bytes != null) return bytes;
    }
    await _pace();
    // Load a real <img> inside the current chapter. Chrome supplies that page's
    // Referer, cookies and normal image-request headers, without CORS fetch access.
    _imageByUrl.remove(url);
    await command('Network.setCacheDisabled', {'cacheDisabled': true});
    try {
      final loaded = await evaluate('''
        new Promise(resolve => {
          const image = new Image();
          image.referrerPolicy = 'unsafe-url';
          image.style.display = 'none';
          let done = false;
          const finish = value => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            image.remove();
            resolve(value);
          };
          const timer = setTimeout(() => {
            image.src = '';
            finish(false);
          }, 30000);
          image.onload = () => finish(true);
          image.onerror = () => finish(false);
          document.body.appendChild(image);
          image.src = ${jsonEncode(url)};
        })
      ''');
      final capture = _imageByUrl[url];
      if (loaded != true || capture == null) {
        throw StateError('图片在章节页面内加载失败，HTTP ${capture?.status ?? "未知"}。'
            '请重新运行并在验证窗口确认插图可见；如果网站也无法显示，请等待恢复。');
      }
      final bytes = await capture.body.future
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (bytes == null) throw StateError('图片响应不可读取或超过 30 MB。');
      return bytes;
    } finally {
      await command('Network.setCacheDisabled', {'cacheDisabled': false});
    }
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
    for (final capture in _imageByRequest.values) {
      if (!capture.body.isCompleted) capture.body.complete(null);
    }
    _imageByRequest.clear();
    _imageByUrl.clear();
    _lastRequest = null;
    _failPending(StateError('下载器已退出。'));
    final activePort = File(p.join(profile.path, 'DevToolsActivePort'));
    if (await activePort.exists()) await activePort.delete();
  }
}

class _ImageCapture {
  final String id;
  int? status;
  final Completer<Uint8List?> body = Completer<Uint8List?>();
  _ImageCapture(this.id);
}
