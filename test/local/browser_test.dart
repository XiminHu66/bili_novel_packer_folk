import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:bili_novel_packer/local/browser_session.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_source.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';

void main() {
  test('real Chrome preserves CDN Referer, cached images and cookies through headless restart', () async {
    final profile = await Directory.systemTemp.createTemp('bili-browser-test');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final browser = BrowserSession(profile:profile, headless:true, requestGap:Duration.zero);
    final image = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=');
    final pageUrl = 'http://127.0.0.1:${server.port}/novel/1/1.html';
    final cdnUrl = 'http://127.0.0.1:${cdn.port}/image.png';
    var imageRequests = 0;
    cdn.listen((request) async {
      imageRequests++;
      if (request.headers.value('referer') != pageUrl) {
        request.response.statusCode = 403;
      } else if (!request.cookies.any((c) => c.name == 'session' && c.value == 'fixture')) {
        request.response.statusCode = 401;
      } else {
        // Intentionally omit Access-Control-Allow-Origin, as many image CDNs do.
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(image);
      }
      await request.response.close();
    });
    server.listen((request) async {
      if (request.uri.path == '/image.png') {
        if (!request.cookies.any((c) => c.name=='session' && c.value=='fixture')) {
          request.response.statusCode=401;
        } else {
          request.response.headers.contentType=ContentType('image','png');
          request.response.add(image);
        }
      } else {
        request.response.cookies.add(Cookie('session','fixture'));
        request.response.headers.contentType=ContentType.html;
        request.response.write('<html><body><div id="acontent"><p>Second</p><p>First</p></div>'
          '<script>window.addEventListener("load",()=>{'
          'document.querySelector("#acontent").innerHTML="<p>First</p><p>Second</p>";});</script>'
          '</body></html>');
      }
      await request.response.close();
    });
    try {
      await browser.start(mobile:false);
      final url = 'http://127.0.0.1:${server.port}/novel/1/1.html';
      final source = BiliNovelSource(browser:browser);
      final novel=Novel()..id='1'..title='T'..author='A'..status='';
      final volume=Volume('',Catalog(novel));
      final doc = await source.getNovelChapter(Chapter('T',url,volume));
      expect(doc.body!.querySelectorAll('p').map((p)=>p.text).toList(), ['First','Second']);
      // Reproduce the old downloader's 403: cookie inclusion does not provide Referer.
      final frames = await browser.command('Page.getFrameTree');
      final legacy = await browser.command('Network.loadNetworkResource', {
        'frameId': frames['frameTree']['frame']['id'],
        'url': cdnUrl,
        'options': {'disableCache': true, 'includeCredentials': true},
      });
      expect(legacy['resource']['httpStatusCode'], 403);
      final data = await browser.readImage(cdnUrl);
      expect(data, orderedEquals(image));
      final beforeReuse = imageRequests;
      expect(await browser.readImage(cdnUrl), orderedEquals(image));
      expect(imageRequests, beforeReuse); // Do not re-request already captured images.
      await browser.evaluate('''(() => {
        const img = document.createElement('img');
        img.referrerPolicy = 'unsafe-url';
        img.src = "${cdnUrl}?existing";
        document.body.appendChild(img);
      })()''');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final beforeExisting = imageRequests;
      expect(await browser.readImage('$cdnUrl?existing'), orderedEquals(image));
      expect(imageRequests, beforeExisting);
      await browser.readHtml('http://127.0.0.1:${server.port}/next');
      // Bytes captured on the prior page remain available after navigation.
      expect(await browser.readImage(cdnUrl), orderedEquals(image));
      // Resuming cached text must restore chapter Referer after a catalog navigation.
      await browser.readHtml('http://127.0.0.1:${server.port}/catalog');
      await source.prepareImageContext(Chapter('T', pageUrl, volume));
      expect(await browser.evaluate('location.href'), pageUrl);
      expect(await browser.readImage('$cdnUrl?resume'), orderedEquals(image));
      // Session cookies survive the visible-verification -> headless restart.
      await browser.restartHeadless(pageUrl);
      expect(browser.headless, true);
      expect(await browser.readImage(cdnUrl), orderedEquals(image));
      expect(await browser.evaluate('navigator.userAgent'), contains('HeadlessChrome'));
    } finally {
      await browser.close();
      await server.close(force:true);
      await cdn.close(force:true);
      await profile.delete(recursive:true);
    }
  }, timeout: const Timeout(Duration(minutes:2)));
  test('hung images cannot block text or prevent the real load handler', () async {
    final profile = await Directory.systemTemp.createTemp('bili-slow-page');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final browser = BrowserSession(profile: profile, headless: true,
      requestGap: Duration.zero, resourceGrace: const Duration(milliseconds: 300));
    server.listen((request) async {
      if (request.uri.path == '/hung.png') {
        // No response: this keeps window.load pending indefinitely in the old version.
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html><body><div id="acontent"><p>Before script</p>'
        '<img src="/hung.png"></div><script>window.loadCount=0;'
        'window.addEventListener("load",()=>{window.loadCount++;'
        'document.querySelector("p").textContent="After script";});</script></body></html>');
      await request.response.close();
    });
    try {
      await browser.start(mobile: false);
      final url = 'http://127.0.0.1:${server.port}/novel/1/2.html';
      final timer = Stopwatch()..start();
      final html = await browser.readHtml(url);
      expect(html, contains('After script'));
      expect(html, contains('data-src="/hung.png"'));
      expect(await browser.evaluate('window.loadCount'), 1);
      expect(timer.elapsed, lessThan(const Duration(seconds: 15)));
      // Protocol timeout diagnostics name the exact operation and target page.
      await expectLater(browser.command('Runtime.evaluate', {
        'expression': 'new Promise(() => {})', 'awaitPromise': true,
      }, const Duration(milliseconds: 100)), throwsA(isA<TimeoutException>()
        .having((e) => e.message, 'stage', contains('Runtime.evaluate'))
        .having((e) => e.message, 'url', contains(url))));
    } finally {
      await browser.close();
      await server.close(force: true);
      await profile.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('temporary 503 is retried once; 403 is not retried', () async {
    final profile = await Directory.systemTemp.createTemp('bili-page-retry');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final browser = BrowserSession(profile: profile, headless: true,
      requestGap: Duration.zero);
    var transientCalls = 0;
    var authCalls = 0;
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      if (request.uri.path == '/denied') {
        authCalls++;
        request.response.statusCode = 403;
        request.response.write('<html><body>Denied</body></html>');
      } else if (request.uri.path == '/transient') {
        transientCalls++;
        request.response.statusCode = transientCalls == 1 ? 503 : 200;
        request.response.write('<html><body><div id="acontent"><p>Recovered</p></div></body></html>');
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
    try {
      await browser.start(mobile: false);
      final base = 'http://127.0.0.1:${server.port}';
      expect(await browser.readHtml('$base/transient'), contains('Recovered'));
      expect(transientCalls, 2);
      await expectLater(browser.readHtml('$base/denied'),
        throwsA(isA<StateError>().having((e) => e.message, 'status', contains('403'))));
      expect(authCalls, 1);
    } finally {
      await browser.close();
      await server.close(force: true);
      await profile.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('ad permission waits longer than page timeout then survives headless restart', () async {
    final profile = await Directory.systemTemp.createTemp('bili-ad-gate');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var manualPauses = 0;
    final browser = BrowserSession(profile: profile, headless: true,
      requestGap: Duration.zero, pageTimeout: const Duration(seconds: 1),
      permissionHandler: (session, url) async {
        manualPauses++;
        // Controlled fixture: this represents the user finishing a required ad.
        await session.evaluate('''new Promise(resolve => setTimeout(() => {
          sessionStorage.setItem("readingPermission", "granted");
          document.querySelector('[role="dialog"]').remove();
          document.querySelector("#acontent").innerHTML="<p>Authorized chapter</p>";
          resolve(true);
        }, 1600))''');
        await session.restartHeadless(url);
      });
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('''<html><body><div id="acontent"><p>Authorized chapter</p></div>
        <script>
        if (sessionStorage.getItem("readingPermission") !== "granted") {
          document.querySelector("#acontent").innerHTML="<p>等待阅读授权</p>";
          const gate=document.createElement("div");
          gate.setAttribute("role","dialog");
          gate.style="position:fixed;top:0;left:0;width:400px;height:300px;z-index:2000";
          gate.textContent="请观看广告获得阅读权限，完成后才能继续";
          document.body.appendChild(gate);
        }
        </script></body></html>''');
      await request.response.close();
    });
    try {
      await browser.start(mobile: false);
      final url='http://127.0.0.1:${server.port}/novel/1/3.html';
      final html=await browser.readHtml(url);
      expect(html, contains('Authorized chapter'));
      expect(html, isNot(contains('role="dialog"')));
      expect(manualPauses, 1);
      expect(browser.headless, true);
      expect(await browser.evaluate('sessionStorage.getItem("readingPermission")'), 'granted');
      expect(await browser.readHtml(url), contains('Authorized chapter'));
      expect(manualPauses, 1);
    } finally {
      await browser.close();
      await server.close(force:true);
      await profile.delete(recursive:true);
    }
  }, timeout: const Timeout(Duration(minutes:3)));

  test('blocking JavaScript ad prompt is permission state instead of generic timeout', () async {
    final profile=await Directory.systemTemp.createTemp('bili-ad-dialog');
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    var manualPauses=0;
    final browser=BrowserSession(profile:profile,headless:true,requestGap:Duration.zero,
      pageTimeout:const Duration(seconds:2),
      permissionHandler:(session,url) async {
        manualPauses++;
        await session.command('Page.handleJavaScriptDialog', {'accept':false});
        await Future<void>.delayed(const Duration(milliseconds:100));
        // Controlled fixture grant; production asks the user to handle the real website.
        await session.evaluate('sessionStorage.setItem("readingPermission","granted")');
        await session.restartHeadless(url);
      });
    server.listen((request) async {
      request.response.headers.contentType=ContentType.html;
      request.response.write('''<html><body><div id="acontent"><p>Readable</p></div>
        <script>
        if (sessionStorage.getItem("readingPermission")!=="granted")
          alert("请观看广告获得阅读权限");
        </script></body></html>''');
      await request.response.close();
    });
    try {
      await browser.start(mobile:false);
      final html=await browser.readHtml('http://127.0.0.1:${server.port}/novel/1/4.html');
      expect(html,contains('Readable'));
      expect(manualPauses,1);
      expect(browser.headless,true);
    } finally {
      await browser.close();
      await server.close(force:true);
      await profile.delete(recursive:true);
    }
  }, timeout:const Timeout(Duration(minutes:3)));

}
