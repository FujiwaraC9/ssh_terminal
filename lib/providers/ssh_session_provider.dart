import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ssh_session_manager.dart';

/// 按服务器 id 共享同一个 SSH 会话。
///
/// 用 keepAlive 让它不随页面销毁而断开，这样从终端进 Agent 再回来连接还在，
/// Agent 也能直接复用终端那条连接执行命令。
final sshSessionProvider =
    ChangeNotifierProvider.family<SshSessionHandle, String>((ref, hostId) {
  final handle = SshSessionHandle(hostId);
  ref.keepAlive();
  ref.onDispose(handle.dispose);
  return handle;
});
