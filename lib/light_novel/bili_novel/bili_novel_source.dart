import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:bili_novel_packer/local/browser_session.dart';
import 'package:bili_novel_packer/local/download_cache.dart';

import 'package:bili_novel_packer/interceptor/logging_interceptor.dart';
import 'package:bili_novel_packer/interceptor/rate_limit_interceptor.dart';
import 'package:bili_novel_packer/interceptor/redirect_interceptor.dart';
import 'package:bili_novel_packer/interceptor/retry_interceptor.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_source.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_chapterlog.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_restore.dart';
import 'package:bili_novel_packer/logger.dart';
import 'package:bili_novel_packer/util/html_util.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

class BiliNovelSource implements LightNovelSource {
  static final RegExp _exp = RegExp(
    "(?:https?://[^/]*?(?:linovelib\\.com|bilinovel\\.(?:com|net)))/(?:novel|download)/(\\d+)",
  );
  static final String domain = "https://www.bilinovel.com";

  static final String userAgent =
      "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36";

  static const List<String> _contentSelectors = ["#acontent", ".bcontent"];
  static const int _maxChapterUrlProbeCount = 20;

  static const Set<String> _previousPageTexts = {"上一页", "上一頁"};
  static const Set<String> _nextPageTexts = {"下一页", "下一頁"};

  static final RegExp _pageUrlRegExp = RegExp(
    "url_previous:'(.*?)',url_next:'(.*?)'",
  );

  late final Dio _dio;
  late final Dio _imageDio;
  late final BiliChapterLogResolver _chapterLogResolver =
      BiliChapterLogResolver(
        domain: domain,
        loadScript: (src) {
          return _dio.get(src).then((res) {
            return res.data.toString();
          });
        },
      );

  final BrowserSession? browser;
  final Future<String> Function(String)? htmlLoader;
  final bool offline;
  final DownloadCache pageCache;
  BiliNovelSource({this.browser, this.htmlLoader, this.offline = false,
      DownloadCache? pageCache}) : pageCache = pageCache ?? DownloadCache() {
    var options = _createBaseOptions();
    _dio = _createTextDio(options);
    _imageDio = _createImageDio(options);
  }

  BaseOptions _createBaseOptions() {
    return BaseOptions(
      baseUrl: domain,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Cookie": "night=0",
        "Referer": domain,
        "User-Agent": userAgent,
      },
      responseType: ResponseType.plain,
      validateStatus: (status) {
        if (status == null) return false;
        return status >= 200 && status < 400;
      },
    );
  }

  Dio _createTextDio(BaseOptions options) {
    var dio = Dio(options);
    dio.interceptors.add(RateLimitInterceptor(15, Duration(minutes: 1)));
    dio.interceptors.add(
      RetryInterceptor(dio: dio, delay: Duration(seconds: 3)),
    );
    dio.interceptors.add(LoggingInterceptor(printer: logger.i));
    dio.interceptors.add(RedirectInterceptor(dio));
    return dio;
  }

  Dio _createImageDio(BaseOptions options) {
    var dio = Dio(options.copyWith(responseType: ResponseType.bytes));
    dio.interceptors.add(RateLimitInterceptor(10, Duration(minutes: 1)));
    dio.interceptors.add(
      RetryInterceptor(dio: dio, delay: Duration(seconds: 3)),
    );
    dio.interceptors.add(LoggingInterceptor(printer: logger.i));
    return dio;
  }

  @override
  final String name = "哔哩轻小说";

  @override
  final String sourceUrl = "https://www.bilinovel.com";

  @override
  Future<Novel> getNovel(String url) async {
    String id = _getId(url);
    String actualUrl = "$domain/novel/$id.html";
    String html = await _readHtml(actualUrl);
    if (offline) return _parseNovel(actualUrl, id, parse(html));
    try {
      final novel = _parseNovel(actualUrl, id, parse(html));
      await pageCache.saveChapter('page:$actualUrl', novel.title, html);
      return novel;
    } catch (e) {
      logger.e(e);
      // Do not log HTML, which may contain account information.
      rethrow;
    }
  }

  Novel _parseNovel(String url, String id, Document doc) {
    return Novel()
      ..id = id
      ..url = url
      ..title = doc.querySelector(".book-title")!.text
      ..alias = _getNovelAlias(doc)
      ..coverUrl = doc.querySelector(".book-layout img")!.attributes["src"]!
      ..tags = doc
          .querySelectorAll(".book-cell .book-meta span em")
          .map((e) => e.text)
          .toList()
      ..publisher = doc.querySelector(".tag-small.orange")?.text
      ..status = doc
          .querySelector(".book-cell .book-meta+.book-meta")!
          .nodes
          .last
          .text!
      ..author = doc.querySelector(".book-rand-a span")!.text
      ..description = doc.querySelector("#bookSummary content")!.text;
  }

  String? _getNovelAlias(Document doc) {
    return doc.querySelector(".backupname .bkname-body.gray")?.text.trim();
  }

  String _getId(String url) {
    var match = _exp.firstMatch(url);
    if (match == null || match.groupCount < 1) {
      throw "不支持的URL: $url";
    }
    return match.group(1)!;
  }

  /// 获取小说目录
  @override
  Future<Catalog> getNovelCatalog(Novel novel) async {
    String url = "$domain/novel/${novel.id}/catalog";
    String html = await _readHtml(url);
    var doc = parse(html);
    var catalog = Catalog(novel);
    // 获取卷封面前先处理图片src
    _fixImgSrc(doc.body!);

    var items = _getCatalogItems(url, html, doc);
    _parseCatalogItems(catalog, doc, items);
    if (catalog.volumes.isEmpty || catalog.volumes.every((v) => v.chapters.isEmpty)) {
      throw StateError('目录没有可下载章节，请检查网页或更新下载器。');
    }
    if (!offline) await pageCache.saveChapter('page:$url', novel.title, html);
    return catalog;
  }

  List<Element> _getCatalogItems(String url, String html, Document doc) {
    var items = doc.querySelectorAll(".volume-chapters>li");
    if (items.isEmpty) {
      // Do not log HTML, which may contain account information.
      throw "目录获取为空";
    }
    return items;
  }

  void _parseCatalogItems(
    Catalog catalog,
    Document doc,
    List<Element> items,
  ) {
    Volume? volume = _createInitialVolume(catalog, doc);
    for (var item in items) {
      volume = _parseCatalogItem(catalog, volume, item);
    }
    if (volume != null) {
      catalog.volumes.add(volume);
    }
  }

  Volume? _createInitialVolume(Catalog catalog, Document doc) {
    // 如果没有卷标题，则将书名直接作为卷名。
    if (doc.querySelector(".chapter-bar") == null) {
      return Volume("", catalog);
    }
    return null;
  }

  Volume? _parseCatalogItem(
    Catalog catalog,
    Volume? volume,
    Element item,
  ) {
    if (item.classes.contains("chapter-bar")) {
      if (volume != null) {
        catalog.volumes.add(volume);
      }
      return Volume(item.text, catalog);
    }

    if (item.classes.contains("volume-cover")) {
      var coverImg = item.querySelector("a")?.querySelector("img");
      if (coverImg != null) {
        var coverUrl =
            coverImg.attributes["data-src"] ?? coverImg.attributes["src"];
        if (coverUrl?.contains("book-cover-no") ?? false) {
          coverUrl = null;
        } else {
          volume?.cover = coverUrl;
        }
      }
      return volume;
    }

    if (item.classes.contains("jsChapter") && volume != null) {
      volume.chapters.add(_parseCatalogChapter(item, volume));
    }
    return volume;
  }

  Chapter _parseCatalogChapter(Element item, Volume volume) {
    var link = item.querySelector("a")!;
    return Chapter(
      link.text,
      _normalizeChapterHref(link.attributes["href"]),
      volume,
    );
  }

  String? _normalizeChapterHref(String? href) {
    if (href == null || href.contains("javascript")) {
      return null;
    }
    return Uri.parse(domain).resolve(href).toString();
  }

  @override
  Future<Document> getNovelChapter(Chapter chapter) async {
    Document doc = Document.html(LightNovelSource.html);

    String chapterUrl = await _requireChapterUrl(chapter);
    logger.i("");
    logger.i("${chapter.chapterName} ${chapter.chapterUrl}");
    String? nextPageUrl = chapterUrl;
    final visited = <String>{};
    do {
      if (!visited.add(nextPageUrl!) || visited.length > 100) {
        throw StateError('章节分页循环或超过 100 页，已停止，避免重复抓取。');
      }
      ChapterPage page = await _getChapterPage(nextPageUrl);
      _updateChapterName(chapter, page);
      _appendChapterPage(doc, page);
      nextPageUrl = page.nextPageUrl;
      if (nextPageUrl != null) {
        final currentId = Uri.parse(chapterUrl).path.split('/').last.split('.').first.split('_').first;
        final nextId = Uri.parse(nextPageUrl).path.split('/').last.split('.').first.split('_').first;
        if (currentId != nextId) throw StateError('分页链接跳到了另一章，已停止以避免错章。');
      }
    } while (nextPageUrl != null);

    return _finalizeChapterDocument(doc);
  }

  Future<String> _requireChapterUrl(Chapter chapter) async {
    chapter.chapterUrl ??= await _getChapterUrl(chapter);
    if (chapter.chapterUrl == null) {
      throw "Empty chapter url";
    }
    return chapter.chapterUrl!;
  }

  void _updateChapterName(Chapter chapter, ChapterPage page) {
    // 处理目录标题与章节中获取的标题不一致情况。
    if (page.title != null &&
        page.title != chapter.chapterName &&
        !page.title!.contains("〇")) {
      chapter.chapterName = page.title!;
    }
  }

  void _appendChapterPage(Document doc, ChapterPage page) {
    for (var content in page.contents) {
      doc.body!.append(content);
    }
  }

  Document _finalizeChapterDocument(Document doc) {
    HTMLUtil.unescape(doc.body!);
    HTMLUtil.removeLineBreak(doc.body!);
    _normalizeImg(doc.body!);
    return doc;
  }

  /// 网站早期版本缺失url的处理方法
  Future<String?> _getChapterUrl(Chapter chapter) async {
    if (chapter.chapterUrl != null && chapter.chapterUrl!.isNotEmpty) {
      return chapter.chapterUrl;
    }
    Catalog catalog = chapter.volume.catalog;
    return await _findChapterUrlFromNextChapter(catalog, chapter) ??
        await _findChapterUrlFromPrevChapter(catalog, chapter);
  }

  Future<String?> _findChapterUrlFromNextChapter(
    Catalog catalog,
    Chapter chapter,
  ) async {
    // 先获取下一章，再通过下一章页面中的“上一章”反推出当前章节链接。
    Chapter? nextChapter = _getNextChapter(catalog, chapter);
    if (nextChapter?.chapterUrl == null) {
      return null;
    }

    ChapterPage chapterPage = await _getChapterPage(nextChapter!.chapterUrl!);
    return chapterPage.prevChapterUrl;
  }

  Future<String?> _findChapterUrlFromPrevChapter(
    Catalog catalog,
    Chapter chapter,
  ) async {
    // 先获取上一章，再沿着“下一页”走到末页，从末页的“下一章”拿当前章节链接。
    Chapter? prevChapter = _getPrevChapter(catalog, chapter);
    if (prevChapter?.chapterUrl == null) {
      return null;
    }

    ChapterPage page = await _getChapterPage(prevChapter!.chapterUrl!);
    for (int i = 0; i < _maxChapterUrlProbeCount; i++) {
      String? nextPageUrl = page.nextPageUrl;
      if (nextPageUrl == null) {
        return page.nextChapterUrl;
      }
      page = await _getChapterPage(nextPageUrl);
    }
    return null;
  }

  // 根据目录查找上一章
  Chapter? _getPrevChapter(Catalog catalog, Chapter chapter) {
    List<Chapter> chapters = catalog.volumes
        .expand((volume) => volume.chapters)
        .toList();
    int pos = chapters.indexOf(chapter);
    if (pos < 1) return null;
    return chapters[pos - 1];
  }

  // 根据目录查找下一章
  Chapter? _getNextChapter(Catalog catalog, Chapter chapter) {
    List<Chapter> chapters = catalog.volumes
        .expand((volume) => volume.chapters)
        .toList();
    int pos = chapters.indexOf(chapter);
    if (pos < 0 || pos >= chapters.length - 1) return null;
    return chapters[pos + 1];
  }

  @override
  bool supportUrl(String url) {
    return _exp.hasMatch(url);
  }

  /// 获取章节一页内容
  Future<ChapterPage> _getChapterPage(String url) async {
    String html = await _readHtml(url);
    var doc = parse(html);

    String? title = _getChapterPageTitle(url, doc);
    Element content = _getChapterPageContent(url, html, doc);
    _ChapterNavigation navigation = _getChapterNavigation(doc, url);
    _cleanChapterContent(content);
    // Chrome has already executed chapterlog.js; never shuffle the rendered DOM twice.
    if (browser == null) await _restoreChapterContent(doc, content);

    return ChapterPage(
      title: title,
      content.children.toList(),
      prevPageUrl: navigation.prevPageUrl,
      nextPageUrl: navigation.nextPageUrl,
      prevChapterUrl: navigation.prevChapterUrl,
      nextChapterUrl: navigation.nextChapterUrl,
    );
  }

  String? _getChapterPageTitle(String url, Document doc) {
    if (url.contains("_")) {
      return null;
    }
    return doc.querySelector("#atitle")?.text;
  }

  Element _getChapterPageContent(String url, String html, Document doc) {
    Element? content = _contentSelectors
        .map((selector) => doc.querySelector(selector))
        .whereType<Element>()
        .firstOrNull;
    if (content == null) {
      logger.i("GET $url ERROR");
      // Do not log HTML, which may contain account information.
      final visible = doc.body?.text ?? '';
      if (RegExp(r'invalid\s+login|请先登录|請先登入|登录失效|登入失效', caseSensitive: false).hasMatch(visible)
          || doc.querySelector('input[type="password"]') != null) {
        throw StateError('登录无效或已过期。请在下载器专用 Chrome 中登录 bilinovel.com，'
            '确认可阅读该章后重新运行；已完成章节会从缓存恢复。');
      }
      throw StateError('网页没有正文，可能是验证、限流或网站结构变化。'
          '请重新运行下载器，在验证窗口中确认网页可阅读，再继续后台下载。URL: $url');
    }
    return content;
  }

  _ChapterNavigation _getChapterNavigation(Document doc, String url) {
    RegExpMatch? match = _pageUrlRegExp.firstMatch(doc.outerHtml);
    String? prevUrl = match?.group(1);
    String? nextUrl = match?.group(2);
    Element? prev = doc.querySelector("#footlink a.prevlink");
    Element? next = doc.querySelector("#footlink a.nextlink");
    prevUrl ??= prev?.attributes['href'];
    nextUrl ??= next?.attributes['href'];

    String? prevPage;
    String? nextPage;
    String? prevChapter;
    String? nextChapter;

    if (prev != null && prevUrl != null) {
      if (_isPageLink(prev, _previousPageTexts)) {
        prevPage = Uri.parse(url).resolve(prevUrl).toString();
      } else if (!_isCatalog(prev)) {
        prevChapter = Uri.parse(url).resolve(prevUrl).toString();
      }
    }

    if (next != null && nextUrl != null) {
      if (_isPageLink(next, _nextPageTexts)) {
        nextPage = Uri.parse(url).resolve(nextUrl).toString();
      } else if (!_isCatalog(next)) {
        nextChapter = Uri.parse(url).resolve(nextUrl).toString();
      }
    }
    if (nextPage == null && nextChapter == null) {
      logger.i("prevUrl: $prevUrl, nextUrl: $nextUrl");
      logger.i("prev: ${prev?.outerHtml}, next: ${next?.outerHtml}");
    }

    return _ChapterNavigation(
      prevPageUrl: prevPage,
      nextPageUrl: nextPage,
      prevChapterUrl: prevChapter,
      nextChapterUrl: nextChapter,
    );
  }

  bool _isPageLink(Element? link, Set<String> pageTexts) {
    return link != null && pageTexts.contains(link.text.trim());
  }

  bool _isCatalog(Element? link) {
    return link != null && {"返回目录", "返回目錄"}.contains(link.text.trim());
  }

  void _cleanChapterContent(Element content) {
    const List<String> contentRemoveSelectors = [
      "div",
      "ins",
      "figure",
      "fig",
      "br",
      "script",
      ".tp",
      ".bd",
    ];
    for (var selector in contentRemoveSelectors) {
      HTMLUtil.removeElements(content.querySelectorAll(selector));
    }
    HTMLUtil.removeElementsByPattern(content, r"[a-z]\d{4}");
  }

  Future<void> _restoreChapterContent(Document doc, Element content) async {
    Map<String, int>? params = await _chapterLogResolver.getShuffleParams(doc);
    if (params != null) {
      BiliNovelRestore.restore(content, params);
    }
  }

  void _fixImgSrc(Element img) {
    String? src = img.attributes["data-src"] ?? img.attributes["src"];
    if (src != null) {
      if (src.startsWith("data:image")) {
        return;
      }
      if (src.contains("<")) {
        img.remove();
      }
      if (src.startsWith("//")) {
        src = "https:$src";
      }
      if (!src.startsWith("http")) {
        src = "$domain/$src";
      }
      src = src.replaceFirst("https://https://", "https://");
      src = src.replaceAll("\ud835\ude23", "b");
      img.attributes["src"] = src;
    }
  }

  void _normalizeImg(Element root) {
    void removeImgAttr(Element img) {
      const Set<String> allowedImageAttributes = {
        "alt",
        "class",
        "dir",
        "height",
        "id",
        "ismap",
        "lang",
        "longdesc",
        "style",
        "title",
        "usemap",
        "width",
        "src",
        "xml:lang",
      };
      for (var attr in img.attributes.keys.toList()) {
        if (!allowedImageAttributes.contains(attr as String)) {
          img.attributes.remove(attr);
        }
      }
    }

    void addImgAlt(Element img, [String alt = ""]) {
      img.attributes["alt"] = alt;
    }

    List<Element> images = root.querySelectorAll("img");
    for (var img in images) {
      _fixImgSrc(img);
      removeImgAttr(img);
      addImgAlt(img);
    }
  }

  Future<String> _readHtml(String url) async {
    if (offline) {
      final cached = await pageCache.readChapter('page:$url');
      if (cached == null) throw StateError('离线模式缺少目录或书籍信息缓存，请先正常下载一次。');
      return cached;
    }
    if (htmlLoader != null) return htmlLoader!(url);
    if (browser != null) return browser!.readHtml(url);
    return (await _dio.get<String>(url)).data ?? '';
  }

  /// A cached text chapter must still restore its page before requesting CDN images.
  Future<void> prepareImageContext(Chapter chapter) async {
    if (browser != null && !offline) {
      await browser!.readHtml(await _requireChapterUrl(chapter));
    }
  }

  /// Check a single chapter without requesting the full book.
  Future<Document> checkChapter(String url) async {
    final id = _getId(url);
    final uri = Uri.parse(url);
    final normalized = Uri.parse(domain).resolve(uri.path).toString();
    final novel = Novel()..id = id..title = '章节检查'..author = ''..status = '';
    final volume = Volume('', Catalog(novel));
    return getNovelChapter(Chapter('章节检查', normalized, volume));
  }

  @override
  Future<Uint8List> getImage(String url) {
    if (url.startsWith("data:image")) {
      var data = url.split(",")[1];
      return Future.value(base64.decode(data));
    }
    if (browser != null) return browser!.readImage(url);
    return _imageDio.get<Uint8List>(url).then((res) => res.data!);
  }
}

class _ChapterNavigation {
  final String? prevPageUrl;
  final String? nextPageUrl;
  final String? prevChapterUrl;
  final String? nextChapterUrl;

  const _ChapterNavigation({
    this.prevPageUrl,
    this.nextPageUrl,
    this.prevChapterUrl,
    this.nextChapterUrl,
  });
}

class ChapterPage {
  String? title;
  List<Element> contents;
  String? prevPageUrl;
  String? nextPageUrl;
  String? prevChapterUrl;
  String? nextChapterUrl;

  ChapterPage(
    this.contents, {
    this.title,
    this.prevPageUrl,
    this.nextPageUrl,
    this.prevChapterUrl,
    this.nextChapterUrl,
  });
}
