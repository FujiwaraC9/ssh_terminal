import 'package:hive/hive.dart';

part 'ssh_host.g.dart';

@HiveType(typeId: 0)
class SshHost extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String host;

  @HiveField(3)
  int port;

  @HiveField(4)
  String username;

  @HiveField(5)
  String? password;

  @HiveField(6)
  String? privateKey;

  @HiveField(7)
  DateTime createdAt;

  SshHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    required this.createdAt,
  });
}
