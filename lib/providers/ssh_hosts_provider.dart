import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/ssh_host.dart';

class SshHostsNotifier extends StateNotifier<List<SshHost>> {
  SshHostsNotifier() : super([]) {
    _loadHosts();
  }

  void _loadHosts() {
    final box = Hive.box<SshHost>('ssh_hosts');
    state = box.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> addHost(SshHost host) async {
    final box = Hive.box<SshHost>('ssh_hosts');
    await box.put(host.id, host);
    state = [...state, host]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> updateHost(SshHost host) async {
    final box = Hive.box<SshHost>('ssh_hosts');
    await box.put(host.id, host);
    state = state.map((h) => h.id == host.id ? host : h).toList();
  }

  Future<void> deleteHost(String id) async {
    final box = Hive.box<SshHost>('ssh_hosts');
    await box.delete(id);
    state = state.where((h) => h.id != id).toList();
  }

  SshHost? getHostById(String id) {
    try {
      return state.firstWhere((h) => h.id == id);
    } catch (_) {
      return null;
    }
  }
}

final sshHostsProvider =
    StateNotifierProvider<SshHostsNotifier, List<SshHost>>((ref) {
  return SshHostsNotifier();
});
