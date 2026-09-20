import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service that allows Aarohi to lock distracting apps until Mithun finishes his task.
///
/// Usage from chat:
///   "lock instagram and youtube until I finish studying"
///   "task done" / "unlock apps"
///
/// Also integrates with productivity_service for automatic focus sessions.
class AppLockService extends ChangeNotifier {
  AppLockService._();
  static final AppLockService instance = AppLockService._();

  static const MethodChannel _channel = MethodChannel('com.mithun.aarohi/applock');

  final Set<String> _lockedApps = {};
  String _currentTask = '';
  bool _isLockActive = false;

  Set<String> get lockedApps => Set.unmodifiable(_lockedApps);
  String get currentTask => _currentTask;
  bool get isLockActive => _isLockActive;

  // ── Common app name → package mapping (mirrors Kotlin side) ──────────

  static const Map<String, String> knownApps = {
    'instagram': 'com.instagram.android',
    'insta': 'com.instagram.android',
    'ig': 'com.instagram.android',
    'youtube': 'com.google.android.youtube',
    'yt': 'com.google.android.youtube',
    'youtube music': 'com.google.android.apps.youtube.music',
    'yt music': 'com.google.android.apps.youtube.music',
    'twitter': 'com.twitter.android',
    'x': 'com.twitter.android',
    'snapchat': 'com.snapchat.android',
    'snap': 'com.snapchat.android',
    'facebook': 'com.facebook.katana',
    'fb': 'com.facebook.katana',
    'tiktok': 'com.zhiliaoapp.musically',
    'reddit': 'com.reddit.frontpage',
    'whatsapp': 'com.whatsapp',
    'wa': 'com.whatsapp',
    'telegram': 'org.telegram.messenger',
    'tg': 'org.telegram.messenger',
    'netflix': 'com.netflix.mediaclient',
    'chrome': 'com.android.chrome',
    'browser': 'com.android.chrome',
    'discord': 'com.discord',
    'pinterest': 'com.pinterest',
    'linkedin': 'com.linkedin.android',
    'amazon': 'com.amazon.mShop.android.shopping',
    'prime video': 'com.amazon.avod.thirdpartyclient',
    'hotstar': 'in.startv.hotstar',
    'twitch': 'tv.twitch.android.app',
  };

  /// Resolve app name to package name
  String _resolvePackage(String appName) {
    final lower = appName.toLowerCase().trim();
    return knownApps[lower] ?? lower;
  }

  /// Lock a list of app names until the given task is complete.
  /// Example: lockApps(['instagram', 'youtube'], 'finish studying')
  Future<void> lockApps(List<String> appNames, String task) async {
    final packages = appNames.map(_resolvePackage).toList();
    _lockedApps.clear();
    _lockedApps.addAll(packages);
    _currentTask = task;
    _isLockActive = true;

    try {
      if (!kIsWeb) {
        await _channel.invokeMethod('lockApps', {
          'packages': packages,
          'task': task,
        });
      }
    } catch (e) {
      debugPrint('Error locking apps: $e');
    }

    // Save state for persistence
    await _saveState();
    notifyListeners();
  }

  /// Unlock all locked apps (task completed or manual unlock)
  Future<void> unlockApps() async {
    _lockedApps.clear();
    _currentTask = '';
    _isLockActive = false;

    try {
      if (!kIsWeb) {
        await _channel.invokeMethod('unlockApps');
      }
    } catch (e) {
      debugPrint('Error unlocking apps: $e');
    }

    await _saveState();
    notifyListeners();
  }

  /// Check if overlay permission is granted
  Future<bool> hasOverlayPermission() async {
    if (kIsWeb) return false;
    try {
      final result = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Request overlay permission (opens system settings)
  Future<void> requestOverlayPermission() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      debugPrint('Error requesting overlay permission: $e');
    }
  }

  /// Check if usage stats permission is granted
  Future<bool> hasUsagePermission() async {
    if (kIsWeb) return false;
    try {
      final result = await _channel.invokeMethod<bool>('hasUsagePermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Request usage stats permission (opens system settings)
  Future<void> requestUsagePermission() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('requestUsagePermission');
    } catch (e) {
      debugPrint('Error requesting usage permission: $e');
    }
  }

  /// Parse user command to extract app names and task from natural language.
  /// Returns null if the message isn't an app lock command.
  ///
  /// Supported patterns:
  ///   "lock instagram until I finish studying"
  ///   "block youtube and twitter until homework is done"
  ///   "lock instagram for studying"
  ///   "lock instagram to study"
  ///   "lock instagram" (defaults to "your work")
  ///   "block youtube"
  ///   "lock apps" / "lock distracting apps"
  Map<String, dynamic>? parseAppLockCommand(String message) {
    final lower = message.toLowerCase().trim();

    // Must start with or contain lock/block command
    if (!lower.contains('lock') && !lower.contains('block')) return null;

    // Skip unlock commands
    if (isUnlockCommand(message)) return null;

    // Pattern 0: Direct generic lock commands
    if (lower == 'lock' ||
        lower == 'lock apps' ||
        lower == 'lock the apps' ||
        lower == 'lock all apps' ||
        lower == 'block apps' ||
        lower == 'app lock' ||
        lower == 'start app lock' ||
        lower == 'turn on app lock' ||
        lower == 'enable app lock' ||
        lower == 'lock distracting apps' ||
        lower == 'block distracting apps' ||
        lower == 'focus mode' ||
        lower == 'turn on focus mode') {
      return _buildResult('distracting', 'finishing your work');
    }

    // Pattern 1: lock/block <apps> until/till/before <task>
    final untilMatch = RegExp(
      r'(?:lock|block|app\s*lock)\s+(.+?)\s+(?:until|till|before)\s+(.+)',
      caseSensitive: false,
    ).firstMatch(lower);

    if (untilMatch != null) {
      final appsStr = untilMatch.group(1)!;
      final task = untilMatch.group(2)!
          .replaceFirst(RegExp(r'^i\s+'), '')
          .replaceFirst(RegExp(r'^(?:finish|complete|done with)\s+'), '')
          .trim();
      return _buildResult(appsStr, task);
    }

    // Pattern 2: lock/block <apps> for/to <task>
    final forMatch = RegExp(
      r'(?:lock|block)\s+(.+?)\s+(?:for|to)\s+(.+)',
      caseSensitive: false,
    ).firstMatch(lower);

    if (forMatch != null) {
      final appsStr = forMatch.group(1)!;
      final task = forMatch.group(2)!.trim();
      return _buildResult(appsStr, task);
    }

    // Pattern 3: lock/block <apps> (no task specified)
    final simpleMatch = RegExp(
      r'(?:please\s+)?(?:lock|block)\s+(.+)',
      caseSensitive: false,
    ).firstMatch(lower);

    if (simpleMatch != null) {
      final appsStr = simpleMatch.group(1)!.replaceAll(RegExp(r'\bplease\b'), '').trim();
      return _buildResult(appsStr, 'finishing your work');
    }

    return null;
  }

  Map<String, dynamic> _buildResult(String appsStr, String task) {
    final cleanAppsStr = appsStr
        .replaceAll(RegExp(r'\b(?:the|my|app|apps)\b'), '')
        .trim();

    if (cleanAppsStr.isEmpty || cleanAppsStr == 'distracting' || cleanAppsStr == 'all') {
      return {
        'apps': ['instagram', 'youtube', 'snapchat', 'twitter', 'reddit'],
        'task': task.isEmpty ? 'finishing your work' : task,
      };
    }

    // Split by "and", ",", or "&"
    final appNames = cleanAppsStr
        .split(RegExp(r'\s*(?:and|,|&)\s*'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return {
      'apps': appNames.isEmpty ? ['instagram'] : appNames,
      'task': task.isEmpty ? 'finishing your work' : task,
    };
  }

  /// Check for unlock/task-done commands (comprehensive natural language matching)
  bool isUnlockCommand(String message) {
    final lower = message.toLowerCase().trim();
    if (lower == 'unlock' ||
        lower == 'done' ||
        lower == 'finished' ||
        lower == "i'm done" ||
        lower == 'i am done' ||
        lower == 'all done') {
      return true;
    }

    final unlockPatterns = [
      r'\bunlock\b',
      r'\bunblock\b',
      r'\b(?:i\s+)?(?:have\s+)?completed\s+(?:my\s+)?(?:task|work|study|goal)\b',
      r'\btask\s+(?:is\s+)?(?:complete|completed|done|finished)\b',
      r'\bwork\s+(?:is\s+)?(?:complete|completed|done|finished)\b',
      r'\bstudy\s+(?:is\s+)?(?:complete|completed|done|finished)\b',
      r'\bfinished\s+(?:my\s+)?(?:task|work|study|all)\b',
      r'\b(?:i\s+)?(?:have\s+)?finished\s+(?:my\s+)?task\b',
      r'\bdone\s+with\s+(?:my\s+)?(?:task|work|study)\b',
      r'\b(?:remove|disable|stop|turn\s+off|clear)\s+(?:the\s+)?(?:app\s+)?lock\b',
      r'\b(?:free|open)\s+(?:my\s+)?(?:apps?|phone)\b',
    ];

    for (final pattern in unlockPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(lower)) {
        return true;
      }
    }
    return false;
  }

  /// Build context string for AI prompt
  String buildAppLockContext() {
    if (!_isLockActive) return '';
    final appNames = _lockedApps
        .map((pkg) =>
            knownApps.entries
                .where((e) => e.value == pkg)
                .map((e) => e.key)
                .firstOrNull ??
            pkg)
        .join(', ');
    return '''
[FOCUS MODE ACTIVE - STRICT BOSSY LOCKDOWN]
Locked apps: $appNames
Required task: $_currentTask
Aarohi is strictly holding Mithun accountable. She acts bossy, commanding, and demanding. She will NOT tolerate slacking off or excuses until "$_currentTask" is completed.
If he says "task done" or "unlock apps", verify he actually finished it and then unlock.
''';
  }

  // ── Persistence ──────────────────────────────────────────────────────

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('applock_packages', _lockedApps.toList());
    await prefs.setString('applock_task', _currentTask);
    await prefs.setBool('applock_active', _isLockActive);
  }

  Future<void> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    _isLockActive = prefs.getBool('applock_active') ?? false;
    _currentTask = prefs.getString('applock_task') ?? '';
    final pkgs = prefs.getStringList('applock_packages') ?? [];
    _lockedApps.clear();
    _lockedApps.addAll(pkgs);

    // If lock was active, re-engage the native service
    if (_isLockActive && _lockedApps.isNotEmpty && !kIsWeb) {
      try {
        await _channel.invokeMethod('lockApps', {
          'packages': _lockedApps.toList(),
          'task': _currentTask,
        });
      } catch (_) {}
    }
    notifyListeners();
  }
}
