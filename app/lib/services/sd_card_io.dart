// Native (Android/iOS) implementation for SdCardService file I/O.
// This file is loaded when dart:io is available.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'sd_card_service.dart';

String _basePath = '/sdcard/Aarohi';

String getBasePath() => _basePath;

Future<void> initNative(SdCardService service) async {
  final dir = await _resolveStorageDirectory(service);
  _basePath = dir.path;
  await _ensureSubdirectories(dir);
  await _loadFastCacheNative(service);
}

Future<Directory> _resolveStorageDirectory(SdCardService service) async {
  for (final path in [
    '/storage/8922-0FEC/Android/data/com.mithun.aarohi/files/Aarohi',
    '/sdcard/Android/data/com.mithun.aarohi/files/Aarohi',
    '/sdcard/Download/Aarohi',
    '/data/user/0/com.mithun.aarohi/files/Aarohi',
    '/data/data/com.mithun.aarohi/files/Aarohi',
  ]) {
    try {
      final dir = Directory(path);
      if (await _testWriteAccess(dir)) {
        service.storageTypeValue = path.contains('8922-0FEC')
            ? StorageType.physicalSdCard
            : (path.startsWith('/sdcard') ? StorageType.sharedExternal : StorageType.phoneInternal);
        return dir;
      }
    } catch (_) {}
  }

  final tempDir = Directory('${Directory.systemTemp.path}/Aarohi');
  await tempDir.create(recursive: true);
  service.storageTypeValue = StorageType.phoneInternal;
  return tempDir;
}

Future<bool> _testWriteAccess(Directory dir) async {
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
    final testFile = File('${dir.path}/.test_rw');
    await testFile.writeAsString('test');
    await testFile.delete();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _ensureSubdirectories(Directory baseDir) async {
  for (final sub in ['model', 'cache', 'daily_logs']) {
    final d = Directory('${baseDir.path}/$sub');
    if (!await d.exists()) await d.create(recursive: true);
  }
}

String _pad(int n) => n < 10 ? '0$n' : '$n';

Future<void> appendDailyLogNative({required String role, required String content}) async {
  try {
    final now = DateTime.now();
    final dateStr = '${now.year}-${_pad(now.month)}-${_pad(now.day)}';
    final timeStr = '${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}';
    final file = File('$_basePath/daily_logs/conversation_$dateStr.txt');
    final line = '[$timeStr] ${role.toUpperCase()}: $content\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  } catch (e) {
    debugPrint('Error writing to daily log: $e');
  }
}

Future<void> savePersonalModelNative(Map<String, dynamic> data) async {
  try {
    final file = File('$_basePath/model/personal_model.json');
    await file.writeAsString(jsonEncode(data), flush: true);
  } catch (e) {
    debugPrint('Error saving personal model: $e');
  }
}

Future<Map<String, dynamic>?> loadPersonalModelNative() async {
  try {
    final file = File('$_basePath/model/personal_model.json');
    if (await file.exists()) {
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    }
  } catch (e) {
    debugPrint('Error loading personal model: $e');
  }
  return null;
}

Future<void> _loadFastCacheNative(SdCardService service) async {
  try {
    final file = File('$_basePath/cache/fast_responses.json');
    if (await file.exists()) {
      final content = await file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      service.fastResponseCache.clear();
      for (final entry in map.entries) {
        final val = entry.value.toString().trim();
        if (val.isNotEmpty) {
          service.fastResponseCache[entry.key] = val;
        }
      }
    }
    service.fastResponseCache.removeWhere((k, v) => v.trim().isEmpty);
  } catch (_) {}
}

Future<void> saveFastCacheNative(Map<String, String> cache) async {
  try {
    final file = File('$_basePath/cache/fast_responses.json');
    await file.writeAsString(jsonEncode(cache), flush: true);
  } catch (_) {}
}
