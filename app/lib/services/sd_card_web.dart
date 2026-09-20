// Web stub for SdCardService — all file I/O is handled in the main
// sd_card_service.dart via SharedPreferences when kIsWeb is true.
// These functions are never actually called on web, but must exist
// to satisfy the conditional import contract.
import 'sd_card_service.dart';

String getBasePath() => '/web-storage';

Future<void> initNative(SdCardService service) async {
  // No-op on web
}

Future<void> appendDailyLogNative({required String role, required String content}) async {
  // No-op on web
}

Future<void> savePersonalModelNative(Map<String, dynamic> data) async {
  // No-op on web
}

Future<Map<String, dynamic>?> loadPersonalModelNative() async {
  return null;
}

Future<void> saveFastCacheNative(Map<String, String> cache) async {
  // No-op on web
}
