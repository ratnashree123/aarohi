import 'package:aarohi/screens/gym_screen.dart';
import 'package:aarohi/screens/work_screen.dart';
import 'package:aarohi/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseSet handles spoken set formats', () {
    var r = parseSet('bench 60 8')!;
    expect((r.exercise, r.weight, r.reps), ('bench', 60.0, 8));

    r = parseSet('Bench Press 62.5 kg 8 reps')!;
    expect((r.exercise, r.weight, r.reps), ('bench press', 62.5, 8));

    r = parseSet('lat pulldown 45, 12')!;
    expect((r.exercise, r.weight, r.reps), ('lat pulldown', 45.0, 12));

    expect(parseSet('just chatting'), isNull);
    expect(parseSet('60 8'), isNull);
  });

  test('stripTags removes paralinguistic tags for display/fallback voice', () {
    expect(Tts.stripTags('[sigh] Fine. [chuckle] You win.'), 'Fine. You win.');
    expect(Tts.stripTags('No tags here.'), 'No tags here.');
  });

  test('redact strips emails and phone-like numbers', () {
    expect(redact('mail me at joe@corp.com'), 'mail me at [email]');
    expect(redact('call +91 98765 43210 now'), 'call [number] now');
    expect(redact('order #123 failed'), 'order #123 failed');
  });
}
