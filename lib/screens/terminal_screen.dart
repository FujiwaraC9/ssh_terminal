import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';

import '../providers/ssh_hosts_provider.dart';
import '../providers/ssh_session_provider.dart';

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
    command:
        'sudo setterm -blank force -powersave powerdown > /dev/tty1 2>&1 && echo "屏幕已关闭"\n',
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
  final terminalController = TerminalController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureConnected());
  }

  /// 复用共享会话：只有没连过才发起新连接
  void _ensureConnected() {
    if (!mounted) return;
    final handle = ref.read(sshSessionProvider(widget.hostId));
    if (handle.connected || handle.connecting) return;

    final host =
        ref.read(sshHostsProvider.notifier).getHostById(widget.hostId);
    if (host == null) {
      handle.terminal.write('主机不存在\r\n');
      return;
    }
    handle.connect(host);
  }

  @override
  void dispose() {
    // 故意不关闭 SSH 会话：Agent 可能正在用它，返回终端时也应该保持连接
    super.dispose();
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
                          ref
                              .read(sshSessionProvider(widget.hostId))
                              .sendRaw(tool.command);
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
    final handle = ref.watch(sshSessionProvider(widget.hostId));
    final host =
        ref.watch(sshHostsProvider.notifier).getHostById(widget.hostId);
    final colorScheme = Theme.of(context).colorScheme;

    final isConnected = handle.connected;
    final isConnecting = handle.connecting;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(host?.name ?? '终端', style: const TextStyle(fontSize: 16)),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected
                        ? Colors.green
                        : (isConnecting ? Colors.orange : Colors.red),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isConnected
                      ? '已连接'
                      : (isConnecting ? '连接中...' : '已断开'),
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
            onPressed: isConnected
                ? () => context.push('/status/${widget.hostId}')
                : null,
            tooltip: '系统状态',
          ),
          IconButton(
            icon: const Icon(Icons.handyman_outlined),
            onPressed: isConnected ? _showToolPanel : null,
            tooltip: '工具',
          ),
          IconButton(
            icon: const Icon(Icons.smart_toy_outlined),
            onPressed: () => context.push('/ai/${widget.hostId}'),
            tooltip: 'AI 助手',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            onPressed: host == null
                ? null
                : () {
                    ref.read(sshSessionProvider(widget.hostId)).reconnect(host);
                  },
            tooltip: '重新连接',
          ),
        ],
      ),
      body: Container(
        color: const Color(0xFF1E1E1E),
        child: TerminalView(
          handle.terminal,
          controller: terminalController,
          padding: const EdgeInsets.all(8),
        ),
      ),
    );
  }
}
