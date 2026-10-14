import 'package:hive/hive.dart';

part 'ai_config.g.dart';

@HiveType(typeId: 1)
class AiConfig extends HiveObject {
  @HiveField(0)
  String apiKey;

  @HiveField(1)
  String baseUrl;

  @HiveField(2)
  String model;

  @HiveField(3)
  double temperature;

  AiConfig({
    this.apiKey = '',
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.temperature = 0.7,
  });
}
