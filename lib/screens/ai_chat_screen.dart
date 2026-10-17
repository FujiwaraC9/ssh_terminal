import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../providers/ai_config_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/ssh_hosts_provider.dart';
import '../providers/ssh_session_provider.dart';
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

  /// 已展开输出的执行卡片
  final Set<String> _expandedExec = {};

  /// 正在执行中的执行卡片
  final Set<String> _runningExec = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConversation();
    });
  }

  void _loadConversation() {
    if (widget.conversationId != null) {
      final conv = ref
          .read(chatConversationsProvider.notifier)
          .getConversation(widget.conversationId!);
      if (conv != null) {
        setState(() {
          _conversationId = conv.id;
          _messages = List.from(conv.messages);
        });
        _scrollToBottom();
        return;
      }
    }
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

  /// 身份 + 运行环境。Agent 必须清楚自己是谁、命令在哪儿执行，
  /// 否则会反问用户「你在哪个终端里执行这条命令」。
  String _agentIdentity() {
    var target = '一台远程 Linux 服务器';
    final hostId = widget.hostId;
    if (hostId != null) {
      final host = ref.read(sshHostsProvider.notifier).getHostById(hostId);
      if (host != null) {
        target = '远程 Linux 服务器 ${host.username}@${host.host}:${host.port}';
        if (host.name.isNotEmpty) {
          target = '$target（服务器名称：${host.name}）';
        }
      }
    }
    return '你是「SSH 终端」这款 App 内置的运维 AI 助手。\n\n'
        '【运行环境】\n'
        '- 你面对的是用户通过本 App 用 SSH 连接的 $target。\n'
        '- 命令由 App 代你在这台服务器上执行：走 App 内置终端的那条 SSH 连接，'
        '用户点「执行」按钮后就会真正运行，执行结果会回传给你。\n'
        '- 你访问不到用户手机本地的环境，也不需要知道「在哪个终端执行」——'
        '答案永远是「本 App 内置的 SSH 终端，连的就是上面这台服务器」。'
        '所以不要反问用户用的是桌面终端、串口还是虚拟机控制台。\n';
  }

  String _systemPrompt({required bool analyzing}) {
    final identity = _agentIdentity();
    if (analyzing) {
      return '$identity\n'
          '【当前任务】\n'
          '用户刚执行了一条命令，执行结果已经给出。请用中文简要解读结果，'
          '并说明下一步该做什么。如果还需要继续执行命令，'
          '用 ```shell\\n命令\\n``` 格式给出下一条命令（一次只给一条）。';
    }
    return '$identity\n'
        '【工作方式】\n'
        '1. 需要执行命令或排查问题时，用 ```shell\\n命令\\n``` 格式输出，一次只给一条命令。\n'
        '2. 命令要简洁、可直接执行；破坏性操作（rm -rf、格式化、dd、重启服务等）先提醒风险。\n'
        '3. 用中文回答，先一句话说明你要做什么，再给出命令。\n'
        '4. 简单问题直接回答即可，不必都去执行命令。\n'
        '5. 拿到执行结果后，简要解读并给出下一步建议。';
  }

  /// 把对话整理成发给模型的消息列表。
  /// 执行卡片会被还原成「命令 + 执行结果」，让模型能拿到完整上下文。
  List<Map<String, String>> _buildAiMessages(String systemPrompt) {
    final list = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
    ];
    for (final m in _messages) {
      if (m.kind == 'exec') {
        list.add({
          'role': 'assistant',
          'content': '```shell\n${m.command}\n```',
        });
        final out = m.output.trim();
        list.add({
          'role': 'user',
          'content': '命令执行结果:\n\n${out.isEmpty ? '(无输出)' : out}',
        });
      } else {
        if (m.content.trim().isEmpty) continue;
        list.add({'role': m.role, 'content': m.content});
      }
    }
    return list;
  }

  String? _ensureConversation() {
    if (_conversationId != null) return _conversationId;
    if (widget.hostId == null) return null;
    final notifier = ref.read(chatConversationsProvider.notifier);
    final conv = notifier.createConversation(widget.hostId!);
    for (final m in _messages) {
      notifier.addMessage(conv.id, m);
    }
    setState(() => _conversationId = conv.id);
    return conv.id;
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    final aiConfig = ref.read(aiConfigProvider);
    if (aiConfig.apiKey.isEmpty || aiConfig.baseUrl.isEmpty) {
      _snack('请先在设置中配置 API Key 和地址');
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

    final existedBefore = _conversationId != null;
    final convId = _ensureConversation();
    if (convId != null && existedBefore) {
      ref.read(chatConversationsProvider.notifier).addMessage(convId, userMsg);
    }

    final aiMessages = _buildAiMessages(
      widget.hostId != null
          ? _systemPrompt(analyzing: false)
          : '你是一个 AI 助手，请用中文回答用户的问题。',
    );

    try {
      final assistantMsg = ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      setState(() => _messages.add(assistantMsg));
      if (convId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .addMessage(convId, assistantMsg);
      }

      final response = await _aiService.chat(
        config: aiConfig,
        messages: aiMessages,
      );

      if (!mounted) return;
      setState(() {
        assistantMsg.content = response;
        _isLoading = false;
      });
      if (convId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .replaceLastAssistantMessage(convId, response);
      }
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
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

  /// 执行一条命令：复用终端那条共享 SSH 会话，实时显示输出，完成后自动折叠。
  Future<void> _executeAndAnalyze(String command) async {
    final hostId = widget.hostId;
    if (hostId == null) return;

    final handle = ref.read(sshSessionProvider(hostId));

    // 从终端页进来时本来就连着；从底栏进来则先建立连接
    if (!handle.connected && !handle.connecting) {
      final host = ref.read(sshHostsProvider.notifier).getHostById(hostId);
      if (host == null) {
        _snack('找不到服务器配置');
        return;
      }
      setState(() => _isLoading = true);
      await handle.connect(host);
      if (!mounted) return;
    }

    if (!handle.connected) {
      setState(() => _isLoading = false);
      _snack('SSH 未连接，请先回到终端页面连接服务器');
      return;
    }

    final execMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      kind: 'exec',
      command: command,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    setState(() {
      _isLoading = true;
      _messages.add(execMsg);
      _expandedExec.add(execMsg.id);
      _runningExec.add(execMsg.id);
    });
    _scrollToBottom();

    final existedBefore = _conversationId != null;
    final convId = _ensureConversation();
    if (convId != null && existedBefore) {
      ref.read(chatConversationsProvider.notifier).addMessage(convId, execMsg);
    }

    final output = await handle.runAgentCommand(
      command,
      onOutput: (partial) {
        if (!mounted) return;
        setState(() => execMsg.output = partial);
        _scrollToBottom();
      },
    );

    if (!mounted) return;
    setState(() {
      execMsg.output = output;
      _runningExec.remove(execMsg.id);
      // 执行完成自动折叠，需要时点开即可
      _expandedExec.remove(execMsg.id);
    });
    if (convId != null) {
      ref.read(chatConversationsProvider.notifier).persistConversation(convId);
    }
    _scrollToBottom();

    await _analyzeResult();
  }

  /// 把执行结果交给 AI 继续分析
  Future<void> _analyzeResult() async {
    final aiConfig = ref.read(aiConfigProvider);
    final convId = _conversationId;
    final aiMessages = _buildAiMessages(_systemPrompt(analyzing: true));

    final analysisMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _messages.add(analysisMsg));
    if (convId != null) {
      ref
          .read(chatConversationsProvider.notifier)
          .addMessage(convId, analysisMsg);
    }
    _scrollToBottom();

    try {
      final response = await _aiService.chat(
        config: aiConfig,
        messages: aiMessages,
      );
      if (!mounted) return;
      setState(() {
        analysisMsg.content = response;
        _isLoading = false;
      });
      if (convId != null) {
        ref
            .read(chatConversationsProvider.notifier)
            .replaceLastAssistantMessage(convId, response);
      }
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
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
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  void _newChat() {
    setState(() {
      _conversationId = null;
      _expandedExec.clear();
      _runningExec.clear();
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
                      if (msg.kind == 'exec') {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: colorScheme.primary,
                                child: Icon(
                                  Icons.terminal_outlined,
                                  size: 18,
                                  color: colorScheme.onPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(child: _buildExecCard(context, msg)),
                            ],
                          ),
                        );
                      }
                      return _buildTextMessage(context, msg, index);
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

  /// 普通文本消息（用户气泡 / AI Markdown）
  Widget _buildTextMessage(BuildContext context, ChatMessage msg, int index) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = msg.role == 'user';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                                    index == _messages.length - 1 &&
                                    _isLoading
                                ? '_思考中..._'
                                : msg.content,
                            selectable: false,
                            builders: {
                              'pre': _CodeblockBuilder(context),
                            },
                            styleSheet: _markdownStyleSheet(context),
                          ),
                  ),
                  if (!isUser &&
                      widget.hostId != null &&
                      _extractShellCommands(msg.content).isNotEmpty) ...[
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
                              padding: const EdgeInsets.only(bottom: 8),
                              child: FilledButton.tonalIcon(
                                onPressed: _isLoading
                                    ? null
                                    : () => _executeAndAnalyze(entry.value),
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: Expanded(
                                  child: Text(
                                    _truncateCommand(entry.value),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 0),
                                  minimumSize:
                                      const Size(double.infinity, 40),
                                  alignment: Alignment.centerLeft,
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
  }

  /// 命令执行卡片：折叠时只留一行标题，展开后显示命令和终端输出
  Widget _buildExecCard(BuildContext context, ChatMessage msg) {
    final colorScheme = Theme.of(context).colorScheme;
    final expanded = _expandedExec.contains(msg.id);
    final running = _runningExec.contains(msg.id);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (expanded) {
                  _expandedExec.remove(msg.id);
                } else {
                  _expandedExec.add(msg.id);
                }
              });
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal_outlined,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '执行命令 · ${_truncateCommand(msg.command)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (running)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(
                      Icons.check_circle_outline,
                      size: 14,
                      color: Colors.green,
                    ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              color: const Color(0xFF0E1116),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '\$ ${msg.command}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: 1.4,
                            color: Color(0xFF7EE787),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: msg.output));
                          _snack('已复制输出内容');
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.copy_all_outlined,
                            size: 15,
                            color: Color(0xFF8B949E),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(height: 1, color: const Color(0xFF30363D)),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      child: Text(
                        msg.output.isEmpty
                            ? (running ? '等待输出...' : '(无输出)')
                            : msg.output,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          height: 1.4,
                          color: msg.output.isEmpty
                              ? const Color(0xFF8B949E)
                              : const Color(0xFFE6EDF3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 明确指定各元素的颜色，避免 flutter_markdown 默认样式在深色模式下
  /// 出现「浅色背景 + 浅色文字」的不可读组合（默认引用块背景是 Colors.blue.shade100）。
  MarkdownStyleSheet _markdownStyleSheet(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: TextStyle(color: cs.onSurface, fontSize: 14, height: 1.5),
      a: TextStyle(
        color: cs.primary,
        decoration: TextDecoration.underline,
      ),
      code: TextStyle(
        backgroundColor: cs.surface,
        color: cs.onSurface,
        fontFamily: 'monospace',
        fontSize: 13,
      ),
      blockquote: TextStyle(color: cs.onSurface, fontSize: 14, height: 1.5),
      blockquotePadding: const EdgeInsets.all(12),
      blockquoteDecoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
      ),
      h1: TextStyle(color: cs.onSurface, fontSize: 22, fontWeight: FontWeight.bold),
      h2: TextStyle(color: cs.onSurface, fontSize: 19, fontWeight: FontWeight.bold),
      h3: TextStyle(color: cs.onSurface, fontSize: 17, fontWeight: FontWeight.w600),
      h4: TextStyle(color: cs.onSurface, fontSize: 15, fontWeight: FontWeight.w600),
      h5: TextStyle(color: cs.onSurface, fontSize: 14, fontWeight: FontWeight.w600),
      h6: TextStyle(color: cs.onSurface, fontSize: 13, fontWeight: FontWeight.w600),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: TextStyle(color: cs.onSurface, fontWeight: FontWeight.bold),
      listBullet: TextStyle(color: cs.onSurface, fontSize: 14),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      tableBorder: TableBorder.all(color: cs.outlineVariant),
      tableHead: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
      tableBody: TextStyle(color: cs.onSurface, fontSize: 13),
      tableCellsDecoration: BoxDecoration(color: cs.surfaceContainerHigh),
    );
  }

  void _showHistory() {
    if (widget.hostId == null) {
      _snack('请先选择一台服务器');
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
                                      style: const TextStyle(fontSize: 12),
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
                                        _expandedExec.clear();
                                        _runningExec.clear();
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
    final text = element.textContent ?? '';
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                    Clipboard.setData(ClipboardData(text: text));
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
