import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mailburrow/state/connection_store.dart';

/// The active saved connection as a version 2 record, the shape tests
/// compare against. Before the v3 index exists (no migration yet, or an
/// unreadable legacy record kept for recovery) it is the raw legacy record.
Future<String?> savedConnectionText() async {
  const storage = FlutterSecureStorage();
  if (await storage.read(key: 'connections') == null) {
    return storage.read(key: 'connection');
  }
  final saved = await const ConnectionStore().read();
  return saved == null
      ? null
      : ConnectionStore.encode(
          serverType: saved.serverType,
          server: saved.server,
          key: saved.key,
          accountId: saved.accountId,
        );
}
