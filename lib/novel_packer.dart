import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:bili_novel_packer/local/download_cache.dart';

import 'package:bili_novel_packer/assets/assets.dart';
import 'package:bili_novel_packer/console/console.dart';
import 'package:bili_novel_packer/epub_packer/epub_navigator_ncx.dart';
import 'package:bili_novel_packer/epub_packer/epub_packer.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_cover_detector.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_source.dart';
import 'package:bili_novel_packer/logger.dart';
import 'package:bili_novel_packer/pack_option.dart';
import 'package:bili_novel_packer/util/html_util.dart';
import 'package:bili_novel_packer/util/sequence.dart';
import 'package:bili_novel_packer/util/volume_util.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

class NovelPacker {
  final LightNovelSource source;

  final DownloadCache cache;
  final bool textOnly;
  final bool offline;
  NovelPacker(this.source, {DownloadCache? cache, this.textOnly = false,
      this.offline = false}) : cache = cache ?? DownloadCache();

  Future<void> packVolume({
    required LightNovelSource source,
    required Volume volume,
    required PackOption option,
  }) async {
    console.writeLine("开始打包 ${volume.volumeName}...");
    logger.i("开始打包 ${volume.volumeName}");
    EpubPacker packer = EpubPacker(_getEpubVolumeName(volume));
    _fillEpubVolume(packer, volume);
    if (option.addChapterTitle) {
      packer.addStylesheet(styleCss());
    }
    LightNovelCoverDetector detector = LightNovelCoverDetector();

    Sequence chapterSeq = Sequence();
    Sequence imageSeq = Sequence();
    try {
    for (var chapter in volume.chapters) {
      var doc = await _resolveChapter(
        chapter: chapter,
        packer: packer,
        imageSeq: imageSeq,
        addChapterTitle: option.addChapterTitle,
        detector: detector,
      );
      _addTitle(doc, chapter.chapterName);
      String html = _closeTag(doc);
      html = _appendXmlDeclare(html);
      String chapterId = chapterSeq.next.toString().padLeft(6, "0");
      packer.addChapter(
        name: "OEBPS/chapter$chapterId.xhtml",
        title: chapter.chapterName,
        chapterContent: html,
      );
    }
    } catch (_) {
      if (chapterSeq.nowVal > 0) packer.pack(partial: true);
      rethrow;
    }
    // 设置封面
    await _resolveCover(
      volume: volume,
      packer: packer,
      imageSeq: imageSeq,
      coverDetector: detector,
    );
    // 写出目标文件
    packer.pack();
    logger.i("EPUB file: ${packer.absolutePath}\n");
    console.writeLine("打包完成: ${packer.absolutePath}\n");
  }

  String _getEpubVolumeName(Volume volume) {
    String title = _sanitizeFileName(volume.catalog.novel.title);
    String volumeName = _sanitizeFileName(volume.volumeName);
    if (volumeName == "") {
      return "$title${Platform.pathSeparator}$title.epub";
    }
    if (volumeName.startsWith(title)) {
      return "$title${Platform.pathSeparator}$volumeName.epub";
    }
    return "$title${Platform.pathSeparator}$title $volumeName.epub";
  }

  void _fillEpubVolume(EpubPacker packer, Volume volume) {
    var novel = volume.catalog.novel;
    packer.docTitle = "${volume.catalog.novel.title} ${volume.volumeName}";
    if (volume.volumeName.startsWith(volume.catalog.novel.title)) {
      packer.docTitle = volume.volumeName;
    }
    packer.creator = volume.catalog.novel.author;
    packer.source = novel.url;
    packer.publisher = novel.publisher;
    packer.subjects = novel.tags ?? [];
    packer.description = novel.description;
    // 当识别出丛书编号时才设置丛书名 否则丛书编号会被当成1
    packer.calibreSeriesIndex = VolumeUtil.getSeriesIndex(volume.volumeName);
    if (packer.calibreSeriesIndex != null) {
      packer.calibreSeries = volume.catalog.novel.title;
    }
  }

  Future<void> packCombine({
    required LightNovelSource source,
    required Novel novel,
    required PackOption option,
  }) async {
    EpubPacker packer = EpubPacker(_getEpubCombineName(novel));
    _fillEpubCombine(packer, novel);

    Sequence chapterSeq = Sequence();
    Sequence imageSeq = Sequence();

    Uint8List? coverData = novel.coverUrl == null
        ? null
        : await _downloadImageByUrl(novel.coverUrl!);
    if (coverData != null && coverData.isNotEmpty) {
      final format = _imageFormat(coverData);
      String coverId = imageSeq.next.toString().padLeft(6, '0');
      String coverName = "images/$coverId.${format.$1}";
      packer.addImage(name: "OEBPS/$coverName", data: coverData, mediaType: format.$2);
      packer.cover = coverName;
    }

    if (option.addChapterTitle) {
      packer.addStylesheet(styleCss());
    }

    try {
    for (Volume volume in option.selectedVolumes) {
      logger.i("开始处理: ${volume.volumeName}");
      console.writeLine("正在处理: ${volume.volumeName}");
      NavPoint volumeNavPoint = NavPoint(volume.volumeName);
      packer.addNavPoint(volumeNavPoint);

      for (var i = 0; i < volume.chapters.length; i++) {
        var chapter = volume.chapters[i];
        var doc = await _resolveChapter(
          chapter: chapter,
          packer: packer,
          imageSeq: imageSeq,
          addChapterTitle: option.addChapterTitle,
        );
        _addTitle(doc, chapter.chapterName);
        String html = _closeTag(doc);
        html = _appendXmlDeclare(html);
        String chapterId = chapterSeq.next.toString().padLeft(6, "0");
        String name = "chapter$chapterId.xhtml";
        packer.addChapter(
          addNavPoint: false,
          name: "OEBPS/$name",
          title: chapter.chapterName,
          chapterContent: html,
        );
        NavPoint chapterNavPoint = NavPoint(chapter.chapterName, src: name);
        volumeNavPoint.addChild(chapterNavPoint);
        if (i == 0) {
          volumeNavPoint.src = name;
        }
      }
      logger.i("处理完成: ${volume.volumeName}");
    }
    } catch (_) {
      if (chapterSeq.nowVal > 0) packer.pack(partial: true);
      rethrow;
    }
    packer.pack();
    logger.i("EPUB file: ${packer.absolutePath}");
    console.writeLine("打包完成: ${packer.absolutePath}");
  }

  String _getEpubCombineName(Novel novel) {
    String title = _sanitizeFileName(novel.title);
    return "$title${Platform.pathSeparator}$title.epub";
  }

  void _fillEpubCombine(EpubPacker packer, Novel novel) {
    packer.docTitle = novel.title;
    packer.creator = novel.author;
    packer.source = novel.url;
    packer.publisher = novel.publisher;
    packer.subjects = novel.tags ?? [];
    packer.description = novel.description;
  }

  Future<Document> _resolveChapter({
    required Chapter chapter,
    required EpubPacker packer,
    required bool addChapterTitle,
    required Sequence imageSeq,
    LightNovelCoverDetector? detector,
  }) async {
    final url = chapter.chapterUrl ??
        'chapter:${chapter.volume.catalog.novel.id}:${chapter.volume.volumeName}:${chapter.chapterName}';
    final cached = await cache.readChapter(url);
    late Document doc;
    if (cached != null) {
      console.writeLine('使用缓存: ${chapter.chapterName}');
      doc = parse(cached);
    } else {
      if (offline) throw StateError('离线模式缺少章节: ${chapter.chapterName}');
      doc = await source.getNovelChapter(chapter);
      await cache.saveChapter(url, chapter.chapterName, doc.outerHtml);
    }
    // 处理图片资源
    await _resolveImages(
      doc: doc,
      packer: packer,
      imageSeq: imageSeq,
      detector: detector,
    );

    // 添加章节标题
    if (addChapterTitle) {
      doc.head!.append(
        Element.html(
          '<link rel="stylesheet" type="text/css" href="styles/style.css">',
        ),
      );
      var firstChild = doc.body!.firstChild;
      Node chapterTitle = Element.html(
        '<div class="chapter-title">${chapter.chapterName}</div>',
      );
      doc.body!.insertBefore(chapterTitle, firstChild);
    }
    return doc;
  }

  Future<void> _resolveImages({
    required Document doc,
    required EpubPacker packer,
    required Sequence imageSeq,
    required LightNovelCoverDetector? detector,
  }) async {
    List<Element> imgList = doc.querySelectorAll("img");
    if (textOnly || offline) {
      for (final image in imgList) { image.remove(); }
      return;
    }
    for (var img in imgList) {
      var imageData = await _downloadImage(img);
      if (imageData == null) {
        img.replaceWith(Element.tag("p")..text = "[插图下载失败，重新运行可补全]");
        continue;
      }
      final format = _imageFormat(imageData);
      String imageName = "${imageSeq.next.toString().padLeft(6, '0')}.${format.$1}";
      String relativeSrc = "images/$imageName";
      packer.addImage(name: "OEBPS/$relativeSrc", data: imageData, mediaType: format.$2);
      String src = img.attributes["src"]!;
      img.attributes["src"] = relativeSrc;
      try {
        detector?.add("OEBPS/$relativeSrc", imageData);
      } on UnsupportedImageException catch (e) {
        console.writeLine("$src ${e.message}");
      }
    }
    HTMLUtil.wrapDuoKanImage(doc.body!);
  }

  Future<Uint8List?> _downloadImage(Element img) async {
    String? src = img.attributes["src"];
    if (src == null || src.trim().isEmpty) {
      return null;
    }
    return await _downloadImageByUrl(src);
  }

  Future<Uint8List?> _downloadImageByUrl(String url) async {
    if (textOnly || offline) return null;
    try {
      final cached = await cache.readImage(url);
      if (cached != null) return cached;
      Uint8List imageData = await source.getImage(url).timeout(const Duration(seconds: 90));
      if (imageData.isEmpty) {
        console.writeLine("$url 图片下载失败: 图片下载为空");
        return null;
      }
      _imageFormat(imageData); // Reject HTML/error responses masquerading as images.
      await cache.saveImage(url, imageData);
      return imageData;
    } catch (e) {
      console.writeLine("$url 图片下载失败: $e");
      return null;
    }
  }

  Future<void> _resolveCover({
    required Volume volume,
    required EpubPacker packer,
    required Sequence imageSeq,
    required LightNovelCoverDetector coverDetector,
  }) async {
    // 优先使用volume.cover 但需检测比例
    if (volume.cover != null) {
      Uint8List? coverData = await _downloadImageByUrl(volume.cover!);
      if (coverData != null && coverData.isNotEmpty) {
        final format = _imageFormat(coverData);
        String coverId = imageSeq.next.toString().padLeft(6, '0');
        String coverName = "images/$coverId.${format.$1}";
        packer.addImage(name: "OEBPS/$coverName", data: coverData, mediaType: format.$2);
        coverDetector.addFirst("OEBPS/$coverName", coverData);
      }
    }
    String? cover = coverDetector.detectCover();
    if (cover != null) {
      packer.cover = cover.replaceFirst("OEBPS/", "");
    }
  }

  (String, String) _imageFormat(Uint8List data) {
    if (data.length >= 8 && data[0] == 137 && data[1] == 80 &&
        data[2] == 78 && data[3] == 71) return ('png', 'image/png');
    if (data.length >= 3 && data[0] == 255 && data[1] == 216 &&
        data[2] == 255) return ('jpg', 'image/jpeg');
    if (data.length >= 6 && String.fromCharCodes(data.take(3)) == 'GIF') {
      return ('gif', 'image/gif');
    }
    if (data.length >= 12 && String.fromCharCodes(data.take(4)) == 'RIFF' &&
        String.fromCharCodes(data.skip(8).take(4)) == 'WEBP') {
      return ('webp', 'image/webp');
    }
    throw StateError('图片格式不支持或返回了网页，已跳过。');
  }

  String _sanitizeFileName(String name) {
    var keywords = {":", "*", "?", "\"", "\\", "/", "<", ">", "|", "\\0", "　"};
    for (var keyword in keywords) {
      name = name.replaceAll(keyword, " ");
    }
    if (name.startsWith(".")) {
      name = name.substring(1);
    }
    if (name.endsWith(".")) {
      name = name.substring(0, name.length - 1);
    }
    // 替换连续空格为一个空格
    name = name.replaceAllMapped(RegExp("\\s{2,}"), (_) => " ");
    return name.trim();
  }

  // 添加title元素
  void _addTitle(Document document, String title) {
    var element = document.createElement("title");
    element.text = title;
    document.head?.append(element);
  }

  /// 将标签闭合
  String _closeTag(Document document) {
    String html = document.outerHtml;
    RegExp regExp = RegExp("(<(?:img|link).*?)>");
    Iterable<RegExpMatch> matches = regExp.allMatches(html);
    for (var match in matches) {
      String segment = match.group(0)!;
      if (!segment.endsWith("/>")) {
        String newImg = "${match.group(1)!}/>";
        html = html.replaceAll(segment, newImg);
      }
    }
    return html;
  }

  String _appendXmlDeclare(String html) {
    String xml = '<?xml version="1.0" encoding="utf-8"?>';
    String docType = '<!DOCTYPE html>';
    return '$xml\n$docType\n$html';
  }
}
