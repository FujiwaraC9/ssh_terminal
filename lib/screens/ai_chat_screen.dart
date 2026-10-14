import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_config.dart';
import '../models/chat_message.dart';
import '../models/ssh_host.dart';
import '../providers/ai_config_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/ssh_hosts_provider.dart';
import '../services/ai_service.dart';

const _uuid = Uuid();

class AiChatScreen extends ConsumerStatefulWidget {
  final String? hostId;
  final String? conversationId;
  const AiChatScreen({super.key, this.hostId, this.conversationId});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final AiService _aiService = AiService();
  bool _isLoading = false;

  String? _conversationId;
  List<ChatMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConversation();
    });
  }

  void _loadConversation() {
    if (widget.conversationId != null) {
      // 从历史记录打开
      final conv = ref
          .read(chatConversationsProvider.notifier)
          .getConversation(widget.conversationId!);
      if (conv != null) {
        setState(() {
          _conversationId = conv.id;
          _messages = List.from(conv.messages);
        });
        return;
      }
    }
    // 新对话，先不创建，等第一条消息发送时再创建
    setState(() {
      _messages = [
        ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: widget.hostId != null
              ? '你好！我是你的运维 AI 助手。我可以帮你：\n\n• 解释命令的含义\n• 根据需求生成 Linux 命令\n• 排查系统问题\n• 分析日志和错误信息\n\n有什么可以帮你的吗？'
              : '你好！我是你的 AI 助手。请先在设置中配置 API Key 和模型地址，然后就可以开始对话了。',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    final aiConfig = ref.read(aiConfigProvider);
    if (aiConfig.apiKey.isEmpty || aiConfig.baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中配置 API Key 和地址')),
      );
      return;
    }

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() {
      _messages.add(userMsg);
      _isLoading = true;
      _messageController.clear();
    });

    _scrollToBottom();

    // 如果是第一条用户消息，创建对话
    if (_conversationId == null && widget.hostId != null) {
      final conv = ref
          .read(chatConversationsProvider.notifier)
          .createConversation(widget.hostId!);
      // 添加欢迎消息和用户消息
      for (final m in _messages) {
        ref
            .read(chatConversationsProvider.notifier)
            .addMessage(conv.id, m);
      }
      setState(() => _conversationId = conv.id);
    } else if (_conversationId != null) {
      ref
          .read(chatConversationsProvider.notifier)
          .addMessage(_conversationId!, userMsg);
    }

    try {
      // 构建消息列表，加入 system prompt（Agent 模式）
      final messagesList = <Map<String, String>>[];
      if (widget.hostId != null) {
        messagesList.add({
          'role': 'system',
          'content':
              '你是一个专业的 Linux 运维 AI 助手，可以直接帮用户操作服务器。\n\n'
                  '规则：\n'
                  '1. 当用户需要执行命令或排查问题时，用 ```shell\\n命令\\n``` 的格式输出要执行的命令\n'
                  '2. 每次只输出一条命令，执行完再根据结果决定下一步\n'
                  '3. 命令要简洁、安全，破坏性操作（如 rm、格式化等）要提醒用户确认\n'
                  '4. 用中文回答，先说明你要做什么，再给出命令\n'
                  '5. 对于简单问题可以直接回答，不需要都执行命令'
        });
      } else {
        messagesList.add({
          'role': 'system',
          'content': '你是一个 AI 助手，请用中文回答用户的问题。',
        });
      }
      messagesList.addAll(
          _messages.map((m) => {'role': m.role, 'content': m.content}));

      final assistantMsg = ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      setState(() => _messages.add(assistantMsg));

      if (_conversationId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .addMessage(_conversationId!, assistantMsg);
      }

      final response = await _aiService.chat(
        config: aiConfig,
        messages: messagesList,
      );

      setState(() {
        _messages.last.content = response;
        _isLoading = false;
      });

      if (_conversationId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .replaceLastAssistantMessage(_conversationId!, response);
      }

      _scrollToBottom();
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: '出错了: $e',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
        _isLoading = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
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

  // 从 AI 回复中提取 shell 命令
  List<String> _extractShellCommands(String content) {
    final regex = RegExp(r'```shell\n(.*?)```', dotAll: true);
    return regex.allMatches(content).map((m) => m.group(1)!.trim()).toList();
  }

  // 截断命令显示为概览
  String _truncateCommand(String cmd) {
    final firstLine = cmd.split('\n').first.trim();
    if (firstLine.length > 40) {
      return '${firstLine.substring(0, 37)}...';
    }
    return firstLine;
  }

  // 执行命令并返回结果
  Future<String> _executeCommand(String command) async {
    if (widget.hostId == null) return '没有关联服务器';

    final host = ref
        .read(sshHostsProvider.notifier)
        .getHostById(widget.hostId!);
    if (host == null) return '找不到服务器配置';

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

      await client.authenticated;

      final result = await client.run(command);
      final output = utf8.decode(result);

      client.close();
      await client.done;

      return output.isEmpty ? '(命令执行完成，无输出)' : output;
    } catch (e) {
      return '执行失败: $e';
    }
  }

  // 执行命令并把结果发给 AI
  Future<void> _executeAndAnalyze(String command) async {
    setState(() => _isLoading = true);

    // 添加命令执行的消息
    final execMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '🔧 正在执行命令: `$command`',
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _messages.add(execMsg));
    _scrollToBottom();

    if (_conversationId != null) {
      ref
          .read(chatConversationsProvider.notifier)
          .addMessage(_conversationId!, execMsg);
    }

    // 执行命令
    final result = await _executeCommand(command);

    // 显示结果
    final resultMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: '📋 命令执行结果:\n\n$result',
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _messages.add(resultMsg));
    _scrollToBottom();

    if (_conversationId != null) {
      ref
          .read(chatConversationsProvider.notifier)
          .addMessage(_conversationId!, resultMsg);
    }

    // 让 AI 分析结果
    final aiConfig = ref.read(aiConfigProvider);
    try {
      final messagesList = <Map<String, String>>[];
      messagesList.add({
        'role': 'system',
        'content':
            '你是一个专业的 Linux 运维 AI 助手。用户刚刚执行了一条命令，'
                '请分析执行结果并用中文回答用户的问题。如果需要进一步操作，'
                '可以继续用 ```shell\\n命令\\n``` 格式输出下一条命令。'
      });
      messagesList.addAll(
          _messages.map((m) => {'role': m.role, 'content': m.content}));

      final analysisMsg = ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      setState(() => _messages.add(analysisMsg));

      if (_conversationId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .addMessage(_conversationId!, analysisMsg);
      }

      final response = await _aiService.chat(
        config: aiConfig,
        messages: messagesList,
      );

      setState(() {
        _messages.last.content = response;
        _isLoading = false;
      });

      if (_conversationId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .replaceLastAssistantMessage(_conversationId!, response);
      }

      _scrollToBottom();
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: '出错了: $e',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
        _isLoading = false;
      });
      _scrollToBottom();
    }
  }

  void _newChat() {
    setState(() {
      _conversationId = null;
      _messages = [
        ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: widget.hostId != null
              ? '你好！我是你的运维 AI 助手。有什么可以帮你的吗？'
              : '你好！我是你的 AI 助手。',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canPop = widget.hostId == null ||
        ModalRoute.of(context)?.impliesAppBarDismissal == true;

    return Scaffold(
      appBar: AppBar(
        leading: canPop ? null : const SizedBox.shrink(),
        title: const Text('AI 助手'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _newChat,
            tooltip: '新建对话',
          ),
          IconButton(
            icon: const Icon(Icons.history_outlined),
            onPressed: () => _showHistory(),
            tooltip: '历史对话',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      '开始对话吧',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isUser = msg.role == 'user';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          mainAxisAlignment: isUser
                              ? MainAxisAlignment.end
                              : MainAxisAlignment.start,
                          children: [
                            if (!isUser) ...[
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: colorScheme.primary,
                                child: Icon(
                                  Icons.smart_toy_outlined,
                                  size: 18,
                                  color: colorScheme.onPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? colorScheme.primary
                                      : colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectionArea(
                                      child: isUser
                                          ? Text(
                                              msg.content,
                                              style: TextStyle(
                                                color: colorScheme.onPrimary,
                                              ),
                                            )
                                          : MarkdownBody(
                                              data: msg.content.isEmpty &&
                                                      index ==
                                                          _messages.length - 1
                                                  ? '_思考中..._'
                                                  : msg.content,
                                              selectable: false,
                                              builders: {
                                                'pre':
                                                    _CodeblockBuilder(context),
                                              },
                                              styleSheet:
                                                  MarkdownStyleSheet.fromTheme(
                                                Theme.of(context),
                                              ).copyWith(
                                                p: TextStyle(
                                                  color:
                                                      colorScheme.onSurface,
                                                  fontSize: 14,
                                                ),
                                                code: TextStyle(
                                                  backgroundColor:
                                                      colorScheme.surface,
                                                  fontFamily: 'monospace',
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                    ),
                                    // AI 消息且有 shell 命令时，显示执行按钮
                                    if (!isUser &&
                                        widget.hostId != null &&
                                        _extractShellCommands(msg.content)
                                            .isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      const Divider(height: 1),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.terminal_outlined,
                                            size: 16,
                                            color: colorScheme.primary,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '检测到 ${_extractShellCommands(msg.content).length} 条命令',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                              color: colorScheme.primary,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      ..._extractShellCommands(msg.content)
                                          .asMap()
                                          .entries
                                          .map((entry) => Padding(
                                                padding: const EdgeInsets.only(
                                                    bottom: 8),
                                                child:
                                                    FilledButton.tonalIcon(
                                                  onPressed: _isLoading
                                                      ? null
                                                      : () =>
                                                          _executeAndAnalyze(
                                                              entry.value),
                                                  icon: const Icon(
                                                      Icons.play_arrow,
                                                      size: 18),
                                                  label: Expanded(
                                                    child: Text(
                                                      _truncateCommand(
                                                          entry.value),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                          fontSize: 13),
                                                    ),
                                                  ),
                                                  style: FilledButton
                                                      .styleFrom(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 12,
                                                        vertical: 0),
                                                    minimumSize:
                                                        const Size(
                                                            double.infinity,
                                                            40),
                                                    alignment:
                                                        Alignment.centerLeft,
                                                  ),
                                                ),
                                              ))
                                          .toList(),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (isUser) ...[
                              const SizedBox(width: 8),
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: colorScheme.secondary,
                                child: Icon(
                                  Icons.person_outline,
                                  size: 18,
                                  color: colorScheme.onSecondary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: '输入消息...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _isLoading ? null : _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showHistory() {
    if (widget.hostId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一台服务器')),
      );
      return;
    }
    final conversations = ref
        .read(chatConversationsProvider.notifier)
        .getByHost(widget.hostId!);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(28)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        child: Row(
                          children: [
                            const Text(
                              '历史对话',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () {
                                Navigator.pop(context);
                                _newChat();
                              },
                              icon: const Icon(Icons.add),
                              label: const Text('新建'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: conversations.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.chat_bubble_outline_outlined,
                                        size: 64,
                                        color: colorScheme.onSurfaceVariant
                                            .withOpacity(0.5)),
                                    const SizedBox(height: 16),
                                    Text(
                                      '还没有对话记录',
                                      style: TextStyle(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: conversations.length,
                                itemBuilder: (context, index) {
                                  final conv = conversations[index];
                                  return ListTile(
                                    leading: const Icon(
                                        Icons.chat_bubble_outline),
                                    title: Text(
                                      conv.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      DateTime.fromMillisecondsSinceEpoch(
                                              conv.updatedAt)
                                          .toString()
                                          .substring(0, 16),
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    trailing: PopupMenuButton<String>(
                                      onSelected: (value) {
                                        if (value == 'delete') {
                                          ref
                                              .read(
                                                  chatConversationsProvider
                                                      .notifier)
                                              .deleteConversation(conv.id);
                                          setSheetState(() {});
                                          // 如果正在看这个对话，新建一个
                                          if (_conversationId == conv.id) {
                                            _newChat();
                                          }
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Row(
                                            children: [
                                              Icon(Icons.delete_outline,
                                                  color: Colors.red),
                                              SizedBox(width: 8),
                                              Text('删除对话',
                                                  style: TextStyle(
                                                      color: Colors.red)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      setState(() {
                                        _conversationId = conv.id;
                                        _messages =
                                            List.from(conv.messages);
                                      });
                                      _scrollToBottom();
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// 自定义代码块构建器：带复制按钮 + 自动换行
class _CodeblockBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  _CodeblockBuilder(this.context);

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext ctx,
    element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // pre 元素下面有一个 code 子元素
    final text = element.textContent ?? '';
    // 从 code 的 class 属性提取语言，如 "language-shell"
    String? language;
    final children = element.children ?? [];
    if (children.isNotEmpty) {
      try {
        final codeEl = children.first as md.Element;
        final cls = codeEl.attributes['class'] ?? '';
        if (cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
      } catch (_) {}
    }
    final colorScheme = Theme.of(ctx).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(7),
                topRight: Radius.circular(7),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.code,
                  size: 14,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  language ?? 'code',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.primary,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(
                        ClipboardData(text: text));
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('已复制到剪贴板'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Icon(
                    Icons.copy_all_outlined,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: colorScheme.onSurface,
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}