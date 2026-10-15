import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'api.dart';
import 'billing.dart';
import 'i18n.dart';
import 'widgets.dart';

/// Google and Apple sign-in only (no passwords). The provider's ID token goes to the backend, which verifies it and
/// returns this phone's own token (docs/DARB-PROTOCOL.md → Accounts). Client ids are public build settings.
class Auth {
  static const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static bool get appleAvailable => Platform.isIOS;
  static bool _googleReady = false;

  /// A provider's ID token (+ Apple's extras), or null when the student cancelled.
  static Future<Map<String, dynamic>?> providerToken(String provider) async {
    if (provider == 'google') {
      if (!_googleReady) {
        await GoogleSignIn.instance.initialize(
            clientId: Platform.isIOS && googleIosClientId.isNotEmpty ? googleIosClientId : null,
            serverClientId: googleServerClientId.isEmpty ? null : googleServerClientId);
        _googleReady = true;
      }
      try {
        final account = await GoogleSignIn.instance.authenticate();
        return {'id_token': account.authentication.idToken};
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled) return null;
        rethrow;
      }
    }
    try {
      final c = await SignInWithApple.getAppleIDCredential(scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName]);
      return {
        'id_token': c.identityToken,
        'authorization_code': c.authorizationCode,
        'name': [c.givenName, c.familyName].whereType<String>().join(' ').trim(),
      };
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }
  }

  /// Sends the token to the backend. Returns null when signed in, 'birth_year' when this is a new account that needs
  /// the age step first, or a message to show.
  static Future<String?> signIn(String provider, Map<String, dynamic> token, {int? birthYear}) async {
    final http.Response r;
    try {
      r = await Api.client
          .post(Uri.parse('${Api.defaultUrl}/api/auth/$provider'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({...token, 'platform': Platform.operatingSystem, 'birth_year': ?birthYear}))
          .timeout(const Duration(seconds: 30));
    } on Exception {
      return t('No internet. Connect and try again.');
    }
    final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    if (r.statusCode != 200) return body['code'] == 'birth_year' ? 'birth_year' : t('${body['error'] ?? 'Something went wrong.'}');
    final err = await Api.connect(Api.defaultUrl, body['token'] as String);
    Api.me.value = Map<String, dynamic>.from(body['account'] as Map);
    await Billing.start(Api.me.value!['id'] as String);
    return err;
  }

  static Future<void> signOut() async {
    try {
      await Api.call('POST', 'auth/signout');
    } on ApiError {
      // offline: the token is forgotten here anyway
    }
    await Api.forget();
    if (_googleReady) await GoogleSignIn.instance.signOut();
  }
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final devToken = TextEditingController();

  Future<void> _go(String provider) async {
    final token = await Auth.providerToken(provider).catchError((Object e) {
      if (mounted) toast(context, t('Sign-in failed. Try again.'));
      return null;
    });
    if (token == null || !mounted) return;
    var err = await busy<String?>(context, t('Signing in…'), () => Auth.signIn(provider, token));
    if (err == 'birth_year' && mounted) {
      final year = await pickBirthYear(context);
      if (year == null || !mounted) return;
      err = await busy<String?>(context, t('Signing in…'), () => Auth.signIn(provider, token, birthYear: year));
    }
    if (err != null && mounted) toast(context, err);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 48),
          Icon(Icons.route_rounded, size: 80, color: cs.primary),
          const SizedBox(height: 12),
          Text('درب', textAlign: TextAlign.center, style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: cs.primary)),
          Text(t('Short daily study for Qudurat, Tahsili and your school subjects.'),
              textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 40),
          if (Auth.appleAvailable) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: cs.onSurface, foregroundColor: cs.surface),
              icon: const Icon(Icons.apple),
              label: Text(t('Continue with Apple')),
              onPressed: () => _go('apple'),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.g_mobiledata, size: 32),
            label: Text(t('Continue with Google')),
            onPressed: () => _go('google'),
          ),
          const SizedBox(height: 24),
          Text(t('Under 13? Use a Google or Apple account your parent manages.'),
              textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          if (kDebugMode) ...[
            const SizedBox(height: 40),
            TextField(controller: devToken, decoration: const InputDecoration(labelText: 'Dev token (debug builds only)')),
            TextButton(onPressed: () => Api.connect(Api.defaultUrl, devToken.text), child: const Text('Connect')),
          ],
        ]),
      ),
    );
  }
}

/// The age step (new accounts only): the year alone, as little data as possible.
Future<int?> pickBirthYear(BuildContext context) {
  final now = DateTime.now().year;
  return showModalBottomSheet<int>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(t('Which year were you born?'), style: Theme.of(c).textTheme.titleMedium)),
        SizedBox(
          height: 280,
          child: ListView(children: [
            for (var y = now - 10; y >= now - 70; y--) ListTile(title: Text('$y', textAlign: TextAlign.center), onTap: () => Navigator.pop(c, y)),
          ]),
        ),
      ]),
    ),
  );
}
