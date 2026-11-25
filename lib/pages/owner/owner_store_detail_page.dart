import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/owner/store_analytics_page.dart';
import 'package:flutter_application_1/pages/owner/store_finance_page.dart';
import 'package:flutter_application_1/pages/owner/store_info_edit_page.dart';
import 'package:flutter_application_1/pages/owner/store_menu_page.dart';
import 'package:flutter_application_1/pages/owner/store_order_history_page.dart';
import 'package:flutter_application_1/pages/owner/store_orders_page.dart';
import 'package:flutter_application_1/pages/owner/store_work_time_page.dart';
import 'package:flutter_application_1/pages/shared/support_page.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// One store's management hub - status/rating at a glance, this month's
/// orders/revenue, and the links into every other owner sub-page for it
/// (info, orders, hours, menu, analytics, finance, support).
class OwnerStoreDetailPage extends StatefulWidget {
  final String language;
  final String storeId;
  const OwnerStoreDetailPage(this.language, this.storeId, {super.key});

  @override
  State<OwnerStoreDetailPage> createState() => _OwnerStoreDetailPageState();
}

class _OwnerStoreDetailPageState extends State<OwnerStoreDetailPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;
  Map<String, dynamic>? _store;
  int? _trendLevel;
  int _monthlyOrders = 0;
  double _monthlyRevenue = 0;

  // A field, not a getter - StreamBuilder resets to ConnectionState.waiting
  // on every "new" Stream instance, which a getter would recreate on every
  // setState (e.g. the alert card showing/hiding).
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _pendingOrdersStream =
      _firestore
          .collection('orders')
          .where('store_id', isEqualTo: widget.storeId)
          .where('order_end', isEqualTo: false)
          .snapshots();

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

  Future<void> _load() async {
    try {
      final storeSnap =
          await _firestore.collection('stores').doc(widget.storeId).get();
      if (!storeSnap.exists) {
        if (!mounted) return;
        setState(() {
          _loadError = StateError('store-not-found');
          _isLoading = false;
        });
        return;
      }

      final store = storeSnap.data()!;

      final results = await Future.wait([
        _firestore
            .collection('stores_analytics')
            .doc(widget.storeId)
            .collection('monthly')
            .doc(_monthKey(DateTime.now()))
            .get(),
        // Firestore-server time, not the device clock - trend_time is the
        // hour bucket the backend last scored this store's trend_level
        // for, so "is it still current" has to be judged against the same
        // clock that wrote it, not whatever time the phone happens to
        // think it is.
        _fetchServerTime(),
      ]);
      final monthlySnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final serverNow = results[1] as DateTime;

      final monthlyData = monthlySnap.data();
      final trendTime = store['trend_time'] as String?;
      final trendLevel = (store['trend_level'] as num?)?.toInt();
      final isCurrentHour =
          trendTime != null && trendTime == _hourKey(serverNow);

      if (!mounted) return;
      setState(() {
        _store = store;
        _trendLevel = (isCurrentHour && trendLevel != null && trendLevel <= 10)
            ? trendLevel
            : null;
        _monthlyOrders = (monthlyData?['total_orders'] as num?)?.toInt() ?? 0;
        _monthlyRevenue =
            (monthlyData?['total_revenue'] as num?)?.toDouble() ?? 0;
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

  String _monthKey(DateTime d) => d.toUtc().toIso8601String().substring(0, 7);

  // "YYYY-MM-DDTHH" -> "YYYY-MM-DD-HH", matching how trend_time is written
  // (see lib/map.txt: "trend_time // ... this is hour orders used to
  // change trend every start new hour").
  String _hourKey(DateTime d) =>
      d.toUtc().toIso8601String().substring(0, 13).replaceFirst('T', '-');

  /// A Firestore round trip (write + read back) is the standard way to get
  /// the backend's clock on a plain client SDK, which has no direct
  /// "server now" read - `FieldValue.serverTimestamp()` only resolves once
  /// the write actually lands, and `Source.server` on the read forces a
  /// real round trip instead of the local (pre-resolution) echo. One
  /// shared doc, reused/overwritten by every caller rather than growing a
  /// collection per view.
  Future<DateTime> _fetchServerTime() async {
    final ref = _firestore.collection('system').doc('server_time_probe');
    await ref.set({'t': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    final snap = await ref.get(const GetOptions(source: Source.server));
    final ts = snap.data()?['t'] as Timestamp?;
    return ts?.toDate() ?? DateTime.now();
  }

  String _formatCount(num value) {
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
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _buildErrorState()
                : Column(
                    children: [
                      _buildHeader(),
                      if (alertCard != null) alertCard!,
                      Expanded(child: _buildBody()),
                    ],
                  ),
      ),
    );
  }

  static const _statuses = ['open', 'trafic', 'close'];

  Color _statusColor(String status) {
    switch (status) {
      case 'open':
        return const Color(0xFF1B8A3E);
      case 'trafic':
        return const Color(0xFFB8860B);
      default:
        return const Color(0xFFE74C3C);
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'open':
        return TranslationHelper.get('store_open');
      case 'trafic':
        return TranslationHelper.get('store_busy');
      default:
        return TranslationHelper.get('store_closed');
    }
  }

  /// Two steps, matching the design: pick a new status from the ones the
  /// store isn't already in, then confirm that specific change - tapping
  /// an option in the first dialog immediately opens the second rather
  /// than needing its own confirm button.
  Future<void> _showChangeStatusFlow() async {
    // `start` gates whether this store is allowed to change its own status
    // at all - a store not yet started/approved can't flip itself "open".
    if (_store!['start'] == false) {
      showAlert(TranslationHelper.get('store_inactive_action_blocked'),
          isError: true);
      return;
    }
    final currentStatus = _store!['status'] as String? ?? 'close';
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _ChangeStatusOptionsDialog(
        isArabic: _isArabic,
        options: _statuses.where((s) => s != currentStatus).toList(),
        statusColor: _statusColor,
        statusLabel: _statusLabel,
      ),
    );
    if (chosen == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmStatusDialog(
        isArabic: _isArabic,
        newStatusLabel: _statusLabel(chosen),
      ),
    );
    if (confirmed != true || !mounted) return;

    // An offline Firestore write doesn't fail - the Future just doesn't
    // complete until the connection returns (the write stays queued and is
    // sent then). So with zero internet the `await` below hangs with no
    // error and no feedback, and the status change would go through later,
    // on its own, whenever the connection came back. Check real
    // reachability explicitly first and say so immediately instead.
    final online = await InternetConnectionService().checkNow();
    if (!online) {
      if (mounted) {
        showAlert(TranslationHelper.get('no_internet'), isError: true);
      }
      return;
    }

    try {
      await _firestore
          .collection('stores')
          .doc(widget.storeId)
          .update({'status': chosen});
      if (mounted) {
        setState(() => _store = {..._store!, 'status': chosen});
      }
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
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
              onPressed: () => Navigator.of(context).pop(),
              child: Text(TranslationHelper.get('go_back')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final store = _store!;
    final nameAr = store['name_ar'] as String? ?? '';
    final nameFr = store['name_fr'] as String? ?? '';
    final storeName = (_isArabic ? nameAr : nameFr).isNotEmpty
        ? (_isArabic ? nameAr : nameFr)
        : (nameFr.isNotEmpty ? nameFr : TranslationHelper.get('unknown_store'));
    final status = store['status'] as String? ?? 'close';
    final statusColor = _statusColor(status);
    final statusText = _statusLabel(status);

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
              storeName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Opacity(
            opacity: store['start'] == false ? 0.5 : 1,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _showChangeStatusFlow,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final store = _store!;
    // `rate` is the running sum of every rating, not an average by itself
    // (ratings (subcollection) { id { rating // 1-5 } } - `rate` on the
    // store doc is those added up, `rate_numbers` is the count of them).
    final rateSum = (store['rate'] as num?)?.toDouble() ?? 0;
    final rateNumbers = (store['rate_numbers'] as num?)?.toInt() ?? 0;
    final rate = rateNumbers > 0 ? rateSum / rateNumbers : 0.0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (_trendLevel != null) ...[
          _buildTrendBanner(_trendLevel!),
          const SizedBox(height: 14),
        ],
        _buildStatsRow(rate: rate, rateNumbers: rateNumbers),
        const SizedBox(height: 22),
        Text(
          TranslationHelper.get('gestion_section_label'),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF9AA1AC),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        _buildMenuCard(),
      ],
    );
  }

  Widget _buildTrendBanner(int rank) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.emoji_events_rounded,
              color: Color(0xFFFF9800), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              TranslationHelper.get('trend_rank_banner', {'rank': rank}),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow({required double rate, required int rateNumbers}) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            value: _formatCount(_monthlyOrders),
            label: TranslationHelper.get('orders_stat_label'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            value:
                '${_formatCount(_monthlyRevenue)} ${TranslationHelper.get('currency_unit')}',
            label: TranslationHelper.get('revenue_stat_label'),
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
    );
  }

  Widget _buildStatCard({
    required String value,
    required String label,
    Color valueColor = const Color(0xFF2E3A59),
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
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
                    fontSize: 15,
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
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9AA1AC)),
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
            icon: Icons.storefront_outlined,
            label: TranslationHelper.get('store_info_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StoreInfoEditPage(widget.language, widget.storeId),
              ),
            ),
          ),
          _divider(),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _pendingOrdersStream,
            builder: (context, snapshot) {
              final count = snapshot.data?.docs.length ?? 0;
              return _buildMenuRow(
                icon: Icons.receipt_long_outlined,
                label: TranslationHelper.get('ongoing_orders_menu_item'),
                badge: count > 0 ? '$count' : null,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        StoreOrdersPage(widget.language, widget.storeId),
                  ),
                ),
              );
            },
          ),
          _divider(),
          _buildMenuRow(
            icon: Icons.history_rounded,
            label: TranslationHelper.get('order_history_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StoreOrderHistoryPage(widget.language, widget.storeId),
              ),
            ),
          ),
          _divider(),
          _buildMenuRow(
            icon: Icons.schedule_outlined,
            label: TranslationHelper.get('work_time_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StoreWorkTimePage(widget.language, widget.storeId),
              ),
            ),
          ),
          _divider(),
          _buildMenuRow(
            icon: Icons.restaurant_menu_outlined,
            label: TranslationHelper.get('manage_menu_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StoreMenuPage(widget.language, widget.storeId),
              ),
            ),
          ),
          _divider(),
          _buildMenuRow(
            icon: Icons.bar_chart_rounded,
            label: TranslationHelper.get('store_analytics_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StoreAnalyticsPage(widget.language, widget.storeId),
              ),
            ),
          ),
          _divider(),
          _buildMenuRow(
            icon: Icons.account_balance_wallet_outlined,
            label: TranslationHelper.get('finance_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StoreFinancePage(widget.language, widget.storeId),
              ),
            ),
          ),
          _divider(),
          _buildMenuRow(
            icon: Icons.support_agent_outlined,
            label: TranslationHelper.get('support_menu_item'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SupportPage(widget.language, audience: 'owner'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      const Divider(height: 1, color: Color(0xFFF0F1F4), indent: 52);

  Widget _buildMenuRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? badge,
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
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9800),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
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

/// Step 1: pick which status to switch to, from whichever ones the store
/// isn't already in. Tapping a row pops this dialog with that choice
/// instead of needing a separate confirm button here - confirmation is
/// [_ConfirmStatusDialog], one screen later.
class _ChangeStatusOptionsDialog extends StatelessWidget {
  final bool isArabic;
  final List<String> options;
  final Color Function(String status) statusColor;
  final String Function(String status) statusLabel;

  const _ChangeStatusOptionsDialog({
    required this.isArabic,
    required this.options,
    required this.statusColor,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                TranslationHelper.get('change_status_title'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 14),
              for (final status in options)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context, status),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F8FA),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: statusColor(status),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          statusLabel(status),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF2E3A59),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    TranslationHelper.get('cancel'),
                    style: const TextStyle(
                      color: Color(0xFF9AA1AC),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Step 2: confirm the specific change picked in [_ChangeStatusOptionsDialog].
class _ConfirmStatusDialog extends StatelessWidget {
  final bool isArabic;
  final String newStatusLabel;

  const _ConfirmStatusDialog({
    required this.isArabic,
    required this.newStatusLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                TranslationHelper.get('change_status_confirm_title'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                TranslationHelper.get('change_status_confirm_message',
                    {'status': newStatusLabel}),
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 13.5, color: Color(0xFF677489)),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: const BorderSide(color: Color(0xFFE1E4E9)),
                      ),
                      child: Text(
                        TranslationHelper.get('cancel'),
                        style: const TextStyle(
                          color: Color(0xFF2E3A59),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9800),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('confirm_button'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
