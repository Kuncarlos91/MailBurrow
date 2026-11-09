import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ios_smoke_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This validates scenario logic only; the device entrypoint uses real storage.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  runSmokeScenarios();
}
