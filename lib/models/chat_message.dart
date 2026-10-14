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

  /// 消息类型：'text' 普通消息，'exec' 命令执行卡片
  @HiveField(4)
  final String kind;

  /// kind == 'exec' 时执行的命令
  @HiveField(5)
  final String command;

  /// kind == 'exec' 时的终端输出（执行过程中会被实时刷新）
  @HiveField(6)
  String output;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.kind = 'text',
    this.command = '',
    this.output = '',
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
