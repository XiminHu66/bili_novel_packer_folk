import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:bili_novel_packer/local/browser_session.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_source.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';

void main() {
  test('real Chrome executes chapter scripts once and loads authenticated images', () async {
    final profile = await Directory.systemTemp.createTemp('bili-browser-test');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final browser = BrowserSession(profile:profile, headless:true, requestGap:Duration.zero);
    final image = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=');
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
      final data = await browser.readImage('http://127.0.0.1:${server.port}/image.png');
      expect(data, orderedEquals(image));
    } finally {
      await browser.close();
      await server.close(force:true);
      await profile.delete(recursive:true);
    }
  }, timeout: const Timeout(Duration(minutes:2)));
}
