import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// Stable URL keys; raw chapter text is cached before images.
class DownloadCache {
  final Directory root;
  DownloadCache({Directory? root}) : root = root ?? Directory('.bili-cache-v1');

  static String key(String value) {
    var a = 2166136261;
    var b = 5381;
    for (final byte in utf8.encode(value)) {
      a = ((a ^ byte) * 16777619) & 0xffffffff;
      b = ((b * 33) ^ byte) & 0xffffffff;
    }
    return '${a.toRadixString(16).padLeft(8, '0')}${b.toRadixString(16).padLeft(8, '0')}';
  }

  File _file(String kind, String url) => File(p.join(root.path, kind, key(url)));
  Future<String?> readChapter(String url) async {
    final file = _file('chapters', url);
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (value['url'] != url || value['html'] is! String) return null;
      return value['html'] as String;
    } catch (_) { return null; }
  }
  Future<void> saveChapter(String url, String title, String html) =>
      _atomic(_file('chapters', url), utf8.encode(jsonEncode({
        'url': url, 'title': title, 'html': html,
      })));
  Future<Uint8List?> readImage(String url) async {
    final file = _file('images', url);
    if (!await file.exists()) return null;
    final data = await file.readAsBytes();
    return data.isEmpty ? null : data;
  }
  Future<void> saveImage(String url, Uint8List data) =>
      _atomic(_file('images', url), data);
  Future<void> _atomic(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
}
