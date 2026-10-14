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
  final Duration pageTimeout;
  final Duration resourceGrace;
  String? _activeUrl;
  bool _dialogGate = false;
  bool _handlingPermission = false;
  final Future<void> Function(BrowserSession, String)? permissionHandler;
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
    this.pageTimeout = const Duration(seconds: 35),
    this.resourceGrace = const Duration(seconds: 6),
    this.permissionHandler,
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
          if (message['method'] == 'Page.javascriptDialogOpening') {
            final prompt = message['params']?['message']?.toString() ?? '';
            _dialogGate = _looksLikeReadingPermission(prompt);
            if (_dialogGate && headless && !_handlingPermission) {
              _failPending(_ReadingPermissionRequired());
            }
          } else if (message['method'] == 'Page.javascriptDialogClosed') {
            _dialogGate = false;
          }
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
      await command('Page.setLifecycleEventsEnabled', {'enabled': true});
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
      [Map<String, dynamic> params = const {},
      Duration timeout = const Duration(seconds: 45)]) async {
    final socket = _socket;
    if (socket == null) throw StateError('Chrome 未连接。');
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        throw TimeoutException('浏览器操作超时: $method (${timeout.inSeconds} 秒)'
            '${_activeUrl == null ? "" : "\n页面: $_activeUrl"}');
      });
    } finally {
      _pending.remove(id);
    }
  }

  Future<dynamic> evaluate(String expression,
      [Duration timeout = const Duration(seconds: 45)]) async {
    final response = await command('Runtime.evaluate', {
      'expression': expression, 'returnByValue': true, 'awaitPromise': true,
      'timeout': timeout.inMilliseconds,
    }, timeout);
    if (response['exceptionDetails'] != null) {
      final details = response['exceptionDetails'].toString();
      if (RegExp(r'timed out|timeout|terminated', caseSensitive: false).hasMatch(details)) {
        throw TimeoutException('浏览器 Runtime.evaluate 执行超时。页面: $_activeUrl');
      }
      throw StateError('浏览器 Runtime.evaluate 脚本执行失败。页面: $_activeUrl');
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

  Future<String> readHtml(String url, {bool verification = false}) async {
    _activeUrl = url;
    final attempts = verification ? 1 : 2;
    var failures = 0;
    var permissionPauses = 0;
    while (true) {
      try {
        return await _readHtmlOnce(url, verification: verification);
      } on _ReadingPermissionRequired {
        if (verification || _handlingPermission || permissionPauses >= 2) {
          throw StateError('阅读授权仍未生效。请在网站确认当前章节可阅读；缓存已保留。URL: $url');
        }
        permissionPauses++;
        await _handleReadingPermission(url);
        // User/ad waiting does not consume a network retry or a page timeout budget.
        failures = 0;
      } on TimeoutException catch (error) {
        if (_dialogGate && !verification) {
          permissionPauses++;
          if (permissionPauses > 2) rethrow;
          await _handleReadingPermission(url);
          continue;
        }
        try { await command('Page.stopLoading', {}, const Duration(seconds: 5)); }
        catch (_) {}
        try { await command('Runtime.terminateExecution', {}, const Duration(seconds: 3)); }
        catch (_) {}
        failures++;
        if (failures >= attempts) {
          throw TimeoutException('页面自动重试后仍失败。\n$error');
        }
        stdout.writeln('页面暂时超时，自动重试 1 次: $url\n$error');
        await Future<void>.delayed(const Duration(seconds: 3));
      } on _PageNetworkFailure catch (error) {
        failures++;
        if (failures >= attempts) rethrow;
        stdout.writeln('页面连接暂时失败，自动重试 1 次: $url\n$error');
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  Future<String> _readHtmlOnce(String url, {required bool verification}) async {
    await _pace();
    final stages = <String, Set<String>>{};
    final statuses = <String, int>{};
    final subscription = _events.stream.listen((e) {
      final params = e['params'] as Map<String, dynamic>?;
      if (params == null) return;
      final loader = params['loaderId'] as String?;
      if (loader == null) return;
      if (e['method'] == 'Page.lifecycleEvent') {
        stages.putIfAbsent(loader, () => {}).add(params['name'] as String);
      }
      if (e['method'] == 'Network.responseReceived' && params['type'] == 'Document') {
        statuses[loader] = (params['response']['status'] as num).toInt();
      }
    });
    try {
      final result = await command('Page.navigate', {'url': url}, pageTimeout);
      if (result['errorText'] != null) {
        throw _PageNetworkFailure('页面连接失败: ${result['errorText']}。URL: $url');
      }
      if (!verification && _dialogGate) throw _ReadingPermissionRequired();
      final loader = result['loaderId'] as String?;
      final deadline = DateTime.now().add(pageTimeout);
      while (loader != null &&
          !(stages[loader]?.contains('DOMContentLoaded') ?? false)) {
        if (!verification) await _throwIfReadingPermission();
        final status = statuses[loader];
        _requirePageStatus(status, url);
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('等待正文 DOM 就绪超时。URL: $url，HTTP: ${status ?? "未收到"}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      _requirePageStatus(loader == null ? null : statuses[loader], url);
      if (!verification) {
        await _throwIfReadingPermission();
        final grace = DateTime.now().add(resourceGrace);
        while (!(stages[loader]?.contains('load') ?? false)) {
          await _throwIfReadingPermission();
          if (await evaluate('document.readyState', const Duration(seconds: 5)) == 'complete') break;
          if (DateTime.now().isAfter(grace)) {
            // Preserve illustration URLs, then release load handlers from hung resources.
            // Never synthesize a load event: that could shuffle the chapter twice.
            await evaluate('''(() => {
              for (const image of document.images) {
                if (!image.complete) {
                  if (!image.hasAttribute('data-src') && image.getAttribute('src')) {
                    image.setAttribute('data-src', image.getAttribute('src'));
                  }
                  image.removeAttribute('srcset');
                  image.removeAttribute('src');
                }
              }
            })()''', const Duration(seconds: 5));
            await command('Page.stopLoading', {}, const Duration(seconds: 5));
            final stoppedDeadline = DateTime.now().add(const Duration(seconds: 5));
            while (await evaluate('document.readyState', const Duration(seconds: 5)) != 'complete') {
              if (DateTime.now().isAfter(stoppedDeadline)) {
                throw TimeoutException('正文已到达，但页面脚本收尾未完成。URL: $url');
              }
              await Future<void>.delayed(const Duration(milliseconds: 150));
            }
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      // Site post-load paragraph/font scripts get time to complete; images download separately.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!verification) await _throwIfReadingPermission();
      if (verification) {
        return await evaluate('document.documentElement.outerHTML',
            const Duration(seconds: 10)) as String;
      }
      return await _snapshotReadableHtml();
    } finally {
      await subscription.cancel();
    }
  }

  // outerHTML includes CSS-hidden bait paragraphs. Export a clone after consulting
  // live computed styles; never deduplicate by text or modify the site's live DOM.
  Future<String> _snapshotReadableHtml() async {
    final result = await evaluate(r'''(() => {
      const copy = document.documentElement.cloneNode(true);
      const root = document.querySelector('#acontent') || document.querySelector('.bcontent');
      if (!root) return {html: copy.outerHTML};
      const target = copy.querySelector('#acontent') || copy.querySelector('.bcontent');
      const paragraphs = Array.from(root.querySelectorAll('p'));
      const copies = Array.from(target.querySelectorAll('p'));
      const keyed = paragraphs.some(p => Array.from(p.attributes).some(a => /^data-k\d+$/.test(a.name)));
      if (keyed && Array.from(document.querySelectorAll('link[rel~="stylesheet"]'))
          .some(link => !link.disabled && !link.sheet)) {
        return {error: '正文样式尚未加载，无法区分隐藏副本；已停止保存该章，请稍后重试。'};
      }
      function hidden(p) {
        for (let e = p; e && e !== root; e = e.parentElement) {
          const s = getComputedStyle(e);
          if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse'
              || Number(s.opacity) === 0) return true;
          if (s.transform !== 'none') {
            const m = new DOMMatrixReadOnly(s.transform);
            if (m.m11 === 0 && m.m12 === 0 && m.m21 === 0 && m.m22 === 0) return true;
          }
        }
        return false;
      }
      paragraphs.forEach((p, i) => {
        // Lazy illustrations and off-screen text must remain in the book.
        if (!p.querySelector('img,svg,video') && hidden(p)) copies[i].remove();
      });
      target.setAttribute('data-bili-rendered', 'visible-v1');
      return {html: copy.outerHTML};
    })()''', const Duration(seconds: 10)) as Map;
    if (result['error'] != null) throw StateError(result['error'] as String);
    return result['html'] as String;
  }

  void _requirePageStatus(int? status, String url) {
    if (status == 429) throw StateError('网站限流（HTTP 429），请等待后继续。URL: $url');
    if (status == 401 || status == 403) {
      throw StateError('网站拒绝当前会话（HTTP $status），请重新运行并在验证窗口确认可阅读。URL: $url');
    }
    if (status != null && status >= 500) {
      throw _PageNetworkFailure('网站服务器错误（HTTP $status）。URL: $url');
    }
  }

  static bool _looksLikeReadingPermission(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    return RegExp(r'(观看|觀看|播放|看).{0,12}(广告|廣告)', caseSensitive: false)
        .hasMatch(compact) &&
        RegExp(r'阅读权限|閱讀權限|浏览权限|瀏覽權限|权限|權限|解锁|解鎖|继续|繼續|获得|獲得')
            .hasMatch(compact);
  }

  Future<bool> hasReadingPermissionGate() async {
    if (_dialogGate) return true;
    return await evaluate(r'''(() => {
      const gateWords = text => {
        const t = text.replace(/\s+/g, '');
        return /(观看|觀看|播放|看).{0,12}(广告|廣告)/i.test(t) &&
          /阅读权限|閱讀權限|浏览权限|瀏覽權限|权限|權限|解锁|解鎖|继续|繼續|获得|獲得/.test(t);
      };
      const visible = element => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          element.getAttribute('aria-hidden') !== 'true' && rect.width > 0 && rect.height > 0;
      };
      const candidates = document.querySelectorAll(
        'dialog[open],[role="dialog"],.layui-layer,.swal2-popup,.van-popup,' +
        '.ant-modal,.el-dialog,.modal,.popup,.dialog,[class*="overlay"],[class*="mask"]');
      for (const element of candidates) {
        if (visible(element) && gateWords(element.innerText || element.textContent || '')) return true;
      }
      // Custom fixed modals need not use a standard dialog class.
      for (const element of document.querySelectorAll('body *')) {
        const text = element.innerText || '';
        if (text.length > 1500 || !gateWords(text) || !visible(element)) continue;
        const style = getComputedStyle(element);
        if (style.position === 'fixed' || Number(style.zIndex) >= 1000) return true;
      }
      const content = document.querySelector('#acontent,.bcontent');
      if (content && visible(content) && (content.innerText || '').length < 1000 &&
          gateWords(content.innerText || '') &&
          content.querySelectorAll('p').length < 3) return true;
      return false;
    })()''', const Duration(seconds: 5)) == true;
  }

  Future<void> _throwIfReadingPermission() async {
    if (await hasReadingPermissionGate()) throw _ReadingPermissionRequired();
  }

  Future<void> _navigateForVerification(String url) async {
    _activeUrl = url;
    try {
      await command('Page.navigate', {'url': url}, const Duration(seconds: 10));
    } on TimeoutException {
      // Keep the browser/video alive; the user is not subject to the download timer.
      stdout.writeln('验证页面仍在载入，请在 Chrome 中操作，完成后再回到终端。');
    }
  }

  Future<void> _confirmReadable(String url) async {
    while (true) {
      stdout.writeln('请完成登录或网站要求的广告观看。等待多久都不会触发下载超时。');
      stdout.writeln('确认原章节已经可阅读后按 Enter 继续；输入 q 保存进度并退出。');
      if (stdin.readLineSync()?.trim().toLowerCase() == 'q') {
        throw StateError('用户暂停下载，缓存已保留。');
      }
      // Drain Chrome events accumulated while stdin was waiting.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await hasReadingPermissionGate()) return;
      stdout.writeln('当前仍检测到阅读授权提示，暂不关闭验证窗口。');
    }
  }

  Future<void> _handleReadingPermission(String url) async {
    if (_handlingPermission) throw _ReadingPermissionRequired();
    _handlingPermission = true;
    stdout.writeln('\n检测到观看广告/阅读授权。已暂停下载，当前章节不会标记为完成。');
    try {
      if (permissionHandler != null) {
        await permissionHandler!(this, url);
        return;
      }
      // Decline the headless JS prompt only to hand it over to a visible browser.
      // This does not grant access or click an advertisement.
      if (_dialogGate) {
        try { await command('Page.handleJavaScriptDialog', {'accept': false}); }
        catch (_) {}
        _dialogGate = false;
      }
      await _restartBrowser(url, nextHeadless: false);
      await _navigateForVerification(url);
      stdout.writeln('已打开原章节，请手动完成网站广告授权；广告页可由你自行打开/关闭。');
      await _confirmReadable(url);
      await _restartBrowser(url, nextHeadless: true);
      stdout.writeln('授权确认完成，恢复 headless 下载。');
    } finally {
      _handlingPermission = false;
    }
  }

  Future<void> prepareLogin(String url) async {
    stdout.writeln('正在打开 Chrome 验证窗口，请稍候...');
    await start();
    await _navigateForVerification(url);
    stdout.writeln('\n已打开下载器专用 Chrome（登录状态保存在本机）。');
    stdout.writeln('普通 Chrome 中 linovelib.com 的登录不会自动转到 bilinovel.com。');
    await _confirmReadable(url);
    await restartHeadless(url);
  }

  Future<void> _restartBrowser(String url, {required bool nextHeadless}) async {
    final urls = <String>{url, ..._imageByUrl.keys.take(32)};
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
    final origin = Uri.parse(url).origin;
    var session = <String, String>{};
    try {
      final snapshot = await evaluate(r'''(() => ({
        origin: location.origin,
        entries: Object.entries(sessionStorage)
      }))()''', const Duration(seconds: 5));
      if (snapshot is Map && snapshot['origin'] == origin) {
        for (final entry in snapshot['entries'] as List<dynamic>) {
          session[entry[0] as String] = entry[1] as String;
        }
      }
    } catch (_) { /* Cookies/profile remain available if storage is inaccessible. */ }
    final mobile = _mobile;
    await close();
    headless = nextHeadless;
    await start(mobile: mobile);
    if (cookies.isNotEmpty) await command('Network.setCookies', {'cookies': cookies});
    if (session.isNotEmpty) {
      await command('Page.addScriptToEvaluateOnNewDocument', {'source': '''
        (() => {
          if (location.origin !== ${jsonEncode(origin)}) return;
          const entries = ${jsonEncode(session)};
          for (const [key, value] of Object.entries(entries)) {
            if (sessionStorage.getItem(key) === null) sessionStorage.setItem(key, value);
          }
        })();
      '''});
    }
  }

  Future<void> restartHeadless(String url) async {
    await _restartBrowser(url, nextHeadless: true);
    await readHtml(url);
    stdout.writeln('已切换后台下载；仅遇到网站要求的人工授权时会暂停打开验证窗口。');
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
    for (var pause = 0; pause < 3; pause++) {
      try {
        await _throwIfReadingPermission();
        return await _readImageOnce(url);
      } on _ReadingPermissionRequired {
        final chapterUrl = _activeUrl;
        if (pause >= 2 || chapterUrl == null) rethrow;
        await _handleReadingPermission(chapterUrl);
        await readHtml(chapterUrl);
      }
    }
    throw StateError('图片阅读授权未生效。');
  }

  Future<Uint8List> _readImageOnce(String url) async {
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
    _dialogGate = false;
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

class _PageNetworkFailure implements Exception {
  final String message;
  _PageNetworkFailure(this.message);
  @override
  String toString() => message;
}

class _ReadingPermissionRequired implements Exception {
  @override
  String toString() => '网站要求观看广告或确认阅读授权，下载已暂停。';
}
