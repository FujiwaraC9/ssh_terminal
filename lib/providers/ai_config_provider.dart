import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/ai_config.dart';

class AiConfigNotifier extends StateNotifier<AiConfig> {
  AiConfigNotifier() : super(AiConfig()) {
    _loadConfig();
  }

  void _loadConfig() {
    final box = Hive.box<AiConfig>('ai_config');
    if (box.isNotEmpty) {
      state = box.values.first;
    }
  }

  Future<void> updateConfig(AiConfig config) async {
    final box = Hive.box<AiConfig>('ai_config');
    await box.put('config', config);
    state = config;
  }

  bool get isConfigured => state.apiKey.isNotEmpty && state.baseUrl.isNotEmpty;
}

final aiConfigProvider =
    StateNotifierProvider<AiConfigNotifier, AiConfig>((ref) {
  return AiConfigNotifier();
});
