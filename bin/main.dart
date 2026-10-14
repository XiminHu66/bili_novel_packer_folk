import 'dart:io';
import 'package:bili_novel_packer/local/browser_session.dart';
import 'package:bili_novel_packer/console/console.dart';
import 'package:bili_novel_packer/console/prompt.dart';
import 'package:bili_novel_packer/console/selector.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_model.dart';
import 'package:bili_novel_packer/light_novel/base/light_novel_source.dart';
import 'package:bili_novel_packer/light_novel/bili_novel/bili_novel_source.dart';
import 'package:bili_novel_packer/light_novel/wenku_novel/wenku_novel_source.dart';
import 'package:bili_novel_packer/logger.dart';
import 'package:bili_novel_packer/novel_packer.dart';
import 'package:bili_novel_packer/pack_option.dart';

const String gitUrl = "https://github.com/XiminHu66/bili_novel_packer_folk";
const String version = "0.2.50-local5";
final browser = BrowserSession();
bool textOnly = false;
bool offline = false;
bool downloadAll = false;

List<LightNovelSource> sources = [
  BiliNovelSource(browser: browser),
  WenkuNovelSource(),
];

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    print('Bili Novel Packer 0.2.50-local5\n'
        '双击运行，或: bili_novel_packer.exe [选项] [小说/章节URL]\n'
        '--text-only  只下载文字，插图不阻塞打包\n'
        '--offline    从缓存打包已有章节（不启动 Chrome）\n'
        '--all        下载所有分卷并合并\n'
        '--check URL  仅检查该章节的正文与分页\n'
        '--check-images URL  检查该章节正文和前三张插图\n'
        '--help       显示说明\n'
        '输出在当前目录；登录状态在本机专用 Chrome 目录。');
    return;
  }
  textOnly = args.contains('--text-only');
  offline = args.contains('--offline');
  downloadAll = args.contains('--all');
  sources = [BiliNovelSource(browser: browser, offline: offline), WenkuNovelSource()];
  final urls = args.where((a) => a.startsWith('https://') || a.startsWith('http://')).toList();
  printWelcome();
  try {
    if (args.contains('--check') || args.contains('--check-images')) {
      if (urls.length != 1 || offline) {
        throw ArgumentError('--check 需要一个章节链接，不能与 --offline 合用。');
      }
      final source = sources.first as BiliNovelSource;
      if (!source.supportUrl(urls.single)) throw ArgumentError('不支持的章节链接。');
      final uri = Uri.parse(urls.single);
      await browser.prepareLogin(Uri.parse(BiliNovelSource.domain).resolve(uri.path).toString());
      final doc = await source.checkChapter(urls.single);
      final count = doc.body?.text.trim().length ?? 0;
      if (count == 0) throw StateError('章节正文为空。');
      print('章节检查通过：正文 $count 字符，插图 ${doc.querySelectorAll("img").length} 张。');
      if (args.contains('--check-images')) {
        final images = doc.querySelectorAll('img').take(3).toList();
        for (var i = 0; i < images.length; i++) {
          final url = images[i].attributes['src'];
          if (url == null) continue;
          final bytes = await source.getImage(url).timeout(const Duration(seconds: 60));
          if (bytes.isEmpty) throw StateError('插图为空。');
          print('插图 ${i + 1}/${images.length} 检查通过：${bytes.length} 字节。');
        }
      }
      return;
    }
    if (urls.isNotEmpty) {
      for (final url in urls) {
        final source = detectSource(url);
        if (source == null) throw ArgumentError('不支持的URL: $url');
        await runOne(url, source, !downloadAll);
      }
    } else {
      while (true) {
        await start();
        console.writeLine('继续下载其他小说? 输入 y 继续，其余退出。');
        if (console.readLine()?.trim().toLowerCase() != 'y') break;
      }
    }
  } catch (error, stack) {
    logger.e(error, stackTrace: stack);
    console.writeLine('\n下载停止: $error');
    console.writeLine('已完成文字和插图保存在缓存中；重新运行可继续。');
    console.writeLine('若产生 .partial.epub，这是未完成版本，不代表整本已下载。');
    exitCode = 1;
    if (urls.isEmpty) {
      console.writeLine('按 Enter 退出。');
      console.readLine();
    }
  } finally {
    await browser.close();
  }
}

void printWelcome() {
  logger.i("version: $version");
  console.writeLine("欢迎使用轻小说打包器!");
  console.writeLine("作者: Spark");
  console.writeLine("当前版本: $version");
  console.writeLine("如遇报错请先查看能否正常访问输入网址");
  console.writeLine("否则请至开源地址携带报错信息进行反馈: $gitUrl");
}

Future<void> start() async {
  var pairs = readUrlSource();
  if (pairs.length == 1) {
    var (url, source) = pairs.first;
    await runOne(url, source, true);
  } else {
    await runMany(pairs);
  }
}

Future<void> runOne(String url, LightNovelSource source, bool manual) async {
  logger.i("URL: $url");

  if (source is BiliNovelSource && !offline && !browser.connected) {
    final uri = Uri.parse(url);
    await browser.prepareLogin(Uri.parse(BiliNovelSource.domain).resolve(uri.path).toString());
  }
  console.writeLine("正在加载数据...");
  var novel = await source.getNovel(url);
  logger.i(novel);
  printNovelDetail(novel);
  var catalog = await source.getNovelCatalog(novel);
  PackOption option;
  bool combineVolume;
  if (manual && !downloadAll) {
    (option, combineVolume) = readPackOption(catalog);
  } else {
    option = PackOption.all(
      addChapterTitle: false,
      selectedVolumes: catalog.volumes,
    );
    combineVolume = downloadAll;
  }
  logger.i("option: $option, combineVolume: $combineVolume");
  await pack(
    source: source,
    novel: novel,
    option: option,
    combineVolume: combineVolume,
  );
}

Future<void> runMany(List<(String, LightNovelSource)> pairs) async {
  var continuousMode = "连续模式: 无需手动介入，所有选项使用默认";
  var manualMode = "手动模式：每次需手动介入，需手动选择选项";
  var manual =
      Selector(
        options: [continuousMode, manualMode],
        prefix: "\n",
        message: '检测到多个链接，请选择工作模式：',
        defaultValue: continuousMode,
      ).selectOne() ==
      manualMode;
  for (var (url, source) in pairs) {
    await runOne(url, source, manual);
  }
}

List<(String, LightNovelSource)> readUrlSource() {
  do {
    console.writeLine("请输入链接(多个链接使用空格隔开):");
    var input = console.readLine();
    if (input == null || input.trim().toLowerCase() == "q") return [];
    if (input.trim() == "") {
      continue;
    }
    input = input.trim();
    var inputs = input.split(RegExp("\\s+"));
    var pairs = <(String, LightNovelSource)>[];
    var err = false;
    for (var url in inputs) {
      url = url.trim();
      if (url.isEmpty) continue;
      var s = detectSource(url);
      if (s == null) {
        console.writeLine("不支持的URL: $url\n");
        err = true;
        break;
      } else {
        pairs.add((url, s));
      }
    }
    if (!err) return pairs;
  } while (true);
}

LightNovelSource? detectSource(String url) {
  for (var source in sources) {
    if (source.supportUrl(url)) {
      return source;
    }
  }
  return null;
}

void printNovelDetail(Novel novel) {
  console.writeLine();
  console.write(novel.toString());
  console.writeLine();
}

(PackOption, bool) readPackOption(Catalog catalog) {
  var option = PackOption();
  var combineVolume = false;
  option.selectedVolumes = Selector(
    options: catalog.volumes,
    message: "请选择要下载的分卷: ",
    suffix: "选择全部\n",
  ).selectMany();

  if (option.selectedVolumes.length > 1) {
    console.writeLine();
    combineVolume = Prompt(
      "是否合并选择的分卷为一个文件? ",
      defaultValue: false,
    ).prompt();
  }

  console.writeLine();
  option.addChapterTitle = Prompt(
    "是否在每章开头添加章节标题? ",
    defaultValue: false,
  ).prompt();
  console.writeLine();
  return (option, combineVolume);
}

Future<void> pack({
  required LightNovelSource source,
  required Novel novel,
  required PackOption option,
  required bool combineVolume,
}) async {
  if (combineVolume && option.selectedVolumes.length <= 1) {
    combineVolume = false;
  }
  var packer = NovelPacker(source, textOnly: textOnly, offline: offline);
  if (combineVolume) {
    await packer.packCombine(source: source, novel: novel, option: option);
  } else {
    for (var volume in option.selectedVolumes) {
      await packer.packVolume(source: source, volume: volume, option: option);
    }
  }
}
