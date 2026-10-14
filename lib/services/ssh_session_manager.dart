import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/ssh_host.dart';

/// 一台服务器对应一个共享的 SSH 会话。
///
/// 终端界面和 AI Agent 都复用同一个句柄，所以：
/// - 从终端进 Agent 再返回，连接不会断
/// - Agent 执行的命令走的就是同一个终端，回终端能看见
class SshSessionHandle extends ChangeNotifier {
  SshSessionHandle(this.hostId);

  final String hostId;

  /// 共享的终端缓冲区，导航切走再回来内容还在
  final Terminal terminal = Terminal(maxLines: 10000);

  SSHClient? _client;
  SSHSession? _session;

  bool connected = false;
  bool connecting = false;
  String? error;

  /// 原始输出字节流，供 Agent 捕获命令结果
  final StreamController<List<int>> _rawOutput =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get rawOutput => _rawOutput.stream;

  bool get isUsable => _session != null && connected;

  Future<void> connect(SshHost host) async {
    if (connecting || connected) return;
    connecting = true;
    error = null;
    notifyListeners();

    try {
      terminal.write('正在连接 ${host.host}:${host.port}...\r\n');

      final socket = await SSHSocket.connect(
        host.host,
        host.port,
        timeout: const Duration(seconds: 15),
      );

      SSHClient client;
      if (host.privateKey != null && host.privateKey!.isNotEmpty) {
        client = SSHClient(
          socket,
          username: host.username,
          identities: SSHKeyPair.fromPem(host.privateKey!),
        );
      } else {
        client = SSHClient(
          socket,
          username: host.username,
          onPasswordRequest: () => host.password ?? '',
        );
      }

      _client = client;
      await client.authenticated;

      final session = await client.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: 120, height: 32),
      );
      _session = session;

      session.stdout.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
        if (!_rawOutput.isClosed) _rawOutput.add(data);
      });

      session.stderr.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
        if (!_rawOutput.isClosed) _rawOutput.add(data);
      });

      terminal.onOutput = (data) {
        session.stdin.add(utf8.encode(data));
      };

      session.done.then((_) {
        connected = false;
        terminal.write('\r\n\r\n连接已断开\r\n');
        notifyListeners();
      });

      connected = true;
      connecting = false;
      terminal.write('\r\n连接成功！\r\n\r\n');
      notifyListeners();
    } catch (e) {
      connected = false;
      connecting = false;
      error = e.toString();
      terminal.write('\r\n连接失败: $e\r\n');
      notifyListeners();
    }
  }

  Future<void> reconnect(SshHost host) async {
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    connected = false;
    connecting = false;
    notifyListeners();
    await connect(host);
  }

  /// 直接把命令打进交互式终端（工具面板用）
  void sendRaw(String command) {
    final session = _session;
    if (session == null || !connected) return;
    session.stdin.add(utf8.encode(command));
  }

  /// Agent 执行命令：走同一条终端会话，实时回报输出，命令结束才返回。
  ///
  /// 结束判定靠一条哨兵 echo，避免依赖提示符格式。
  Future<String> runAgentCommand(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String partial)? onOutput,
  }) async {
    final session = _session;
    if (session == null || !connected) {
      return '(当前没有可用的 SSH 连接，请先回到终端页面连接)';
    }

    final marker = '__TRAE_DONE_${DateTime.now().microsecondsSinceEpoch}__';
    final buffer = <int>[];
    final done = Completer<void>();
    var lastEmit = 0;

    terminal.write('\r\n\x1b[36m── AI 执行命令 ──\x1b[0m\r\n');

    final sub = rawOutput.listen((data) {
      buffer.addAll(data);
      final text = utf8.decode(buffer, allowMalformed: true);

      if (onOutput != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastEmit > 150) {
          lastEmit = now;
          onOutput(_partialView(text, marker));
        }
      }

      if (!done.isCompleted && text.contains(marker)) {
        done.complete();
      }
    });

    session.stdin.add(utf8.encode('$command\n'));
    session.stdin.add(utf8.encode('echo "$marker"\n'));

    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      // 命令长时间没结束，返回已经捕获到的内容
    } finally {
      await sub.cancel();
    }

    return _clean(utf8.decode(buffer, allowMalformed: true), command, marker);
  }

  /// 实时预览：只保留尾部，避免大输出时反复处理整段文本
  String _partialView(String text, String marker) {
    var t = _stripAnsi(text);
    final lines = t.split(RegExp(r'\r?\n'));
    t = lines.where((l) => !l.contains(marker)).join('\n');
    const limit = 4000;
    if (t.length > limit) {
      t = '...(仅显示最新输出)\n${t.substring(t.length - limit)}';
    }
    return t;
  }

  String _clean(String raw, String command, String marker) {
    var text = _stripAnsi(raw);

    // 去掉含哨兵的行（echo 命令行 + 哨兵输出行）
    final lines = text.split(RegExp(r'\r?\n'));
    text = lines.where((l) => !l.contains(marker)).join('\n');

    // 去掉命令本身的回显（只处理开头附近，避免误删输出里的同名文本）
    final idx = text.indexOf(command);
    if (idx >= 0 && idx < 400) {
      text = text.replaceRange(idx, idx + command.length, '');
    }

    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return text.trim();
  }

  String _stripAnsi(String input) {
    return input
        .replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '')
        .replaceAll(RegExp(r'\x1B\][^\x07]*\x07'), '');
  }

  @override
  void dispose() {
    _session?.close();
    _client?.close();
    if (!_rawOutput.isClosed) _rawOutput.close();
    super.dispose();
  }
}
