import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/pages/delivery/delivery_finance_page.dart';
import 'package:flutter_application_1/pages/delivery/delivery_orders_page.dart';
import 'package:flutter_application_1/pages/shared/support_page.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/delivery_offer_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// Driver's dashboard - online/offline toggle, today's earnings/delivery
/// count (computed live from `orders`, not a stored counter - see the
/// class doc on [_todayDeliveredOrdersQuery]), lifetime stats already
/// tracked on `delivery/{uid}` (completed_orders, cancelled_orders, rate,
/// payout_balance), and links into the assigned-orders board and finance.
class DeliveryHomePage extends StatefulWidget {
  final String language;
  const DeliveryHomePage(this.language, {super.key});

  @override
  State<DeliveryHomePage> createState() => _DeliveryHomePageState();
}

class _DeliveryHomePageState extends State<DeliveryHomePage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;
  Map<String, dynamic> _delivery = {};
  int _deliveriesToday = 0;
  double _earningsToday = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  /// "Today" is drawn from `delivered_at`, filtered to the device's own
  /// midnight-to-midnight window (not the server's) - fine for a driver
  /// glancing at their own day, but it means this can read a delivery
  /// either side of actual midnight if the device clock is off, and it
  /// resets at a slightly different real-world instant than a version
  /// keyed off server time would. See the explanation accompanying this
  /// page for the alternative (a maintained daily rollup) and why this
  /// query-based approach was used instead for now.
  Query<Map<String, dynamic>> _todayDeliveredOrdersQuery() {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfDay.add(const Duration(days: 1));
    return _firestore
        .collection('orders')
        .where('delivery_id', isEqualTo: _uid)
        .where('delivery_status', isEqualTo: 'delivered')
        .where('delivered_at',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('delivered_at', isLessThan: Timestamp.fromDate(startOfTomorrow));
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _firestore.collection('delivery').doc(_uid).get(),
        _todayDeliveredOrdersQuery().get(),
      ]);
      final deliverySnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final todaySnap = results[1] as QuerySnapshot<Map<String, dynamic>>;

      double earnings = 0;
      for (final doc in todaySnap.docs) {
        earnings += (doc.data()['delivery_fee'] as num?)?.toDouble() ?? 0;
      }

      if (!mounted) return;
      setState(() {
        _delivery = deliverySnap.data() ?? {};
        _deliveriesToday = todaySnap.docs.length;
        _earningsToday = earnings;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleOnline(bool value) async {
    // `active` gates whether this driver is allowed to go online at all -
    // a deactivated account can't flip itself online, same as a store
    // that hasn't `start`ed can't change its own status.
    if (_delivery['active'] == false) {
      showAlert(TranslationHelper.get('delivery_inactive_action_blocked'),
          isError: true);
      return;
    }
    // An offline Firestore write doesn't fail - the Future just doesn't
    // complete until the connection returns (the write stays queued and is
    // sent then). So with zero internet the `await` below hangs, the catch
    // block's rollback never runs, and the optimistically flipped toggle
    // stays flipped even though nothing has reached the server. Check real
    // reachability explicitly first, before touching any UI state.
    final online = await InternetConnectionService().checkNow();
    if (!online) {
      if (mounted)
        showAlert(TranslationHelper.get('no_internet'), isError: true);
      return;
    }
    // Optimistic - matches the store status/menu-item toggle pattern used
    // elsewhere: flip instantly, roll back only if the write fails.
    setState(() => _delivery = {..._delivery, 'is_online': value});
    try {
      await _firestore.collection('delivery').doc(_uid).update({
        'is_online': value,
        // Stamped every time the driver comes online so the courier-search
        // system can rank/back off idle drivers by how long they've been
        // available, using Firestore's own clock rather than the device's.
        if (value) 'last_assigned_at': FieldValue.serverTimestamp(),
      });
      // Keeps the app-wide offer listener's lifetime in sync with
      // is_online right away, rather than waiting for its own snapshot of
      // this doc to come back around.
      if (value) {
        DeliveryOfferService.instance.start(_uid);
      } else {
        DeliveryOfferService.instance.stop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _delivery = {..._delivery, 'is_online': !value});
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
  }

  String _formatAmount(num value) {
    if (value >= 1000) {
      final k = value / 1000;
      return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
    }
    return value.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: Column(
          children: [
            _buildHeader(),
            if (alertCard != null) alertCard!,
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadError != null
                      ? _buildErrorState()
                      : _buildBody(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              TranslationHelper.get(
                  isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _loadError = null;
                });
                _load();
              },
              child: Text(TranslationHelper.get('retry')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 12, 16, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Row(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(19),
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.22),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isArabic
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              TranslationHelper.get('delivery_home_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final isOnline = _delivery['is_online'] as bool? ?? false;
    final completed = (_delivery['completed_orders'] as num?) ?? 0;
    final cancelled = (_delivery['cancelled_orders'] as num?) ?? 0;
    final payoutBalance =
        (_delivery['payout_balance'] as num?)?.toDouble() ?? 0.0;
    final rateSum = (_delivery['rate'] as num?)?.toDouble() ?? 0;
    final rateNumbers = (_delivery['rate_numbers'] as num?)?.toInt() ?? 0;
    final rate = rateNumbers > 0 ? rateSum / rateNumbers : 0.0;
    final currency = TranslationHelper.get('currency_unit');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildOnlineToggle(isOnline, _delivery['active'] != false),
        const SizedBox(height: 22),
        _buildSectionLabel('delivery_today_section'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                value: '${_formatAmount(_earningsToday)} $currency',
                label: TranslationHelper.get('delivery_earnings_today'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                value: _formatAmount(_deliveriesToday),
                label: TranslationHelper.get('delivery_deliveries_today'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _buildSectionLabel('delivery_total_section'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                value: '${_formatAmount(payoutBalance)} $currency',
                label: TranslationHelper.get('delivery_balance_label'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                value: rateNumbers > 0 ? rate.toStringAsFixed(1) : '—',
                label: TranslationHelper.get('rating_stat_label'),
                valueColor: const Color(0xFFFF9800),
                icon: Icons.star_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                value: _formatAmount(completed),
                label: TranslationHelper.get('delivery_completed_orders'),
                valueColor: const Color(0xFF1B8A3E),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                value: _formatAmount(cancelled),
                label: TranslationHelper.get('delivery_cancelled_orders'),
                valueColor: const Color(0xFFE74C3C),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _buildMenuCard(),
      ],
    );
  }

  Widget _buildOnlineToggle(bool isOnline, bool isActive) {
    final color = isOnline ? const Color(0xFF1B8A3E) : const Color(0xFF9AA1AC);
    return Opacity(
      opacity: isActive ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                TranslationHelper.get(isOnline
                    ? 'delivery_online_label'
                    : 'delivery_offline_label'),
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: isOnline
                      ? const Color(0xFF2E3A59)
                      : const Color(0xFF9AA1AC),
                ),
              ),
            ),
            Switch(
              value: isOnline,
              activeThumbColor: const Color(0xFF1B8A3E),
              onChanged: _toggleOnline,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String key) => Text(
        TranslationHelper.get(key),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      );

  Widget _buildStatCard({
    required String value,
    required String label,
    Color valueColor = const Color(0xFF2E3A59),
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: valueColor),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildMenuRow(
            icon: Icons.local_shipping_outlined,
            label: TranslationHelper.get('delivery_assigned_orders_menu'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeliveryOrdersPage(widget.language),
              ),
            ),
          ),
          Divider(
              height: 1,
              color: const Color(0xFFF0F1F4),
              indent: _isArabic ? 0 : 52,
              endIndent: _isArabic ? 52 : 0),
          _buildMenuRow(
            icon: Icons.account_balance_wallet_outlined,
            label: TranslationHelper.get('delivery_finance_menu'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeliveryFinancePage(widget.language),
              ),
            ),
          ),
          Divider(
              height: 1,
              color: const Color(0xFFF0F1F4),
              indent: _isArabic ? 0 : 52,
              endIndent: _isArabic ? 52 : 0),
          _buildMenuRow(
            icon: Icons.support_agent_outlined,
            label: TranslationHelper.get('support_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    SupportPage(widget.language, audience: 'delivery'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 17, color: const Color(0xFFFF9800)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            Icon(
              _isArabic
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              color: const Color(0xFFC9CDD4),
            ),
          ],
        ),
      ),
    );
  }
}
