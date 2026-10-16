import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves the walkthrough's screenshots to build/walkthrough/ (CI uploads them).
Future<void> main() => integrationDriver(onScreenshot: (name, bytes, [args]) async {
      final f = File('build/walkthrough/$name.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      return true;
    });
