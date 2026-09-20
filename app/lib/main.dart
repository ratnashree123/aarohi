import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/role_select_screen.dart';
import 'services/local_model_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final role = prefs.getString('device_role');

  await Future.wait([
    Supabase.initialize(
      url: Config.supabaseUrl,
      publishableKey: Config.supabaseKey,
    ).timeout(const Duration(seconds: 2), onTimeout: () => Supabase.instance),
    LocalModelService.instance.init(),
  ]);

  runApp(AarohiApp(deviceRole: role));
}

class AarohiApp extends StatefulWidget {
  const AarohiApp({super.key, this.deviceRole});
  final String? deviceRole;

  @override
  State<AarohiApp> createState() => _AarohiAppState();
}

class _AarohiAppState extends State<AarohiApp> {
  String? _role;

  @override
  void initState() {
    super.initState();
    _role = widget.deviceRole;
  }

  Future<void> _setRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_role', role);
    setState(() => _role = role);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aarohi',
      debugShowCheckedModeBanner: false,
      theme: aarohiTheme(),
      home: StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, snapshot) {
          final session = Supabase.instance.client.auth.currentSession;
          if (session == null) return const LoginScreen();
          if (_role == null) return RoleSelectScreen(onSelected: _setRole);
          return HomeShell(deviceRole: _role!);
        },
      ),
    );
  }
}
