import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'models/ssh_host.dart';
import 'models/ai_config.dart';
import 'models/chat_message.dart';
import 'theme/app_theme.dart';
import 'providers/theme_provider.dart';
import 'screens/main_screen.dart';
import 'screens/add_host_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/ai_chat_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/system_status_screen.dart';
import 'screens/file_manager_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 Hive
  await Hive.initFlutter();

  // 注册适配器
  Hive.registerAdapter(SshHostAdapter());
  Hive.registerAdapter(AiConfigAdapter());
  Hive.registerAdapter(ChatMessageAdapter());
  Hive.registerAdapter(ChatConversationAdapter());

  // 打开 Box
  await Hive.openBox<SshHost>('ssh_hosts');
  await Hive.openBox<AiConfig>('ai_config');
  await Hive.openBox('settings');
  await Hive.openBox<ChatConversation>('chat_conversations');

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'SSH Terminal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: _router,
    );
  }
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const MainScreen(),
    ),
    GoRoute(
      path: '/add-host',
      builder: (context, state) {
        final host = state.extra as SshHost?;
        return AddHostScreen(host: host);
      },
    ),
    GoRoute(
      path: '/terminal/:hostId',
      builder: (context, state) {
        final hostId = state.pathParameters['hostId']!;
        return TerminalScreen(hostId: hostId);
      },
    ),
    GoRoute(
      path: '/ai/:hostId',
      builder: (context, state) {
        final hostId = state.pathParameters['hostId'];
        return AiChatScreen(hostId: hostId);
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/status/:hostId',
      builder: (context, state) {
        final hostId = state.pathParameters['hostId']!;
        return SystemStatusScreen(hostId: hostId);
      },
    ),
    GoRoute(
      path: '/files/:hostId',
      builder: (context, state) {
        final hostId = state.pathParameters['hostId']!;
        return FileManagerScreen(hostId: hostId);
      },
    ),
  ],
);
