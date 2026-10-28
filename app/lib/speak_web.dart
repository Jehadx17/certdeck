import 'dart:js_interop';

import 'package:flutter/widgets.dart';

@JS('Audio')
extension type _Audio._(JSObject _) implements JSObject {
  external factory _Audio(String src);
  external JSPromise<JSAny?> play();
}

@JS('SpeechSynthesisUtterance')
extension type _Utterance._(JSObject _) implements JSObject {
  external factory _Utterance(String text);
  external set lang(String value);
  external set rate(num value);
}

extension type _Synth._(JSObject _) implements JSObject {
  external bool get speaking;
  external void cancel();
  external void speak(_Utterance u);
}

@JS('speechSynthesis')
external _Synth get _synth;

extension type _Button._(JSObject _) implements JSObject {
  external _Style get style;
  external set innerHTML(String value);
  external void setAttribute(String name, String value);
  external void addEventListener(String type, JSFunction listener);
}

extension type _Style._(JSObject _) implements JSObject {
  external set cssText(String value);
}

const _volumeUp = '<svg width="24" height="24" viewBox="0 0 24 24" fill="rgba(255,255,255,.7)"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>';

/// A real HTML speaker button. iPhone browsers only allow sound from a genuine tap on a page element, and a Flutter
/// button (drawn on a canvas, its tap read from pointer events) doesn't count, so this one's click starts the sound.
Widget button(String label, void Function() onTap) => SizedBox(
    width: 48,
    height: 48,
    child: HtmlElementView.fromTagName(
        tagName: 'button',
        onElementCreated: (o) {
          final b = _Button._(o as JSObject)
            ..setAttribute('aria-label', label)
            ..setAttribute('title', label)
            ..innerHTML = _volumeUp;
          b.style.cssText = 'width:100%;height:100%;padding:0;border:0;background:none;cursor:pointer;display:flex;'
              'align-items:center;justify-content:center;-webkit-tap-highlight-color:transparent';
          b.addEventListener('click', ((JSAny _) => onTap()).toJS);
        }));

@JS('navigator.onLine')
external bool get _onLine;

/// The browser's own answer: false only when the device has no network at all.
bool online() => _onLine;

/// The recording when there is one, else the browser's English voice (on iPhone: Apple's system voice).
void play(String? url, String word) {
  if (url != null) {
    _Audio(url).play().toDart.catchError((_) {
      _say(word); // the file wouldn't play: say it instead
      return null;
    });
  } else {
    _say(word);
  }
}

void _say(String word) {
  final u = _Utterance(word)
    ..lang = 'en-US'
    ..rate = .9;
  if (_synth.speaking) _synth.cancel(); // only when needed: Safari can drop a speak() that comes right after cancel()
  _synth.speak(u);
}
