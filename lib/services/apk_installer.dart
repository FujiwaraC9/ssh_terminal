import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 应用内下载 APK 并直接调起系统安装器（不跳浏览器）。
class ApkInstaller {
  static const MethodChannel _channel = MethodChannel('ssh_terminal/installer');

  static Future<File> downloadApk(
    String url, {
    required String fileName,
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) {
      await file.delete();
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 10),
    ));

    await dio.download(url, file.path, onReceiveProgress: onProgress);
    return file;
  }

  static Future<void> install(File apk) async {
    await _channel.invokeMethod('installApk', {'path': apk.path});
  }

  static Future<void> openInstallSettings() async {
    await _channel.invokeMethod('openInstallSettings');
  }
}
