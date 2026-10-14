import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_version.dart';
import '../models/ai_config.dart';
import '../providers/ai_config_provider.dart';
import '../providers/theme_provider.dart';
import '../services/ai_service.dart';
import '../services/update_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _tempController;
  final AiService _aiService = AiService();

  String _selectedModel = '';
  List<String> _modelList = [];
  bool _isLoadingModels = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(aiConfigProvider);
    _apiKeyController = TextEditingController(text: config.apiKey);
    _baseUrlController = TextEditingController(text: config.baseUrl);
    _selectedModel = config.model;
    _tempController = TextEditingController(text: config.temperature.toString());
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _tempController.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();

    if (baseUrl.isEmpty || apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 API 地址和 API Key')),
      );
      return;
    }

    setState(() => _isLoadingModels = true);

    try {
      final models = await _aiService.listModels(
        baseUrl: baseUrl,
        apiKey: apiKey,
      );

      setState(() {
        _modelList = models;
        if (models.isNotEmpty && !models.contains(_selectedModel)) {
          _selectedModel = models.first;
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取到 ${models.length} 个模型')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取模型列表失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingModels = false);
    }
  }

  void _save() {
    final config = AiConfig(
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      model: _selectedModel,
      temperature: double.tryParse(_tempController.text) ?? 0.7,
    );
    ref.read(aiConfigProvider.notifier).updateConfig(config);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionHeader(context, 'AI 配置'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _apiKeyController,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      prefixIcon: Icon(Icons.key_outlined),
                      hintText: 'sk-...',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'API 地址 (Base URL)',
                      prefixIcon: Icon(Icons.link_outlined),
                      hintText: 'https://api.openai.com/v1',
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 模型选择
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _modelList.contains(_selectedModel)
                                  ? _selectedModel
                                  : null,
                              decoration: const InputDecoration(
                                labelText: '模型名称',
                                prefixIcon: Icon(Icons.psychology_outlined),
                              ),
                              items: _modelList
                                  .map((m) => DropdownMenuItem(
                                        value: m,
                                        child: Text(m,
                                            overflow: TextOverflow.ellipsis),
                                      ))
                                  .toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _selectedModel = value);
                                }
                              },
                              hint: Text(_selectedModel.isEmpty
                                  ? '选择模型'
                                  : _selectedModel),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            onPressed: _isLoadingModels ? null : _fetchModels,
                            icon: _isLoadingModels
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.refresh_outlined),
                            tooltip: '获取模型列表',
                          ),
                        ],
                      ),
                      if (_modelList.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '点击右侧按钮从 API 获取可用模型',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _tempController,
                    decoration: const InputDecoration(
                      labelText: '温度 (0.0 - 2.0)',
                      prefixIcon: Icon(Icons.thermostat_outlined),
                      hintText: '0.7',
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存设置'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(context, '外观'),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  title: const Text('跟随系统'),
                  secondary: const Icon(Icons.brightness_auto_outlined),
                  value: ThemeMode.system,
                  groupValue: ref.watch(themeModeProvider),
                  onChanged: (value) {
                    if (value != null) {
                      ref.read(themeModeProvider.notifier).setMode(value);
                    }
                  },
                ),
                const Divider(height: 1),
                RadioListTile<ThemeMode>(
                  title: const Text('浅色模式'),
                  secondary: const Icon(Icons.light_mode_outlined),
                  value: ThemeMode.light,
                  groupValue: ref.watch(themeModeProvider),
                  onChanged: (value) {
                    if (value != null) {
                      ref.read(themeModeProvider.notifier).setMode(value);
                    }
                  },
                ),
                const Divider(height: 1),
                RadioListTile<ThemeMode>(
                  title: const Text('深色模式'),
                  secondary: const Icon(Icons.dark_mode_outlined),
                  value: ThemeMode.dark,
                  groupValue: ref.watch(themeModeProvider),
                  onChanged: (value) {
                    if (value != null) {
                      ref.read(themeModeProvider.notifier).setMode(value);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(context, '关于'),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.system_update_alt_outlined),
              title: const Text('版本'),
              subtitle: const Text('点击检查更新'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('v$kAppVersion'),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
              onTap: _checkForUpdate,
            ),
          ),
          const SizedBox(height: 8),
          const Card(
            child: ListTile(
              leading: Icon(Icons.terminal_outlined),
              title: Text('SSH Terminal'),
              subtitle:
                  Text('支持 SSH 连接、文件管理、运维工具面板、AI Agent'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在检查更新...'),
          ],
        ),
      ),
    );

    final result = await UpdateService.checkUpdate(kAppVersion);
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;

    switch (result.status) {
      case UpdateStatus.upToDate:
        _showMessage('已是最新版本', '当前版本 v$kAppVersion');
        break;
      case UpdateStatus.failed:
        _showMessage('检查更新失败', result.error ?? '未知错误');
        break;
      case UpdateStatus.hasUpdate:
        _showUpdateDialog(result.info!);
        break;
    }
  }

  void _showMessage(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  void _showUpdateDialog(AppUpdateInfo update) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${update.version}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本 v$kAppVersion',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              if (update.releaseNotes != null &&
                  update.releaseNotes!.isNotEmpty)
                Text(
                  update.releaseNotes!,
                  style: const TextStyle(fontSize: 14),
                ),
              const SizedBox(height: 12),
              if (update.apkName != null)
                Text(
                  '文件: ${update.apkName}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: update.downloadUrl != null
                ? () async {
                    final uri = Uri.parse(update.downloadUrl!);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  }
                : null,
            child: const Text('下载更新'),
          ),
        ],
      ),
    );
  }
}
