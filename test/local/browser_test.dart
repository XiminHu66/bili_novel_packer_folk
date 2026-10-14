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
}
