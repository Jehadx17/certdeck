import 'package:darb/logic.dart';
import 'package:darb/weighted.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('weighted percentage', () {
    expect(weighted([90, 80, 70], [30, 30, 40]), closeTo(79, 1e-9));
    expect(weighted([90, 80, 70], [30, 30, 30]), isNull); // weights must sum to 100
    expect(weighted([101, 80, 70], [30, 30, 40]), isNull);
    expect(weighted([null, 80, 70], [30, 30, 40]), isNull);
  });

  test('placement level range (Wilson 95%)', () {
    expect(levelRange(12, 24), (31, 69));
    expect(levelRange(24, 24), (86, 100));
    expect(levelRange(0, 24), (0, 14));
  });
}
