import 'dart:convert';
import 'package:dio/dio.dart';

class AppUpdateInfo {
  final String version;
  final String? releaseNotes;
  final String? downloadUrl;
  final String? apkName;

  AppUpdateInfo({
    required this.version,
    this.releaseNotes,
    this.downloadUrl,
    this.apkName,
  });
}

class UpdateService {
  // GitHub 仓库地址，格式: owner/repo
  // 注意：改成你自己的仓库地址
  static const String githubRepo = 'FujiwaraC9/ssh_terminal';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  /// 检查更新，返回最新版本信息，如果没有更新返回 null
  static Future<AppUpdateInfo?> checkUpdate(String currentVersion) async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$githubRepo/releases/latest',
      );
      if (response.statusCode != 200) return null;

      final data = response.data as Map<String, dynamic>;
      final tagName = data['tag_name'] as String? ?? '';
      // 去掉开头的 v，如 v2.5.0 -> 2.5.0
      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;

      if (latestVersion.isEmpty) return null;

      // 比较版本号
      if (!_isNewerVersion(latestVersion, currentVersion)) {
        return null;
      }

      // 找 APK 下载链接
      String? downloadUrl;
      String? apkName;
      final assets = data['assets'] as List<dynamic>?;
      if (assets != null && assets.isNotEmpty) {
        for (final asset in assets) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          if (name.endsWith('.apk')) {
            downloadUrl = asset['browser_download_url'] as String?;
            apkName = asset['name'] as String?;
            break;
          }
        }
      }

      return AppUpdateInfo(
        version: latestVersion,
        releaseNotes: data['body'] as String?,
        downloadUrl: downloadUrl,
        apkName: apkName,
      );
    } catch (e) {
      return null;
    }
  }

  /// 比较版本号，返回 true 表示 latest 比 current 新
  static bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();
      final len = latestParts.length > currentParts.length
          ? latestParts.length
          : currentParts.length;
      for (int i = 0; i < len; i++) {
        final l = i < latestParts.length ? latestParts[i] : 0;
        final c = i < currentParts.length ? currentParts[i] : 0;
        if (l > c) return true;
        if (l < c) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
