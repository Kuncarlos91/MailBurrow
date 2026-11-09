import 'package:flutter_test/flutter_test.dart';
import 'package:mailburrow/build_information.dart';

void main() {
  test('unstamped build does not claim an old release version', () {
    if (buildVersion.isEmpty) {
      expect(buildInformation, 'Build information not supplied');
    } else {
      expect(buildInformation, contains(buildVersion));
      if (buildNumber.isNotEmpty) {
        expect(buildInformation, contains('build $buildNumber'));
      }
    }
  });
}
