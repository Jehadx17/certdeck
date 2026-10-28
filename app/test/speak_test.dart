import 'package:certdeck/speak.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pickAudio: US recording first, else any, else none', () {
    Map entry(List<String> audio) => {'phonetics': [for (final a in audio) {'audio': a}]};
    expect(pickAudio([entry(['', 'https://x/lock-uk.mp3']), entry(['https://x/lock-us.mp3'])]), 'https://x/lock-us.mp3');
    expect(pickAudio([entry(['https://x/raw-uk.mp3'])]), 'https://x/raw-uk.mp3');
    expect(pickAudio([entry(['', ''])]), isNull);
    expect(pickAudio({'title': 'No Definitions Found'}), isNull); // the 404 body
  });

  test('cardWord: only word-course cards, the bold word', () {
    expect(cardWord({'course': wordCourse, 'question': '**race** (competition)\n\n*n., v.*'}), 'race');
    expect(cardWord({'course': 'other', 'question': '**race**'}), isNull);
  });
}
