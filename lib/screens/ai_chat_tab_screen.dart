import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../models/ssh_host.dart';
import '../providers/ssh_hosts_provider.dart';
import '../providers/chat_provider.dart';
import 'ai_chat_screen.dart';

class AiChatTabScreen extends ConsumerStatefulWidget {
  const AiChatTabScreen({super.key});

  @override
  ConsumerState<AiChatTabScreen> createState() => _AiChatTabScreenState();
}

class _AiChatTabScreenState extends ConsumerState<AiChatTabScreen> {
  String? _selectedHostId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hosts = ref.read(sshHostsProvider);
      if (hosts.isNotEmpty) {
        setState(() => _selectedHostId = hosts.first.id);
      }
    });
  }

  void _onHostChanged(String? hostId) {
    if (hostId == null) return;
    setState(() => _selectedHostId = hostId);
  }

  void _openConversation(ChatConversation? conv) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AiChatScreen(
          hostId: _selectedHostId,
          conversationId: conv?.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(sshHostsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final conversations = _selectedHostId != null
        ? ref
            .watch(chatConversationsProvider.notifier)
            .getByHost(_selectedHostId!)
        : <ChatConversation>[];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AI 助手', style: TextStyle(fontSize: 16)),
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
                                      color: h.id == _selectedHostId
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
            icon: const Icon(Icons.add_comment_outlined),
            onPressed:
                _selectedHostId != null ? () => _openConversation(null) : null,
            tooltip: '新建对话',
          ),
        ],
      ),
      body: hosts.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.smart_toy_outlined,
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
          : conversations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline_outlined,
                          size: 64,
                          color: colorScheme.onSurfaceVariant
                              .withOpacity(0.5)),
                      const SizedBox(height: 16),
                      const Text('还没有对话'),
                      const SizedBox(height: 8),
                      Text(
                        '点击右上角 + 开始新对话',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: conversations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final conv = conversations[index];
                    final lastMsg = conv.messages.isNotEmpty
                        ? conv.messages.last.content
                        : '开始对话吧';
                    return Card(
                      elevation: 0,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colorScheme.primaryContainer,
                          child: Icon(Icons.smart_toy_outlined,
                              color: colorScheme.onPrimaryContainer),
                        ),
                        title: Text(
                          conv.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          lastMsg,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Text(
                          _formatTime(conv.updatedAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        onTap: () => _openConversation(conv),
                      ),
                    );
                  },
                ),
    );
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 2) return '昨天';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}
