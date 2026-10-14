import 'package:dio/dio.dart';
import '../models/ai_config.dart';

class AiService {
  final Dio _dio = Dio();

  Future<String> chat({
    required AiConfig config,
    required List<Map<String, String>> messages,
  }) async {
    try {
      final response = await _dio.post(
        '${config.baseUrl}/chat/completions',
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': config.model,
          'temperature': config.temperature,
          'messages': messages,
        },
      );
      return response.data['choices'][0]['message']['content'] as String;
    } catch (e) {
      throw 'AI 调用失败: $e';
    }
  }

  Future<String> analyzeCommand({
    required AiConfig config,
    required String command,
    required String context,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content':
            '你是一个专业的 Linux 运维助手。请用简洁的中文回答用户的问题。'
                '对于命令解释，请说明命令的作用、参数含义和使用场景。'
                '对于排错问题，请给出可能的原因和解决步骤。'
      },
      {
        'role': 'user',
        'content': '上下文信息：$context\n\n问题：$command'
      },
    ];
    return chat(config: config, messages: messages);
  }

  Future<String> generateCommand({
    required AiConfig config,
    required String description,
    required String systemInfo,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content':
            '你是一个 Linux 命令生成专家。用户会用自然语言描述需求，'
                '你只需要返回对应的 Linux 命令，不要解释，不要加任何额外文字。'
                '如果有多个命令，用 && 连接。'
      },
      {
        'role': 'user',
        'content': '系统信息：$systemInfo\n\n需求：$description'
      },
    ];
    return chat(config: config, messages: messages);
  }

  Future<List<String>> listModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    try {
      final response = await _dio.get(
        '$baseUrl/models',
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
      );
      final data = response.data;
      if (data is Map && data['data'] is List) {
        return (data['data'] as List)
            .map((m) => m['id'].toString())
            .where((id) => id.contains('gpt') || id.contains('model') || id.length > 3)
            .toList()
          ..sort();
      }
      return [];
    } catch (e) {
      rethrow;
    }
  }
}
