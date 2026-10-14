import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';

const _uuid = Uuid();

final chatConversationsProvider =
    StateNotifierProvider<ChatConversationsNotifier, List<ChatConversation>>(
        (ref) {
  return ChatConversationsNotifier();
});

class ChatConversationsNotifier
    extends StateNotifier<List<ChatConversation>> {
  ChatConversationsNotifier() : super([]) {
    _loadAll();
  }

  Box<ChatConversation> get _box => Hive.box<ChatConversation>('chat_conversations');

  void _loadAll() {
    state = _box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<ChatConversation> getByHost(String hostId) {
    return state.where((c) => c.hostId == hostId).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  ChatConversation createConversation(String hostId, {String? title}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = ChatConversation(
      id: _uuid.v4(),
      hostId: hostId,
      title: title ?? '新对话',
      messages: [],
      createdAt: now,
      updatedAt: now,
    );
    _box.put(conv.id, conv);
    state = [conv, ...state];
    return conv;
  }

  ChatConversation? getConversation(String id) {
    return _box.get(id);
  }

  void addMessage(String conversationId, ChatMessage message) {
    final conv = _box.get(conversationId);
    if (conv == null) return;
    conv.messages.add(message);
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    // 自动更新标题（第一条用户消息）
    if (conv.title == '新对话' && message.role == 'user') {
      conv.title = message.content.length > 20
          ? '${message.content.substring(0, 20)}...'
          : message.content;
    }
    conv.save();
    _loadAll();
  }

  void replaceLastAssistantMessage(String conversationId, String content) {
    final conv = _box.get(conversationId);
    if (conv == null || conv.messages.isEmpty) return;
    if (conv.messages.last.role == 'assistant') {
      conv.messages.last.content = content;
      conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
      conv.save();
      _loadAll();
    }
  }

  /// 把对话内已变更的消息（例如执行卡片的输出）落盘
  void persistConversation(String conversationId) {
    final conv = _box.get(conversationId);
    if (conv == null) return;
    conv.updatedAt = DateTime.now().millisecondsSinceEpoch;
    conv.save();
    _loadAll();
  }

  void deleteConversation(String conversationId) {
    _box.delete(conversationId);
    state = state.where((c) => c.id != conversationId).toList();
  }

  void updateTitle(String conversationId, String title) {
    final conv = _box.get(conversationId);
    if (conv == null) return;
    conv.title = title;
    conv.save();
    _loadAll();
  }
}
