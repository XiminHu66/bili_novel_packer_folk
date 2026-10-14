import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/dom.dart';
import 'package:test/test.dart';
import 'package:bili_novel_packer/local/download_cache.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_source.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_source.dart';
import 'package:bili_novel_packer/novel_packer.dart';
import 'package:bili_novel_packer/pack_option.dart';
import 'package:xml/xml.dart';

class FakeSource implements LightNovelSource {
  int calls = 0;
  bool fail = false;
  @override String get name => 'fixture';
  @override String get sourceUrl => 'https://example.test';
  @override bool supportUrl(String url) => true;
  @override Future<Novel> getNovel(String url) async => throw UnimplementedError();
  @override Future<Catalog> getNovelCatalog(Novel novel) async => throw UnimplementedError();
  @override Future<Document> getNovelChapter(Chapter chapter) async {
    calls++;
    if (fail && chapter.chapterName == 'Second') throw StateError('Login expired');
    return Document.html('<html><head></head><body><p>${chapter.chapterName}</p>'
      '<img src="https://example.test/image.png"></body></html>');
  }
  @override Future<Uint8List> getImage(String url) async => throw StateError('image unavailable');
}
void verifyEpub(File file, {required int chapters}) {
  final zip = ZipDecoder().decodeBytes(file.readAsBytesSync());
  expect(zip.first.name, 'mimetype');
  expect(String.fromCharCodes(zip.first.content as List<int>), 'application/epub+zip');
  expect(zip.files.where((f) => f.name.startsWith('OEBPS/chapter')).length, chapters);
  for (final entry in zip.files.where((f) => f.name.endsWith('.xhtml') || f.name.endsWith('.opf'))) {
    expect(() => XmlDocument.parse(String.fromCharCodes(entry.content as List<int>)), returnsNormally);
  }
}
void main() {
  test('legacy keyed cache is retained offline and replaced only by a successful verified fetch', () async {
    final previous = Directory.current;
    final directory = await Directory.systemTemp.createTemp('bili-legacy-cache');
    Directory.current = directory;
    try {
      final novel = Novel()..id='1'..title='Migration'..author='A'..status='';
      final volume = Volume('', Catalog(novel));
      final chapter = Chapter('T', 'https://www.bilinovel.com/novel/1/1.html', volume);
      volume.chapters.add(chapter);
      final cache = DownloadCache();
      const legacy = '<html><body><p data-k1="">Text</p><p data-k450="">Text</p></body></html>';
      await cache.saveChapter(chapter.chapterUrl!, 'T', legacy);
      var calls = 0;
      var fail = true;
      final source = BiliNovelSource(htmlLoader: (_) async {
        calls++;
        if (fail) throw StateError('fixture network failure');
        return '<div id="acontent" data-bili-rendered="visible-v1"><p data-k1="">Text</p></div>';
      });
      final option = PackOption()..addChapterTitle=false..selectedVolumes=[volume];
      Future<void> pack({bool offline = false}) => NovelPacker(source, cache: cache,
          textOnly: true, offline: offline).packVolume(source: source, volume: volume, option: option);
      await expectLater(pack(offline: true), throwsStateError);
      expect(calls, 0);
      await expectLater(pack(), throwsStateError);
      expect(await cache.readChapter(chapter.chapterUrl!), legacy);
      fail = false;
      await pack();
      expect(calls, 2);
      final saved = await cache.readChapter(chapter.chapterUrl!);
      expect(saved, contains('data-bili-content-version="2"'));
      expect(saved, isNot(contains('data-k450')));
      await pack(offline: true);
      expect(calls, 2);
      verifyEpub(File('Migration/Migration.epub'), chapters: 1);
    } finally {
      Directory.current = previous;
      await directory.delete(recursive: true);
    }
  });
  test('cache survives a new instance and corrupt records are misses', () async {
    final directory = await Directory.systemTemp.createTemp('bili-cache-test');
    try {
      final cache = DownloadCache(root: directory);
      await cache.saveChapter('https://test/1', 'Title', '<p>Text</p>');
      final reopened = DownloadCache(root: directory);
      expect(await reopened.readChapter('https://test/1'), '<p>Text</p>');
      expect(await reopened.readChapter('https://test/2'), isNull);
      final file = directory.listSync(recursive:true).whereType<File>()
        .firstWhere((f) => !f.path.endsWith('.tmp'));
      await file.writeAsString('corrupt');
      expect(await reopened.readChapter('https://test/1'), isNull);
    } finally { await directory.delete(recursive:true); }
  });
  test('failed chapter emits partial EPUB; resumed text-only and offline use cache', () async {
    final previous = Directory.current;
    final directory = await Directory.systemTemp.createTemp('bili-pack-test');
    Directory.current = directory;
    try {
      final novel = Novel()..id='1'..title='Fixture'..author='A'..status='';
      final volume = Volume('', Catalog(novel));
      volume.chapters.addAll([
        Chapter('First', 'https://example.test/1', volume),
        Chapter('Second', 'https://example.test/2', volume),
      ]);
      final source = FakeSource()..fail=true;
      final option = PackOption()..addChapterTitle=false..selectedVolumes=[volume];
      await expectLater(NovelPacker(source, textOnly:true).packVolume(
        source:source, volume:volume, option:option), throwsStateError);
      final partial = File('Fixture/Fixture.partial.epub');
      expect(partial.existsSync(), true);
      verifyEpub(partial, chapters:1);
      source.fail=false;
      await NovelPacker(source, textOnly:true).packVolume(source:source, volume:volume, option:option);
      expect(source.calls, 3);
      verifyEpub(File('Fixture/Fixture.epub'), chapters:2);
      expect(partial.existsSync(), false);
      // Image errors must not discard text; exporting cached text must avoid refetching chapters.
      await NovelPacker(source).packCombine(source:source, novel:novel, option:option);
      expect(source.calls, 3);
      verifyEpub(File('Fixture/Fixture.epub'), chapters:2);
      final failedImagesZip = ZipDecoder().decodeBytes(File('Fixture/Fixture.epub').readAsBytesSync());
      expect(failedImagesZip.files.where((f) => f.name.startsWith('OEBPS/chapter'))
          .every((entry) => !String.fromCharCodes(entry.content as List<int>).contains('<img')), true);
      source.fail=true;
      await NovelPacker(source, textOnly:true, offline:true).packVolume(
        source:source, volume:volume, option:option);
      expect(source.calls, 3);
      verifyEpub(File('Fixture/Fixture.epub'), chapters:2);
    } finally {
      Directory.current=previous;
      await directory.delete(recursive:true);
    }
  });
}
