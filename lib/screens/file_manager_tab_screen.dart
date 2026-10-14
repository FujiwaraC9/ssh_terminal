import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';

// 辅助扩展
extension SftpNameExt on SftpName {
  bool get isDirectory => attr.mode?.type == SftpFileType.directory;
  int? get size => attr.size;
  int? get modifyTime => attr.modifyTime;
}

class FileManagerTabScreen extends ConsumerStatefulWidget {
  const FileManagerTabScreen({super.key});

  @override
  ConsumerState<FileManagerTabScreen> createState() =>
      _FileManagerTabScreenState();
}

class _FileManagerTabScreenState
    extends ConsumerState<FileManagerTabScreen> {
  String? _selectedHostId;
  SSHClient? _client;
  SftpClient? _sftp;
  bool _isConnected = false;
  bool _isLoading = false;
  String? _error;

  String _currentPath = '/';
  List<SftpName> _files = [];
  bool _isLoadingFiles = false;

  final TextEditingController _newFolderController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 初始化时选择第一个主机
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hosts = ref.read(sshHostsProvider);
      if (hosts.isNotEmpty) {
        setState(() => _selectedHostId = hosts.first.id);
        _connect();
      }
    });
  }

  @override
  void dispose() {
    _sftp?.close();
    _client?.close();
    _newFolderController.dispose();
    super.dispose();
  }

  void _onHostChanged(String? hostId) {
    if (hostId == null || hostId == _selectedHostId) return;
    setState(() {
      _selectedHostId = hostId;
      _isConnected = false;
      _files = [];
      _error = null;
    });
    _sftp?.close();
    _client?.close();
    _connect();
  }

  Future<void> _connect() async {
    if (_selectedHostId == null) return;

    final host = ref.read(sshHostsProvider.notifier).getHostById(_selectedHostId!);
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

      _sftp = await client.sftp();

      setState(() {
        _isConnected = true;
        _isLoading = false;
        _error = null;
      });

      // 获取用户主目录
      try {
        final result = await client.run('echo \$HOME');
        final home = utf8.decode(result).trim();
        if (home.isNotEmpty) {
          setState(() => _currentPath = home);
        }
      } catch (_) {}

      _loadFiles();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
        _isConnected = false;
      });
    }
  }

  Future<void> _loadFiles() async {
    if (_sftp == null) return;

    setState(() => _isLoadingFiles = true);

    try {
      final items = await _sftp!.listdir(_currentPath);
      items.sort((a, b) {
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
    setState(() => _currentPath = dir);
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

  Future<void> _uploadFile() async {
    if (_sftp == null) return;

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withReadStream: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final remotePath = path.join(_currentPath, file.name);
    final totalSize = file.size;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          int transferred = 0;
          return AlertDialog(
            title: const Text('上传中'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: totalSize > 0 ? transferred / totalSize : null,
                ),
                const SizedBox(height: 8),
                Text('${_formatSize(transferred)} / ${_formatSize(totalSize)}'),
              ],
            ),
          );
        },
      ),
    );

    try {
      final remoteFile = await _sftp!.open(
        remotePath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );

      final localFile = File(file.path!);
      final localStream = localFile.openRead().map((list) => Uint8List.fromList(list));

      int transferred = 0;
      await remoteFile.write(localStream);

      await remoteFile.close();

      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('上传成功')),
        );
        _loadFiles();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败: $e')),
        );
      }
    }
  }

  Future<void> _downloadFile(SftpName file) async {
    if (_sftp == null || file.isDirectory) return;

    final remotePath = path.join(_currentPath, file.filename);
    final totalSize = file.size ?? 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('下载中'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(file.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_formatSize(totalSize)),
          ],
        ),
      ),
    );

    try {
      // 获取下载目录
      final downloadDir = await getDownloadsDirectory();
      final localDir = downloadDir ?? await getApplicationDocumentsDirectory();
      final localPath = path.join(localDir.path, file.filename);

      final remoteFile = await _sftp!.open(
        remotePath,
        mode: SftpFileOpenMode.read,
      );

      final localFile = File(localPath);
      final sink = localFile.openWrite();

      final stream = remoteFile.read();
      await sink.addStream(stream);
      await sink.close();
      await remoteFile.close();

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到: $localPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
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
                  if (!file.isDirectory) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _downloadFile(file);
                        },
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('下载'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
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
    final hosts = ref.watch(sshHostsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final currentHost = _selectedHostId != null
        ? ref.read(sshHostsProvider.notifier).getHostById(_selectedHostId!)
        : null;

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
                                        color: h.id == _selectedHostId &&
                                                _isConnected
                                            ? Colors.green
                                            : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(h.name,
                                        style: const TextStyle(
                                            fontSize: 13)),
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
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: _isConnected ? _uploadFile : null,
              tooltip: '上传文件',
            ),
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _isConnected ? _showNewFolderDialog : null,
              tooltip: '新建文件夹',
            ),
            IconButton(
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _isConnected ? _loadFiles : _connect,
              tooltip: '刷新',
            ),
          ],
        ),
        body: hosts.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_off_outlined,
                        size: 64,
                        color: colorScheme.onSurfaceVariant
                            .withOpacity(0.5)),
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
                              onPressed: _connect,
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
                                  icon:
                                      const Icon(Icons.arrow_upward_outlined),
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
                                                color: colorScheme
                                                    .onSurfaceVariant,
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
                                                    ? colorScheme
                                                        .primaryContainer
                                                    : colorScheme
                                                        .secondaryContainer,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              child: Icon(
                                                file.isDirectory
                                                    ? Icons.folder_outlined
                                                    : _getFileIcon(
                                                        file.filename),
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
                                                color: colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                            trailing: IconButton(
                                              icon: const Icon(Icons
                                                  .more_vert_outlined),
                                              onPressed: () =>
                                                  _showFileInfo(file),
                                            ),
                                            onTap: () {
                                              if (file.isDirectory) {
                                                final newPath = path.join(
                                                    _currentPath,
                                                    file.filename);
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
