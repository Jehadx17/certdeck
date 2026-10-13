import 'package:certdeck/cards.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:certdeck/logic.dart';
import 'package:certdeck/widgets.dart' show clozeBack, clozeFront, isolateRuns;
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

  test('list titles: LaTeX as readable text, cloze answers, no Markdown marks', () {
    expect(plain(r'Evaluate $\int\frac{e^x}{1+e^{2x}}\,dx$.'), 'Evaluate ∫eˣ/(1+e²ˣ) dx.');
    expect(plain(r'$$\int_0^3 x^2\,dx$$'), '∫₀³ x² dx');
    expect(plain('The **default** {{constructor::kind}}'), 'The default constructor');
    expect(plain('my_var stays'), 'my_var stays');
  });

  test('mixed Arabic/English: runs of the other script are isolated, code and math untouched', () {
    const lri = '\u2066', rli = '\u2067', pdi = '\u2069';
    final ar = isolateRuns('المتغيرات الثابتة (static) مشتركة — one copy per class.', rtl: true);
    expect(ar, contains('(${lri}static$pdi)')); // brackets stay outside the isolate and pair up
    expect(ar, contains('${lri}one copy per class$pdi.'));
    final en = isolateRuns('`count` is **static** (المتغير الثابت مشترك بين جميع الكائنات), see \$x^2\$.', rtl: false);
    expect(en, startsWith('`count` is **static** ('));
    expect(en, contains('($rliالمتغير الثابت مشترك بين جميع الكائنات$pdi)'));
    expect(en, contains('\$x^2\$')); // math unchanged in an LTR paragraph
    expect(isolateRuns('ارجع إلى [الرابط](https://example.com/a_b)', rtl: true), contains('$lri[الرابط](https://example.com/a_b)$pdi'));
    // A cloze inside the English phrase stays inside the same unit; a fully wrapped term keeps its markers outside.
    final cloze = isolateRuns('المتغيرات الثابتة (‹**static**›) بين الكائنات — one copy per ‹**class**›.', rtl: true);
    expect(cloze, contains('${lri}one copy per ‹**class**›$pdi.'));
    expect(cloze, contains('(‹**${lri}static$pdi**›)'));
    expect(isolateRuns('يُعتنى بـ[**shared / separate?**]', rtl: true), contains('[**${lri}shared / separate?$pdi**]'));
    // Still valid Markdown: the bold survives the isolates.
    expect(md.markdownToHtml(isolateRuns('**قراءة الالتقاط (Scanning)**', rtl: true)), contains('<strong>'));
  });

  test('cloze blanks inside inline code', () {
    expect(clozeBack('set `{{WaitTimeSeconds}}` to {{20}}'), 'set ‹**`WaitTimeSeconds`**› to ‹**20**›');
    expect(clozeFront('set `{{WaitTimeSeconds::param}}`'), 'set [**param**]');
    // Bold right after an Arabic letter: the markers must sit inside the brackets.
    final html = md.markdownToHtml(clozeFront('يُعتنى بـ{{الفكرة العامة}}'));
    expect(html, contains('<strong>…</strong>'));
  });
}
