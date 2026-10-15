import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/models.dart';

void main() {
  group('fmtMs', () {
    test('0 → 0:00', () => expect(fmtMs(0), '0:00'));
    test('5 秒 → 0:05', () => expect(fmtMs(5000), '0:05'));
    test('60 秒 → 1:00', () => expect(fmtMs(60000), '1:00'));
    test('65 秒 → 1:05', () => expect(fmtMs(65000), '1:05'));
    test('59 分 59 秒 → 59:59', () => expect(fmtMs(3599999), '59:59'));
  });
}
