import 'package:test/test.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_source.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';

Chapter chapter() {
  final novel = Novel()..id='5340'..title='Test'..author='A'..status='';
  final volume = Volume('Volume', Catalog(novel));
  return Chapter('Chapter', 'https://www.bilinovel.com/novel/5340/341307.html', volume);
}
void main() {
  test('fallback .bcontent works when #acontent is absent', () async {
    final source = BiliNovelSource(htmlLoader: (_) async =>
      '<h1 id="atitle">Title</h1><div class="bcontent"><p>One</p><p>Two</p></div>');
    final doc = await source.getNovelChapter(chapter());
    expect(doc.body!.text, contains('One'));
    expect(doc.body!.text, contains('Two'));
  });
  test('login page is identified and never becomes chapter content', () async {
    final source = BiliNovelSource(htmlLoader: (_) async =>
      '<html><body>invalid login<input type="password"></body></html>');
    await expectLater(source.getNovelChapter(chapter()),
      throwsA(isA<StateError>().having((e) => e.message.toString(), 'message', contains('登录'))));
  });
  test('pagination supports DOM hrefs and stops before next chapter', () async {
    var count = 0;
    final source = BiliNovelSource(htmlLoader: (url) async {
      count++;
      if (url.endsWith('_2.html')) {
        return '<div id="acontent"><p>Page 2</p></div>'
          '<div id="footlink"><a class="nextlink" href="/novel/5340/341308.html">下一章</a></div>';
      }
      return '<div id="acontent"><p>Page 1</p></div>'
        '<div id="footlink"><a class="nextlink" href="341307_2.html"> 下一页 </a></div>';
    });
    final doc = await source.getNovelChapter(chapter());
    expect(doc.body!.text, contains('Page 1'));
    expect(doc.body!.text, contains('Page 2'));
    expect(count, 2);
  });
  test('pagination loop is bounded', () async {
    var count = 0;
    final source = BiliNovelSource(htmlLoader: (_) async {
      count++;
      return '<div id="acontent"><p>Page</p></div>'
        '<div id="footlink"><a class="nextlink" href="341307.html">下一页</a></div>';
    });
    await expectLater(source.getNovelChapter(chapter()), throwsStateError);
    expect(count, 1);
  });
  test('a page link cannot silently cross into the next chapter', () async {
    final source = BiliNovelSource(htmlLoader: (_) async =>
      '<div id="acontent"><p>Page</p></div>'
      '<div id="footlink"><a class="nextlink" href="341308.html">下一页</a></div>');
    await expectLater(source.getNovelChapter(chapter()), throwsStateError);
  });
}
