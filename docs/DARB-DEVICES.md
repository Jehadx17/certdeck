# Darb: toolchain, minimum devices, and what forced each floor

Checked 2026-10-15. Rule: upgrade only as far as the stores force, and keep the lowest Android/iOS minimum that the chosen
Flutter and every dependency allow.

## Store rules that force the toolchain
- **Google Play:** new apps and updates must target **API 36** since 2026-08-31 ([target-sdk](https://developer.android.com/google/play/requirements/target-sdk)).
  16 KB memory pages become mandatory for updates on 2027-02-01. That needs AGP ≥ 8.5.1 ([page sizes](https://developer.android.com/guide/practices/page-sizes)).
- **Apple:** uploads must be built with **Xcode 26+ / iOS 26 SDK** since 2026-04-28, and the deployment target must be **iOS 13+** since
  2026-09-09 ([upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)).

## Chosen: Flutter 3.35.7 (Dart 3.9.2), the oldest stable that satisfies both
- **Android:** 3.32.x defaults to compile/target SDK 35 and knows AGP up to 8.7.3. API 36 needs AGP ≥ 8.9.1
  ([AGP versions](https://developer.android.com/build/releases/about-agp)). **3.35** is the first stable whose defaults are
  SDK 36 with AGP 8.9.1. This was read in Flutter's own `gradle_utils.dart` / `FlutterExtension.kt` at each release tag.
- **iOS:** debug (JIT) runs on iOS 26 devices failed with `mprotect failed: 13` before **3.35.5**
  ([#176263](https://github.com/flutter/flutter/issues/176263)). 3.35.4 fixed an iOS 26 platform-view touch bug
  ([changelog](https://github.com/flutter/flutter/blob/master/CHANGELOG.md)). Release (AOT) builds were never affected.
- **16 KB pages:** every Flutter engine from 3.22 to 3.47 already has 64 KB-aligned LOAD segments (checked with `readelf`
  on `libflutter.so`). So 16 KB support doesn't decide the version; AGP 8.9.1 covers the packaging side.
- Android Gradle Plugin **8.9.1**, Gradle **8.12**, Kotlin **2.1.0**, JDK **17** (the template's defaults).

## Resulting minimums
| Platform | Minimum | Forced by |
|---|---|---|
| **Android** | **API 24 (Android 7.0)** | Flutter 3.35 itself (`minSdkVersion = 24`; it raises lower values); google_sign_in_android 7, path_provider_android, url_launcher_android and image_picker_android all declare 24 |
| **iOS** | **iOS 13** | Apple's upload rule (≥ 13), Flutter 3.35 (Podfile/deployment target 13), purchases_flutter, google_sign_in_ios, url_launcher_ios, path_provider_foundation, image_picker_ios |

Notes:
- **App Attest needs iOS 14** at run time. On iOS 13 the app works, but attestation is unavailable, so it degrades as the spec says:
  stricter rate limits and no premium pack keys. DARB-PROTOCOL.md → Attestation.
- **RevenueCat's paywall UI (purchases_ui_flutter) would force iOS 15 and API 24** ([paywalls](https://www.revenuecat.com/docs/tools/paywalls)).
  Darb draws its own paywall in Flutter (it also needs full Arabic/RTL control), so the floor stays at iOS 13.
- CertDeck stays on Flutter 3.22.2 (`~/FlutterSDK/flutter`). Darb uses `~/FlutterSDK/flutter-3.35.7`.

## Dependencies (resolved with `flutter pub get` on 3.35.7)
| Package | Version | Min Android | Min iOS | Notes |
|---|---|---|---|---|
| sqflite | 2.4.x | 19 | 12 | local database |
| path_provider | 2.1.5 | **24** | **13** | |
| http | 1.6.x | – | – | |
| flutter_secure_storage | 10.x | 23 | 12 | device token, pack keys (Keystore / Keychain) |
| flutter_local_notifications | 20.1.x | 21 | 11 | study reminders (22.x needs Flutter 3.38) |
| file_picker | 11.x | 21 | 12 | PDF uploads |
| image_picker | 1.2.x | **24** | **13** | photo uploads |
| url_launcher | 6.3.2 | **24** | **13** | help, legal pages |
| fsrs | 2.x | – | – | scheduler |
| purchases_flutter (RevenueCat) | 10.16.x | 21 | 13 | subscriptions (phase 1) |
| google_sign_in | 7.2.x | **24** | **13** | v7 API: `initialize()` + `authenticate()` (phase 1) |
| sign_in_with_apple | 7.0.x | 16 | 9 | 8.x needs Flutter 3.41 |
| cryptography | 2.9.x | – | – | AES-GCM for encrypted packs (phase 3); `crypto` has no AES |
| app_device_integrity | 1.1.x | 19 | 11 | Play Integrity + App Attest without Firebase (phase 6) |
| sentry_flutter | ^9.30.1 | 21 | 12 | pin it: pub otherwise picks 8.14 because of a `jni` clash |

Removed from CertDeck: `google_mlkit_translation` (on-device translation; packs are Arabic), `share_plus` (JSON export),
and the self-updater (REQUEST_INSTALL_PACKAGES is not allowed for a Play app).

## Test devices
| Kind | Device | Why |
|---|---|---|
| Old Android | emulator, **API 24** (Android 7.0, google_apis x86_64), 1 GB RAM, 480x800 | the floor; low RAM, small screen |
| Current Android | emulator, API 36, Pixel-size, and a large-screen profile | target SDK, big screens |
| Real Android | the HONOR Magic8 Lite (Android 16) | real hardware |
| Old iOS | iOS simulator at the oldest runtime available on the CI image (iPhone SE size) | small screen |
| Current iOS | iOS 26 simulator (Xcode 26.3) | upload SDK |

The Play Store system image for API 24 is x86 only and Flutter release builds don't run on 32-bit x86, so the old
emulator uses the **google_apis x86_64** image. It has Google Play services for sign-in, but no Play Store, so it can't test
purchases. Purchases are tested on the current emulator and on the HONOR.

## Building iOS
- **Hackintosh** (MacBookAir9,1): needs macOS **Sequoia 15.6+** and **Xcode 26.3**, the last Xcode that runs on Sequoia
  ([xcode support](https://developer.apple.com/support/xcode/)). That meets today's rule.
- **When Apple requires the iOS 27 SDK** (expected about April 2027; unverified), Xcode 27 needs macOS Tahoe 26.6, which this
  machine can't run. The fix then is the cheapest cloud Mac:
  - **GitHub Actions `macos-15`** already has Xcode 26.3, and the `darb` workflow's `ios` job uses it. A private repo gets
    2,000 free minutes/month at about 10x for macOS (~200 macOS minutes), then $0.062/min
    ([billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
  - **Codemagic free:** 500 macOS minutes/month, then $0.095/min ([pricing](https://codemagic.io/pricing/)).
  - A release archive takes ~15 min, so either free tier covers releases. **Cost today: $0.**
