import 'package:certdeck/logic.dart';
import 'package:certdeck/widgets.dart' show clozeBack, clozeFront;
import 'package:fsrs/fsrs.dart' as fsrs;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('confidence → FSRS rating', () {
    expect(ratingFor(Conf.sure, false, 3), fsrs.Rating.again);
    expect(ratingFor(Conf.guess, true, 0), fsrs.Rating.hard);
    expect(ratingFor(Conf.unsure, true, 5), fsrs.Rating.hard);
    expect(ratingFor(Conf.sure, true, 0), fsrs.Rating.good);
    expect(ratingFor(Conf.sure, true, 1), fsrs.Rating.easy);
  });

  test('lenient typed matching', () {
    expect(lenientMatch('AWS STS assume_role', ['aws sts assume-role']), isTrue);
    expect(lenientMatch('`kubectl get pods`.', ['kubectl get pods']), isTrue);
    expect(lenientMatch('kubectl get pod', ['kubectl get pods']), isTrue); // 1 typo
    expect(lenientMatch('generate data key without plaintext', ['GenerateDataKeyWithoutPlaintext']), isTrue);
    expect(lenientMatch('s4', ['s3']), isFalse); // short answers must be exact
    expect(lenientMatch('dynamodb', ['aws sts assume-role']), isFalse);
  });

  test('weighted new-card interleave follows exam weights', () {
    final cert = {
      'id': 'X',
      'domains': [
        {'id': '1', 'weight': .75},
        {'id': '2', 'weight': .25}
      ]
    };
    final cards = [
      for (var i = 0; i < 40; i++)
        {
          'id': '$i',
          'created_at': i,
          'certs': {'X': i.isEven ? '1' : '2'}
        }
    ];
    final firstEight = orderNew(cards, cert).take(8).map((c) => (c['certs'] as Map)['X']).toList();
    expect(firstEight.where((d) => d == '1').length, 6);
  });

  test('cloze blanks inside inline code', () {
    expect(clozeBack('set `{{WaitTimeSeconds}}` to {{20}}'), 'set **‹`WaitTimeSeconds`›** to **‹20›**');
    expect(clozeFront('set `{{WaitTimeSeconds::param}}`'), 'set **[param]**');
  });
}
