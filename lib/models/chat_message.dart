import 'package:hive/hive.dart';

part 'chat_message.g.dart';

@HiveType(typeId: 3)
class ChatMessage extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String role; // 'user' or 'assistant'

  @HiveField(2)
  String content;

  @HiveField(3)
  final int timestamp;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
  });
}

@HiveType(typeId: 4)
class ChatConversation extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String hostId;

  @HiveField(2)
  String title;

  @HiveField(3)
  List<ChatMessage> messages;

  @HiveField(4)
  final int createdAt;

  @HiveField(5)
  int updatedAt;

  ChatConversation({
    required this.id,
    required this.hostId,
    required this.title,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });
}
