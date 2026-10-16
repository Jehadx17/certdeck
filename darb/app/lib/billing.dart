import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'i18n.dart';
import 'widgets.dart';

/// Subscriptions through RevenueCat (App Store / Google Play). The store takes the money; the backend decides who is
/// premium (it re-reads RevenueCat after every purchase or restore), so the app never trusts its own purchase result.
class Billing {
  // Public SDK keys (safe in the app); empty in development builds without --dart-define.
  static const _iosKey = String.fromEnvironment('REVENUECAT_IOS_KEY');
  static const _androidKey = String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  static String get _key => Platform.isIOS ? _iosKey : _androidKey;
  static bool get available => _key.isNotEmpty;
  static bool _configured = false;

  static bool get premium => Api.me.value?['premium'] == true;

  /// Called once the account is known: purchases belong to the Darb account, not the phone.
  static Future<void> start(String accountId) async {
    if (!available) return;
    if (!_configured) {
      await Purchases.configure(PurchasesConfiguration(_key)..appUserID = accountId);
      _configured = true;
    } else {
      await Purchases.logIn(accountId);
    }
  }

  static Future<void> stop() async {
    if (_configured && !await Purchases.isAnonymous) await Purchases.logOut();
  }

  /// The plans on sale, annual first (it is the one we highlight).
  static Future<List<Package>> plans() async {
    final current = (await Purchases.getOfferings()).current;
    const order = [PackageType.annual, PackageType.threeMonth, PackageType.monthly, PackageType.weekly];
    final list = [...?current?.availablePackages.where((p) => order.contains(p.packageType))];
    list.sort((a, b) => order.indexOf(a.packageType).compareTo(order.indexOf(b.packageType)));
    return list;
  }

  /// Buys a plan. Returns null when premium now, '' when the student cancelled, else a message.
  static Future<String?> buy(Package p) async {
    try {
      await Purchases.purchase(PurchaseParams.package(p));
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) == PurchasesErrorCode.purchaseCancelledError) return '';
      return t('The purchase didn\'t go through. You were not charged.');
    }
    return _confirm();
  }

  static Future<String?> restore() async {
    try {
      await Purchases.restorePurchases();
    } on PlatformException {
      return t('Couldn\'t reach the store. Try again.');
    }
    return _confirm();
  }

  /// The backend reads the entitlement from RevenueCat and answers with the account.
  static Future<String?> _confirm() async {
    try {
      Api.me.value = {...?Api.me.value, ...Map<String, dynamic>.from(await Api.call('POST', 'billing/refresh') as Map)};
    } on ApiError catch (e) {
      return e.message;
    }
    return premium ? null : t('No active subscription found.');
  }

  /// The store's own page to change or cancel (we never hide it).
  static Uri get manageUrl => Platform.isIOS
      ? Uri.parse('https://apps.apple.com/account/subscriptions')
      : Uri.parse('https://play.google.com/store/account/subscriptions?package=sa.darbedu.app');
}

/// Opens the paywall; true when the student is premium afterwards.
Future<bool> openPaywall(BuildContext context) async =>
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PaywallScreen())) == true;

String _planName(PackageType type) => switch (type) {
      PackageType.annual => t('Yearly'),
      PackageType.threeMonth => t('3 months'),
      PackageType.monthly => t('Monthly'),
      PackageType.weekly => t('Weekly'),
      _ => '',
    };

/// The paywall: what Plus adds, the plans with store prices, restore, and how to cancel.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});
  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  late final Future<List<Package>> plans = Billing.available ? Billing.plans() : Future.value(const []);
  Package? chosen;

  Future<void> _run(Future<String?> Function() f) async {
    final err = await busy(context, t('Talking to the store…'), f);
    if (!mounted) return;
    if (err == null) {
      toast(context, t('Welcome to Darb Plus!'));
      Navigator.pop(context, true);
    } else if (err.isNotEmpty) {
      toast(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget perk(IconData icon, String text) => ListTile(leading: Icon(icon, color: cs.primary), title: Text(text), dense: true);
    return Scaffold(
      appBar: AppBar(title: Text(t('Darb Plus'))),
      body: FutureBuilder<List<Package>>(
        future: plans,
        builder: (context, snap) {
          final list = snap.data ?? const <Package>[];
          chosen ??= list.isEmpty ? null : list.first;
          return ListView(padding: const EdgeInsets.all(16), children: [
            perk(Icons.library_books_outlined, t('Every question bank: Qudurat, Tahsili and all your school subjects')),
            perk(Icons.upload_file_outlined, t('Turn your own PDFs and photos into study cards')),
            perk(Icons.auto_awesome_outlined, t('More AI explanations and grading of your written answers')),
            perk(Icons.block_outlined, t('No ads, ever (free or paid)')),
            const SizedBox(height: 12),
            if (snap.connectionState != ConnectionState.done) const Center(child: CircularProgressIndicator()),
            if (snap.connectionState == ConnectionState.done && list.isEmpty)
              Text(t('Subscriptions aren\'t available right now. Try again later.'), textAlign: TextAlign.center),
            for (final p in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: chosen == p ? cs.primary : cs.outlineVariant, width: chosen == p ? 2 : 1)),
                  title: Text(_planName(p.packageType), style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: p.packageType == PackageType.annual
                      ? Text(t('Best value: {price} a month', {'price': p.storeProduct.pricePerMonthString ?? ''}))
                      : null,
                  trailing: Text(p.storeProduct.priceString, style: const TextStyle(fontSize: 16)),
                  onTap: () => setState(() => chosen = p),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: chosen == null ? null : () => _run(() => Billing.buy(chosen!)),
              child: Text(t('Subscribe')),
            ),
            TextButton(onPressed: () => _run(Billing.restore), child: Text(t('Restore purchases'))),
            Text(
              t('Renews automatically until you cancel. Cancel any time in your {store} settings, at least a day before the renewal date.',
                  {'store': Platform.isIOS ? 'App Store' : 'Google Play'}),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            Wrap(alignment: WrapAlignment.center, children: [
              TextButton(onPressed: () => launchUrl(Uri.parse('https://${Api.domain}/terms')), child: Text(t('Terms'))),
              TextButton(onPressed: () => launchUrl(Uri.parse('https://${Api.domain}/privacy')), child: Text(t('Privacy'))),
            ]),
          ]);
        },
      ),
    );
  }
}
