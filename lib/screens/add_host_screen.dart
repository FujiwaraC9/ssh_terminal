import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';

class AddHostScreen extends ConsumerStatefulWidget {
  final SshHost? host;
  const AddHostScreen({super.key, this.host});

  @override
  ConsumerState<AddHostScreen> createState() => _AddHostScreenState();
}

class _AddHostScreenState extends ConsumerState<AddHostScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  AuthType _authType = AuthType.password;

  bool get _isEditing => widget.host != null;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    _nameController = TextEditingController(text: h?.name ?? '');
    _hostController = TextEditingController(text: h?.host ?? '');
    _portController = TextEditingController(text: h?.port.toString() ?? '22');
    _usernameController = TextEditingController(text: h?.username ?? '');
    _passwordController = TextEditingController(text: h?.password ?? '');
    if (h?.privateKey != null && h!.privateKey!.isNotEmpty) {
      _authType = AuthType.key;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _importKeyFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        dialogTitle: '选择私钥文件',
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      String content;
      if (file.bytes != null) {
        content = String.fromCharCodes(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }
      setState(() {
        _passwordController.text = content.trim();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入: ${file.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final host = SshHost(
      id: widget.host?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      host: _hostController.text.trim(),
      port: int.parse(_portController.text),
      username: _usernameController.text.trim(),
      password: _authType == AuthType.password ? _passwordController.text : null,
      privateKey: _authType == AuthType.key ? _passwordController.text : null,
      createdAt: widget.host?.createdAt ?? DateTime.now(),
    );

    if (_isEditing) {
      ref.read(sshHostsProvider.notifier).updateHost(host);
    } else {
      ref.read(sshHostsProvider.notifier).addHost(host);
    }

    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑连接' : '添加连接'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '名称',
                prefixIcon: Icon(Icons.label_outlined),
                hintText: '我的服务器',
              ),
              validator: (v) =>
                  v?.isEmpty == true ? '请输入名称' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: '主机地址',
                prefixIcon: Icon(Icons.dns_outlined),
                hintText: '192.168.1.1 或 example.com',
              ),
              validator: (v) =>
                  v?.isEmpty == true ? '请输入主机地址' : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      prefixIcon: Icon(Icons.settings_ethernet_outlined),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      if (v?.isEmpty == true) return '请输入端口';
                      final port = int.tryParse(v!);
                      if (port == null || port < 1 || port > 65535) {
                        return '端口范围 1-65535';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) =>
                        v?.isEmpty == true ? '请输入用户名' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SegmentedButton<AuthType>(
              segments: const [
                ButtonSegment(
                  value: AuthType.password,
                  label: Text('密码'),
                  icon: Icon(Icons.lock_outline),
                ),
                ButtonSegment(
                  value: AuthType.key,
                  label: Text('密钥'),
                  icon: Icon(Icons.vpn_key_outlined),
                ),
              ],
              selected: {_authType},
              onSelectionChanged: (s) {
                setState(() => _authType = s.first);
                _passwordController.clear();
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _authType == AuthType.password,
              maxLines: _authType == AuthType.key ? 6 : 1,
              decoration: InputDecoration(
                labelText: _authType == AuthType.password ? '密码' : '私钥',
                prefixIcon: Icon(
                  _authType == AuthType.password
                      ? Icons.lock_outline
                      : Icons.key_outlined,
                ),
                hintText: _authType == AuthType.key
                    ? '-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----'
                    : null,
              ),
              validator: (v) =>
                  v?.isEmpty == true ? '请输入${_authType == AuthType.password ? '密码' : '私钥'}' : null,
            ),
            if (_authType == AuthType.key) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _importKeyFile,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('从文件导入私钥'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_isEditing ? '保存修改' : '添加连接'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum AuthType { password, key }
