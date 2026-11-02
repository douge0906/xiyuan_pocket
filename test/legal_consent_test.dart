import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/services/legal_consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('隐私政策同意版本记录', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await LegalConsentService.isAccepted(), isFalse);
    await LegalConsentService.accept();
    expect(await LegalConsentService.isAccepted(), isTrue);
  });
}
