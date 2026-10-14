import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';

class SystemStatusScreen extends ConsumerStatefulWidget {
  final String hostId;
  const SystemStatusScreen({super.key, required this.hostId});

  @override
  ConsumerState<SystemStatusScreen> createState() =>
      _SystemStatusScreenState();
}

class _SystemStatusScreenState extends ConsumerState<SystemStatusScreen> {
  SSHClient? _client;
  bool _isConnected = false;
  bool _isLoading = true;
  String? _error;
  Timer? _refreshTimer;

  SystemStats _stats = SystemStats();

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _client?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    final host =
        ref.read(sshHostsProvider.notifier).getHostById(widget.hostId);
    if (host == null) {
      setState(() {
        _error = '主机不存在';
        _isLoading = false;
      });
      return;
    }

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

      setState(() {
        _isConnected = true;
        _isLoading = false;
      });

      // 首次刷新
      await _refreshStats();

      // 每 5 秒刷新一次
      _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _refreshStats();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshStats() async {
    if (_client == null || !_isConnected) return;

    try {
      // 执行命令获取系统信息
      final cmd = '''
echo '---CPU---'
cat /proc/stat | head -1
echo '---MEM---'
cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|MemFree|Buffers|Cached'
echo '---DISK---'
df -h / | tail -1
echo '---LOAD---'
cat /proc/loadavg
echo '---UPTIME---'
cat /proc/uptime
echo '---PROC---'
ps aux --no-header | wc -l
echo '---NET---'
cat /proc/net/dev | grep -v lo | tail -3
echo '---END---'
''';

      final result = await _client!.run(cmd);
      final output = utf8.decode(result).trim();
      _parseStats(output);
    } catch (e) {
      // 静默失败，下次重试
    }
  }

  void _parseStats(String output) {
    final lines = output.split('\n');
    final newStats = SystemStats();
    String section = '';

    for (final line in lines) {
      if (line == '---CPU---') {
        section = 'cpu';
        continue;
      } else if (line == '---MEM---') {
        section = 'mem';
        continue;
      } else if (line == '---DISK---') {
        section = 'disk';
        continue;
      } else if (line == '---LOAD---') {
        section = 'load';
        continue;
      } else if (line == '---UPTIME---') {
        section = 'uptime';
        continue;
      } else if (line == '---PROC---') {
        section = 'proc';
        continue;
      } else if (line == '---NET---') {
        section = 'net';
        continue;
      } else if (line == '---END---') {
        break;
      }

      if (section == 'cpu' && line.startsWith('cpu ')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 8) {
          final user = int.tryParse(parts[1]) ?? 0;
          final nice = int.tryParse(parts[2]) ?? 0;
          final system = int.tryParse(parts[3]) ?? 0;
          final idle = int.tryParse(parts[4]) ?? 0;
          final iowait = int.tryParse(parts[5]) ?? 0;
          final irq = int.tryParse(parts[6]) ?? 0;
          final softirq = int.tryParse(parts[7]) ?? 0;

          final total = user + nice + system + idle + iowait + irq + softirq;
          final idleTotal = idle + iowait;

          // 计算 CPU 使用率（和上次对比）
          if (_stats.cpuTotal > 0 && _stats.cpuIdle > 0) {
            final diffTotal = total - _stats.cpuTotal;
            final diffIdle = idleTotal - _stats.cpuIdle;
            if (diffTotal > 0) {
              newStats.cpuUsage =
                  ((diffTotal - diffIdle) / diffTotal * 100);
            }
          }
          newStats.cpuTotal = total;
          newStats.cpuIdle = idleTotal;
        }
      } else if (section == 'mem') {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          final key = parts[0];
          final value = int.tryParse(parts[1]) ?? 0;
          if (key == 'MemTotal:') {
            newStats.memTotal = value / 1024; // MB
          } else if (key == 'MemAvailable:') {
            newStats.memAvailable = value / 1024;
          } else if (key == 'MemFree:') {
            newStats.memFree = value / 1024;
          } else if (key == 'Buffers:') {
            newStats.memBuffers = value / 1024;
          } else if (key == 'Cached:') {
            newStats.memCached = value / 1024;
          }
        }
      } else if (section == 'disk') {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 5) {
          newStats.diskTotal = parts[1];
          newStats.diskUsed = parts[2];
          newStats.diskAvail = parts[3];
          final useStr = parts[4].replaceAll('%', '');
          newStats.diskUsage = double.tryParse(useStr) ?? 0;
        }
      } else if (section == 'load') {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 3) {
          newStats.load1 = double.tryParse(parts[0]) ?? 0;
          newStats.load5 = double.tryParse(parts[1]) ?? 0;
          newStats.load15 = double.tryParse(parts[2]) ?? 0;
        }
      } else if (section == 'uptime') {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.isNotEmpty) {
          final seconds = double.tryParse(parts[0]) ?? 0;
          newStats.uptime = _formatUptime(seconds);
        }
      } else if (section == 'proc') {
        newStats.processCount = int.tryParse(line.trim()) ?? 0;
      }
    }

    // 计算内存使用率
    if (newStats.memTotal > 0) {
      newStats.memUsage =
          ((newStats.memTotal - newStats.memAvailable) /
              newStats.memTotal *
              100);
    }

    if (mounted) {
      setState(() {
        _stats = newStats;
      });
    }
  }

  String _formatUptime(double seconds) {
    final days = (seconds / 86400).floor();
    final hours = ((seconds % 86400) / 3600).floor();
    final mins = ((seconds % 3600) / 60).floor();

    if (days > 0) {
      return '${days}天 ${hours}小时';
    } else if (hours > 0) {
      return '${hours}小时 ${mins}分';
    } else {
      return '${mins}分钟';
    }
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
            const Text('系统状态', style: TextStyle(fontSize: 16)),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  host?.name ?? '',
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
            icon: const Icon(Icons.refresh_outlined),
            onPressed: _refreshStats,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text('连接失败: $_error'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _isLoading = true;
                            _error = null;
                          });
                          _connect();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _buildStatsGrid(colorScheme),
    );
  }

  Widget _buildStatsGrid(ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _refreshStats,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // CPU 和内存
          SizedBox(
            height: 180,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildStatCard(
                    icon: Icons.memory_outlined,
                    title: 'CPU',
                    value: '${_stats.cpuUsage.toStringAsFixed(1)}%',
                    progress: _stats.cpuUsage / 100,
                    color: _stats.cpuUsage > 80
                        ? Colors.red
                        : _stats.cpuUsage > 60
                            ? Colors.orange
                            : Colors.green,
                    colorScheme: colorScheme,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    icon: Icons.sd_storage_outlined,
                    title: '内存',
                    value: '${_stats.memUsage.toStringAsFixed(1)}%',
                    subtitle:
                        '${(_stats.memTotal - _stats.memAvailable).toStringAsFixed(0)} / ${_stats.memTotal.toStringAsFixed(0)} MB',
                    progress: _stats.memUsage / 100,
                    color: _stats.memUsage > 80
                        ? Colors.red
                        : _stats.memUsage > 60
                            ? Colors.orange
                            : Colors.green,
                    colorScheme: colorScheme,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 磁盘
          _buildWideStatCard(
            icon: Icons.storage_outlined,
            title: '磁盘 (/)',
            value: '${_stats.diskUsage.toStringAsFixed(0)}%',
            subtitle: '已用 ${_stats.diskUsed} / 总 ${_stats.diskTotal}，剩余 ${_stats.diskAvail}',
            progress: _stats.diskUsage / 100,
            color: _stats.diskUsage > 80
                ? Colors.red
                : _stats.diskUsage > 60
                    ? Colors.orange
                    : Colors.green,
            colorScheme: colorScheme,
          ),
          const SizedBox(height: 12),

          // 系统负载
          _buildInfoCard(
            icon: Icons.speed_outlined,
            title: '系统负载',
            colorScheme: colorScheme,
            children: [
              _buildInfoRow('1 分钟', _stats.load1.toStringAsFixed(2),
                  colorScheme),
              _buildInfoRow('5 分钟', _stats.load5.toStringAsFixed(2),
                  colorScheme),
              _buildInfoRow('15 分钟', _stats.load15.toStringAsFixed(2),
                  colorScheme),
            ],
          ),
          const SizedBox(height: 12),

          // 运行时间和进程数
          SizedBox(
            height: 110,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildInfoCard(
                    icon: Icons.schedule_outlined,
                    title: '运行时间',
                    colorScheme: colorScheme,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _stats.uptime,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildInfoCard(
                    icon: Icons.account_tree_outlined,
                    title: '进程数',
                    colorScheme: colorScheme,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${_stats.processCount}',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '每 5 秒自动刷新',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
    required double progress,
    required Color color,
    required ColorScheme colorScheme,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWideStatCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required double progress,
    required Color color,
    required ColorScheme colorScheme,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required ColorScheme colorScheme,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class SystemStats {
  double cpuUsage = 0;
  int cpuTotal = 0;
  int cpuIdle = 0;

  double memTotal = 0;
  double memFree = 0;
  double memAvailable = 0;
  double memBuffers = 0;
  double memCached = 0;
  double memUsage = 0;

  String diskTotal = '-';
  String diskUsed = '-';
  String diskAvail = '-';
  double diskUsage = 0;

  double load1 = 0;
  double load5 = 0;
  double load15 = 0;

  String uptime = '-';
  int processCount = 0;
}
