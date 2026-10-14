import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';

class TavernScreen extends ConsumerStatefulWidget {
  const TavernScreen({super.key});

  @override
  ConsumerState<TavernScreen> createState() => _TavernScreenState();
}

class _TavernScreenState extends ConsumerState<TavernScreen> {
  String? _selectedHostId;
  SSHClient? _client;
  SSHSession? _session;

  bool _isConnected = false;
  bool _isLoading = false;
  String? _error;

  final ScrollController _scrollController = ScrollController();
  final List<String> _logLines = [];
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hosts = ref.read(sshHostsProvider);
      if (hosts.isNotEmpty) {
        setState(() => _selectedHostId = hosts.first.id);
        _connectAndStartLog();
      }
    });
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _session?.close();
    _client?.close();
    _scrollController.dispose();
    super.dispose();
  }

  void _onHostChanged(String? hostId) {
    if (hostId == null || hostId == _selectedHostId) return;
    setState(() {
      _selectedHostId = hostId;
      _isConnected = false;
      _logLines.clear();
      _error = null;
    });
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _session?.close();
    _client?.close();
    _connectAndStartLog();
  }

  Future<void> _connectAndStartLog() async {
    if (_selectedHostId == null) return;

    final host = ref
        .read(sshHostsProvider.notifier)
        .getHostById(_selectedHostId!);
    if (host == null) return;

    setState(() => _isLoading = true);

    try {
      final socket = await SSHSocket.connect(
        host.host,
        host.port,
        timeout: const Duration(seconds: 15),
      );

      SSHClient client;
      if (host.privateKey != null && host.privateKey!.isNotEmpty) {
        final keyPairs = SSHKeyPair.fromPem(host.privateKey!);
        client = SSHClient(
          socket,
          username: host.username,
          identities: keyPairs,
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

      // 先显示服务状态
      final statusResult = await client.run(
          'systemctl status sillytavern --no-pager -l 2>&1');
      final statusOutput = utf8.decode(statusResult);
      setState(() {
        _logLines.add('═══ 服务状态 ═══');
        _logLines.addAll(statusOutput.trim().split('\n'));
        _logLines.add('');
        _logLines.add('═══ 实时日志 ═══');
      });

      // 启动实时日志
      final session = await client.execute(
        'journalctl -u sillytavern -n 100 -f --no-pager 2>&1',
      );

      _session = session;

      // 监听 stdout
      _stdoutSub = session.stdout
          .map((Uint8List data) => data as List<int>)
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (mounted) {
          setState(() {
            _logLines.add(line);
            if (_logLines.length > 2000) {
              _logLines.removeRange(0, _logLines.length - 2000);
            }
          });
          // 自动滚动到底部
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });

      // 监听 stderr
      _stderrSub = session.stderr
          .map((Uint8List data) => data as List<int>)
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (mounted) {
          setState(() => _logLines.add('[stderr] $line'));
        }
      });

      setState(() {
        _isConnected = true;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
        _isConnected = false;
      });
    }
  }

  Future<void> _restartTavern() async {
    if (_client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重启酒馆'),
        content: const Text('确定要重启 SillyTavern 服务吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重启'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _logLines.add('═══ 正在重启酒馆服务... ═══'));

    try {
      await _client!.run('systemctl restart sillytavern');
      setState(() => _logLines.add('重启命令已发送'));
    } catch (e) {
      setState(() => _logLines.add('重启失败: $e'));
    }
  }

  Future<void> _clearLogs() async {
    setState(() => _logLines.clear());
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(sshHostsProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('酒馆日志', style: TextStyle(fontSize: 16)),
            if (hosts.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 2),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedHostId,
                    isDense: true,
                    itemHeight: 48,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    items: hosts
                        .map((h) => DropdownMenuItem(
                              value: h.id,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color:
                                          h.id == _selectedHostId && _isConnected
                                              ? Colors.green
                                              : Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(h.name,
                                      style:
                                          const TextStyle(fontSize: 13)),
                                ],
                              ),
                            ))
                        .toList(),
                    onChanged: _onHostChanged,
                    selectedItemBuilder: (context) => hosts
                        .map((h) => Text(h.name,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            )))
                        .toList(),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            onPressed: _isConnected
                ? () {
                    _stdoutSub?.cancel();
                    _stderrSub?.cancel();
                    _session?.close();
                    _logLines.clear();
                    _connectAndStartLog();
                  }
                : _connectAndStartLog,
            tooltip: '重新连接',
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt_outlined),
            onPressed: _isConnected ? _restartTavern : null,
            tooltip: '重启酒馆',
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _logLines.isNotEmpty ? _clearLogs : null,
            tooltip: '清空日志',
          ),
        ],
      ),
      body: hosts.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.sports_bar_outlined,
                      size: 64,
                      color:
                          colorScheme.onSurfaceVariant.withOpacity(0.5)),
                  const SizedBox(height: 16),
                  const Text('还没有 SSH 连接'),
                  const SizedBox(height: 8),
                  Text(
                    '请先在「连接」页面添加主机',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 48, color: Colors.red),
                          const SizedBox(height: 16),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              '连接失败: $_error',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _connectAndStartLog,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Colors.black,
                      child: _logLines.isEmpty
                          ? Center(
                              child: Text(
                                '等待日志输出...',
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              itemCount: _logLines.length,
                              itemBuilder: (context, index) {
                                final line = _logLines[index];
                                final color = _getLogColor(line);
                                return SelectableText(
                                  line,
                                  style: TextStyle(
                                    color: color,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                );
                              },
                            ),
                    ),
    );
  }

  Color _getLogColor(String line) {
    if (line.startsWith('═══')) return Colors.cyanAccent;
    if (line.contains('[stderr]')) return Colors.redAccent;
    if (line.contains('ERROR') || line.contains('error')) {
      return Colors.redAccent;
    }
    if (line.contains('WARN') || line.contains('warn')) {
      return Colors.amberAccent;
    }
    if (line.contains('INFO') || line.contains('info')) {
      return Colors.lightGreenAccent;
    }
    return Colors.white70;
  }
}
