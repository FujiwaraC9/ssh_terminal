import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';

class ToolItem {
  final String name;
  final String command;
  final IconData icon;
  final String description;

  const ToolItem({
    required this.name,
    required this.command,
    required this.icon,
    required this.description,
  });
}

const List<ToolItem> _opsTools = [
  ToolItem(
    name: '关闭屏幕',
    command: 'sudo setterm -blank force -powersave powerdown > /dev/tty1 2>&1 && echo "屏幕已关闭"\n',
    icon: Icons.brightness_low_outlined,
    description: '关闭笔记本屏幕',
  ),
  ToolItem(
    name: '点亮屏幕',
    command: 'sudo setterm -blank poke > /dev/tty1 2>&1 && echo "屏幕已点亮"\n',
    icon: Icons.brightness_high_outlined,
    description: '点亮笔记本屏幕',
  ),
  ToolItem(
    name: '启动桌面',
    command: 'sudo systemctl start display-manager && echo "桌面环境已启动"\n',
    icon: Icons.desktop_mac_outlined,
    description: '启动可视化桌面环境',
  ),
  ToolItem(
    name: '关闭桌面',
    command: 'sudo systemctl stop display-manager && echo "桌面环境已关闭"\n',
    icon: Icons.desktop_access_disabled_outlined,
    description: '关闭桌面，降低功耗',
  ),
  ToolItem(
    name: 'SillyTavern 状态',
    command: 'systemctl status sillytavern --no-pager\n',
    icon: Icons.sports_bar_outlined,
    description: '查看酒馆服务状态',
  ),
  ToolItem(
    name: '重启酒馆',
    command: 'systemctl restart sillytavern && echo "酒馆服务已重启"\n',
    icon: Icons.refresh_outlined,
    description: '重启 SillyTavern 服务',
  ),
];

class TerminalScreen extends ConsumerStatefulWidget {
  final String hostId;
  const TerminalScreen({super.key, required this.hostId});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final terminal = Terminal(maxLines: 10000);
  final terminalController = TerminalController();
  SSHClient? _client;
  SSHSession? _session;
  bool _isConnected = false;
  bool _isConnecting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _session?.close();
    _client?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    final host =
        ref.read(sshHostsProvider.notifier).getHostById(widget.hostId);
    if (host == null) {
      setState(() {
        _error = '主机不存在';
        _isConnecting = false;
      });
      return;
    }

    try {
      terminal.write('正在连接 ${host.host}:${host.port}...\r\n');

      final socket = await SSHSocket.connect(
        host.host,
        host.port,
        timeout: const Duration(seconds: 15),
      );

      SSHClient client;
      if (host.privateKey != null && host.privateKey!.isNotEmpty) {
        // 密钥认证
        final keyPairs = SSHKeyPair.fromPem(host.privateKey!);
        client = SSHClient(
          socket,
          username: host.username,
          identities: keyPairs,
        );
      } else {
        // 密码认证
        client = SSHClient(
          socket,
          username: host.username,
          onPasswordRequest: () => host.password ?? '',
        );
      }

      _client = client;
      await client.authenticated;

      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
      terminal.write('\r\n连接成功！\r\n\r\n');

      final session = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: 80,
          height: 24,
        ),
      );

      _session = session;

      session.stdout.listen((data) {
        terminal.write(utf8.decode(data));
      });

      session.stderr.listen((data) {
        terminal.write(utf8.decode(data));
      });

      terminal.onOutput = (data) {
        session.stdin.add(utf8.encode(data));
      };

      session.done.then((_) {
        if (mounted) {
          setState(() => _isConnected = false);
          terminal.write('\r\n\r\n连接已断开\r\n');
        }
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isConnecting = false;
      });
      terminal.write('\r\n连接失败: $e\r\n');
    }
  }

  void _runCommand(String command) {
    if (_session != null && _isConnected) {
      // 直接发送到 SSH 会话，同时在终端显示
      _session!.stdin.add(utf8.encode(command));
    }
  }

  void _showToolPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _buildToolPanel(context),
    );
  }

  Widget _buildToolPanel(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Icon(Icons.handyman_outlined, color: colorScheme.primary),
                    const SizedBox(width: 12),
                    const Text(
                      '工具',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.4,
                  ),
                  itemCount: _opsTools.length,
                  itemBuilder: (context, index) {
                    final tool = _opsTools[index];
                    return Material(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          _runCommand(tool.command);
                          Navigator.pop(context);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  tool.icon,
                                  color: colorScheme.onPrimaryContainer,
                                  size: 22,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                tool.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tool.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final host =
        ref.watch(sshHostsProvider.notifier).getHostById(widget.hostId);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(host?.name ?? '终端',
                style: const TextStyle(fontSize: 16)),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected
                        ? Colors.green
                        : (_isConnecting ? Colors.orange : Colors.red),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _isConnected
                      ? '已连接'
                      : (_isConnecting ? '连接中...' : '已断开'),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            onPressed: _isConnected
                ? () => context.push('/status/${widget.hostId}')
                : null,
            tooltip: '系统状态',
          ),
          IconButton(
            icon: const Icon(Icons.handyman_outlined),
            onPressed: _isConnected ? _showToolPanel : null,
            tooltip: '工具',
          ),
          IconButton(
            icon: const Icon(Icons.smart_toy_outlined),
            onPressed: _isConnected
                ? () => context.push('/ai/${widget.hostId}')
                : null,
            tooltip: 'AI 助手',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            onPressed: () {
              setState(() {
                _isConnecting = true;
                _error = null;
              });
              _connect();
            },
            tooltip: '重新连接',
          ),
        ],
      ),
      body: Container(
        color: const Color(0xFF1E1E1E),
        child: TerminalView(
          terminal,
          controller: terminalController,
          padding: const EdgeInsets.all(8),
        ),
      ),
    );
  }
}
