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

/// 检查更新的三种结果，用于让界面给出准确反馈，而不是一律显示"已是最新"
enum UpdateStatus { hasUpdate, upToDate, failed }

class UpdateCheckResult {
  final UpdateStatus status;
  final AppUpdateInfo? info;
  final String? error;

  UpdateCheckResult(this.status, {this.info, this.error});
}

class UpdateService {
  // GitHub 仓库地址，格式: owner/repo
  static const String githubRepo = 'FujiwaraC9/ssh_terminal';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: const {'Accept': 'application/vnd.github+json'},
  ));

  /// 检查更新。永远不抛异常，用 UpdateStatus 表达结果。
  static Future<UpdateCheckResult> checkUpdate(String currentVersion) async {
    Map<String, dynamic>? data;
    try {
      data = await _fetchLatestRelease();
    } catch (e) {
      return UpdateCheckResult(UpdateStatus.failed, error: _describeError(e));
    }

    if (data == null) {
      return UpdateCheckResult(UpdateStatus.failed, error: '没有找到任何 Release 发布记录');
    }

    final tagName = (data['tag_name'] as String? ?? '').trim();
    final latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    if (latestVersion.isEmpty) {
      return UpdateCheckResult(UpdateStatus.failed, error: '发布记录里没有版本号');
    }

    if (!_isNewerVersion(latestVersion, currentVersion)) {
      return UpdateCheckResult(UpdateStatus.upToDate);
    }

    String? downloadUrl;
    String? apkName;
    final assets = data['assets'] as List<dynamic>?;
    if (assets != null) {
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk')) {
          downloadUrl = asset['browser_download_url'] as String?;
          apkName = asset['name'] as String?;
          break;
        }
      }
    }

    return UpdateCheckResult(
      UpdateStatus.hasUpdate,
      info: AppUpdateInfo(
        version: latestVersion,
        releaseNotes: data['body'] as String?,
        downloadUrl: downloadUrl,
        apkName: apkName,
      ),
    );
  }

  /// 优先取 /releases/latest；若该接口无数据（例如全是预发布），退回到列表接口取最新一条非草稿。
  static Future<Map<String, dynamic>?> _fetchLatestRelease() async {
    final base = 'https://api.github.com/repos/$githubRepo';

    Object? firstError;
    try {
      final r = await _dio.get('$base/releases/latest');
      final data = r.data;
      if (data is Map && data['tag_name'] != null) {
        return data.cast<String, dynamic>();
      }
    } catch (e) {
      firstError = e;
    }

    try {
      final r = await _dio.get('$base/releases', queryParameters: {'per_page': 20});
      final data = r.data;
      if (data is List) {
        for (final item in data) {
          if (item is Map && item['draft'] != true) {
            return item.cast<String, dynamic>();
          }
        }
      }
      return null;
    } catch (e) {
      throw firstError ?? e;
    }
  }

  static String _describeError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '连接 GitHub 超时，请检查网络（国内网络通常需要代理）';
        case DioExceptionType.connectionError:
          return '无法连接 GitHub，请检查网络（国内网络通常需要代理）';
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          if (code == 404) return '仓库或 Release 不存在（HTTP 404）';
          if (code == 403) return 'GitHub 接口访问受限（HTTP 403，可能是频率限制）';
          return 'GitHub 返回异常状态：HTTP $code';
        default:
          return '请求失败：${e.message ?? e.type.name}';
      }
    }
    return '未知错误：$e';
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
