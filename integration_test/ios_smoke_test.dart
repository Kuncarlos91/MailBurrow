import 'package:integration_test/integration_test.dart';

import '../test/support/ios_smoke_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runSmokeScenarios();
}
