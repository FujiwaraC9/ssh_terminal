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
/// - Agent 执行的命令与输出会镜像到同一个终端缓冲区，回终端能看见
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
      });

      session.stderr.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
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

  /// 直接把命令打进交互式终端（工具面板用）。
  /// 统一用 \r 收尾，等价于用户按回车，兼容性最好。
  void sendRaw(String command) {
    final session = _session;
    if (session == null || !connected) return;
    session.stdin.add(utf8.encode('${_normalize(command)}\r'));
  }

  /// Agent 执行命令：在共享的 SSH 连接上开一条独立的 exec 通道运行，
  /// 并把「命令 + 实时输出 + 结束标记」镜像写进终端缓冲区。
  ///
  /// 之所以不用交互式 shell 的 stdin：那条 shell 可能正处在密码提示、
  /// 前台进程或未闭合引号等状态，命令会被吞掉导致完全没有输出。
  Future<String> runAgentCommand(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String partial)? onOutput,
  }) async {
    final client = _client;
    final cmd = command.trim();
    if (client == null || cmd.isEmpty) {
      return '(当前没有可用的 SSH 连接，请先回到终端页面连接服务器)';
    }

    // 显式写进终端，保证回到终端一定能看到 Agent 执行了什么
    terminal.write('\r\n\x1b[36m── AI 执行命令 ──\x1b[0m\r\n');
    terminal.write('\x1b[32m\$ $cmd\x1b[0m\r\n');

    final buffer = <int>[];

    SSHSession session;
    try {
      session = await client.execute(cmd);
    } catch (e) {
      terminal.write('\x1b[31m执行失败: $e\x1b[0m\r\n');
      return '执行失败: $e';
    }

    void sink(List<int> data) {
      buffer.addAll(data);
      final text = utf8.decode(data, allowMalformed: true);
      // exec 通道没有 PTY，输出只有 \n，补成 \r\n 终端才不会错行
      terminal.write(text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'));
    }

    // session.done 只代表通道关闭，此时 stdout/stderr 可能还有数据没投递完，
    // 所以必须等两个流都收尾再取结果，否则会拿到空输出。
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    session.stdout.listen(
      sink,
      onDone: () => stdoutDone.complete(),
      onError: (Object _) => stdoutDone.complete(),
    );
    session.stderr.listen(
      sink,
      onDone: () => stderrDone.complete(),
      onError: (Object _) => stderrDone.complete(),
    );

    var lastLen = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (onOutput == null || buffer.length == lastLen) return;
      lastLen = buffer.length;
      onOutput(_preview(utf8.decode(buffer, allowMalformed: true)));
    });

    try {
      await Future.wait([
        session.done,
        stdoutDone.future,
        stderrDone.future,
      ]).timeout(timeout);
    } on TimeoutException {
      session.close();
    } finally {
      ticker.cancel();
    }

    terminal.write('\x1b[36m── 执行结束 ──\x1b[0m\r\n');

    final text = _clean(utf8.decode(buffer, allowMalformed: true));
    return text.isEmpty ? '(命令执行完成，无输出)' : text;
  }

  String _normalize(String command) {
    var cmd = command.replaceAll('\r', '');
    if (cmd.endsWith('\n')) cmd = cmd.substring(0, cmd.length - 1);
    return cmd;
  }

  /// 实时预览：去掉 ANSI，只保留尾部
  String _preview(String raw) {
    var text = _clean(raw);
    const limit = 4000;
    if (text.length > limit) {
      text = '...(仅显示最新输出)\n${text.substring(text.length - limit)}';
    }
    return text;
  }

  String _clean(String raw) {
    return _stripAnsi(raw)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
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
    super.dispose();
  }
}
