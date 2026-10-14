import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as path;
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';

// 辅助扩展
extension SftpNameExt on SftpName {
  bool get isDirectory =>
      attr.mode?.type == SftpFileType.directory;
  int? get size => attr.size;
  int? get modifyTime => attr.modifyTime;
}

class FileManagerScreen extends ConsumerStatefulWidget {
  final String hostId;
  const FileManagerScreen({super.key, required this.hostId});

  @override
  ConsumerState<FileManagerScreen> createState() =>
      _FileManagerScreenState();
}

class _FileManagerScreenState extends ConsumerState<FileManagerScreen> {
  SSHClient? _client;
  SftpClient? _sftp;
  bool _isConnected = false;
  bool _isLoading = true;
  String? _error;

  String _currentPath = '/';
  List<SftpName> _files = [];
  bool _isLoadingFiles = false;

  final TextEditingController _newFolderController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _sftp?.close();
    _client?.close();
    _newFolderController.dispose();
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

      final client = SSHClient(
        socket,
        username: host.username,
        onPasswordRequest: () => host.password ?? '',
      );

      _client = client;
      await client.authenticated;

      // 连接 SFTP
      _sftp = await client.sftp();

      setState(() {
        _isConnected = true;
        _isLoading = false;
      });

      // 获取用户主目录
      try {
        final result = await client.run('echo \$HOME');
        final home = utf8.decode(result).trim();
        if (home.isNotEmpty) {
          _currentPath = home;
        }
      } catch (_) {}

      _loadFiles();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadFiles() async {
    if (_sftp == null) return;

    setState(() => _isLoadingFiles = true);

    try {
      final items = await _sftp!.listdir(_currentPath);
      items.sort((a, b) {
        // 文件夹在前
        final aIsDir = a.isDirectory;
        final bIsDir = b.isDirectory;
        if (aIsDir != bIsDir) return bIsDir ? 1 : -1;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      setState(() => _files = items);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingFiles = false);
    }
  }

  void _navigateTo(String dir) {
    setState(() {
      _currentPath = dir;
    });
    _loadFiles();
  }

  void _goUp() {
    if (_currentPath == '/') return;
    final parent = path.dirname(_currentPath);
    _navigateTo(parent);
  }

  Future<void> _createFolder() async {
    if (_sftp == null) return;
    final name = _newFolderController.text.trim();
    if (name.isEmpty) return;

    try {
      final newPath = path.join(_currentPath, name);
      await _sftp!.mkdir(newPath);
      if (mounted) {
        Navigator.pop(context);
        _newFolderController.clear();
        _loadFiles();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteFile(SftpName file) async {
    if (_sftp == null) return;
    final filePath = path.join(_currentPath, file.filename);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(
            '确定要删除 "${file.filename}"${file.isDirectory ? '（目录）' : ''} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      if (file.isDirectory) {
        // 递归删除目录
        await _client!.run('rm -rf "$filePath"');
      } else {
        await _sftp!.remove(filePath);
      }
      _loadFiles();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  void _showFileInfo(SftpName file) {
    final attrs = file.attr;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Icon(
                    file.isDirectory
                        ? Icons.folder_outlined
                        : Icons.description_outlined,
                    size: 40,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.filename,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          file.isDirectory ? '文件夹' : '文件',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              _buildInfoRow('大小', _formatSize(file.size)),
              _buildInfoRow(
                  '权限',
                  attrs.mode != null
                      ? attrs.mode!.value.toRadixString(8)
                      : '-'),
              _buildInfoRow(
                  '修改时间',
                  file.modifyTime != null
                      ? DateTime.fromMillisecondsSinceEpoch(
                              file.modifyTime! * 1000)
                          .toString()
                          .substring(0, 19)
                      : '-'),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _deleteFile(file);
                      },
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.red),
                      label: const Text('删除',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatSize(int? size) {
    if (size == null) return '-';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _buildInfoRow(String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host =
        ref.watch(sshHostsProvider.notifier).getHostById(widget.hostId);
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: _currentPath == '/' || !_isConnected,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _currentPath != '/') {
          _goUp();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('文件管理', style: TextStyle(fontSize: 16)),
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
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _isConnected ? _showNewFolderDialog : null,
              tooltip: '新建文件夹',
            ),
            IconButton(
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _isConnected ? _loadFiles : null,
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
                : Column(
                    children: [
                      // 路径导航栏
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          border: Border(
                            bottom: BorderSide(
                                color: colorScheme.outlineVariant),
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_upward_outlined),
                              onPressed:
                                  _currentPath == '/' ? null : _goUp,
                              tooltip: '上一级',
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Text(
                                  _currentPath,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 文件列表
                      Expanded(
                        child: _isLoadingFiles
                            ? const Center(
                                child: CircularProgressIndicator())
                            : _files.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.folder_open_outlined,
                                            size: 64,
                                            color: colorScheme
                                                .onSurfaceVariant
                                                .withOpacity(0.5)),
                                        const SizedBox(height: 16),
                                        Text(
                                          '文件夹为空',
                                          style: TextStyle(
                                            color:
                                                colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: _files.length,
                                    itemBuilder: (context, index) {
                                      final file = _files[index];
                                      if (file.filename == '.' ||
                                          file.filename == '..') {
                                        return const SizedBox.shrink();
                                      }
                                      return ListTile(
                                        leading: Container(
                                          width: 44,
                                          height: 44,
                                          decoration: BoxDecoration(
                                            color: file.isDirectory
                                                ? colorScheme.primaryContainer
                                                : colorScheme
                                                    .secondaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Icon(
                                            file.isDirectory
                                                ? Icons.folder_outlined
                                                : _getFileIcon(file.filename),
                                            color: file.isDirectory
                                                ? colorScheme
                                                    .onPrimaryContainer
                                                : colorScheme
                                                    .onSecondaryContainer,
                                          ),
                                        ),
                                        title: Text(
                                          file.filename,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          file.isDirectory
                                              ? '文件夹'
                                              : _formatSize(file.size),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(
                                              Icons.more_vert_outlined),
                                          onPressed: () =>
                                              _showFileInfo(file),
                                        ),
                                        onTap: () {
                                          if (file.isDirectory) {
                                            final newPath = path.join(
                                                _currentPath, file.filename);
                                            _navigateTo(newPath);
                                          } else {
                                            _showFileInfo(file);
                                          }
                                        },
                                      );
                                    },
                                  ),
                      ),
                    ],
                  ),
      ),
    );
  }

  IconData _getFileIcon(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'svg':
        return Icons.image_outlined;
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
        return Icons.movie_outlined;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'ogg':
        return Icons.music_note_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'zip':
      case 'tar':
      case 'gz':
      case '7z':
      case 'rar':
        return Icons.folder_zip_outlined;
      case 'txt':
      case 'md':
      case 'log':
      case 'conf':
      case 'yaml':
      case 'yml':
      case 'json':
      case 'xml':
      case 'sh':
      case 'py':
      case 'js':
      case 'dart':
      case 'java':
      case 'c':
      case 'cpp':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  void _showNewFolderDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: _newFolderController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '文件夹名称',
            prefixIcon: Icon(Icons.create_new_folder_outlined),
          ),
          onSubmitted: (_) => _createFolder(),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _newFolderController.clear();
              Navigator.pop(context);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _createFolder,
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }
}
