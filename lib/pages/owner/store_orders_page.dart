import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/utils/alert_sound.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// The tabs on the owner's live orders board - each maps straight to
/// `orders.order_status` except "all", which is every non-ended order
/// regardless of status.
enum _OrderFilter { all, placed, accepted, preparing, ready }

String? _statusFor(_OrderFilter f) => switch (f) {
      _OrderFilter.all => null,
      _OrderFilter.placed => 'placed',
      _OrderFilter.accepted => 'accepted',
      _OrderFilter.preparing => 'preparing',
      _OrderFilter.ready => 'ready',
    };

/// Owner's live order board - every non-ended order for this store
/// (`order_end == false`), filterable by status, with the action that
/// advances each one (accept/refuse a new order, start preparing, mark
/// ready) right on its card. A search screen for finding one specific
/// order by its `order_number` is one tap away.
class StoreOrdersPage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreOrdersPage(this.language, this.storeId, {super.key});

  @override
  State<StoreOrdersPage> createState() => _StoreOrdersPageState();
}

class _StoreOrdersPageState extends State<StoreOrdersPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  _OrderFilter _filter = _OrderFilter.all;

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _ordersStream =
      _firestore
          .collection('orders')
          .where('store_id', isEqualTo: widget.storeId)
          .where('order_end', isEqualTo: false)
          .orderBy('created_at', descending: true)
          .snapshots();

  // notifyNewOrder (a Cloud Function) pushes a real notification for when
  // this page (or the app) isn't open - but a push notification's own
  // system alert never shows while the app is in the foreground, on
  // either platform, so an owner already sitting on this exact page still
  // needs its own cue: a short system sound the moment a "placed" order
  // appears that wasn't there in the previous snapshot. Comparing against
  // the previous snapshot's ids (not just "any placed order exists") is
  // what stops this from firing on every rebuild, or right when the page
  // first opens with orders already sitting there.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _newOrderSub;
  Set<String> _knownPlacedIds = {};
  bool _sawFirstSnapshot = false;

  @override
  void initState() {
    super.initState();
    _newOrderSub = _ordersStream.listen(_watchForNewOrders);
  }

  void _watchForNewOrders(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final placedIds = snapshot.docs
        .where((d) => d.data()['order_status'] == 'placed')
        .map((d) => d.id)
        .toSet();
    if (_sawFirstSnapshot && placedIds.difference(_knownPlacedIds).isNotEmpty) {
      AlertSound.playOrderAlert();
    }
    _sawFirstSnapshot = true;
    _knownPlacedIds = placedIds;
  }

  @override
  void dispose() {
    _newOrderSub?.cancel();
    disposeAlert();
    super.dispose();
  }

  // Accept / start preparing / mark ready all go through this - the
  // server (advanceOrderStatus) is what actually decides which timestamp
  // field belongs to which transition and rejects anything that isn't
  // the order's own valid next step, so nothing about that is decided
  // here anymore.
  Future<void> _updateStatus(
    QueryDocumentSnapshot<Map<String, dynamic>> order,
    String newStatus,
  ) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('advanceOrderStatus')
          .call({'order_id': order.id, 'new_status': newStatus});
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

  Future<void> _refuseOrder(
      QueryDocumentSnapshot<Map<String, dynamic>> order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(TranslationHelper.get('refuse_order_title')),
          content: Text(TranslationHelper.get('refuse_order_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(TranslationHelper.get('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                TranslationHelper.get('refuse_button'),
                style: const TextStyle(color: Color(0xFFE74C3C)),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    // Immediate, optimistic - drops the order off this live board (its
    // stream already filters to order_end == false) the moment the owner
    // confirms, without waiting on the callable round trip. The callable
    // below doesn't trust this write happened (or happened correctly) -
    // it re-asserts order_end itself and is what actually does the
    // refund/failed-transaction handling, so this is purely a UI head
    // start, not the real cancellation.
    try {
      await order.reference.update({'order_end': true});
    } catch (_) {
      // Ignored - cancelOrder below is the authoritative action either way.
    }
    try {
      await FirebaseFunctions.instance
          .httpsCallable('cancelOrder')
          .call({'order_id': order.id});
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
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 12, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Row(
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
                  TranslationHelper.get('ongoing_orders_page_title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(19),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        _OrderSearchPage(widget.language, widget.storeId),
                  ),
                ),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.search, size: 20, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildFilterChips(),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final f in _OrderFilter.values) ...[
            _buildFilterChip(f),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip(_OrderFilter f) {
    final selected = _filter == f;
    final label = TranslationHelper.get(switch (f) {
      _OrderFilter.all => 'filter_all_label',
      _OrderFilter.placed => 'filter_new_label',
      _OrderFilter.accepted => 'order_status_accepted_label',
      _OrderFilter.preparing => 'order_status_preparing_label',
      _OrderFilter.ready => 'order_status_ready_label',
    });
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _filter = f),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? const Color(0xFFFF9800) : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _ordersStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              TranslationHelper.get(
                  isConnectivityError(snapshot.error!) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final wantedStatus = _statusFor(_filter);
        final docs = snapshot.data!.docs
            .where((d) =>
                wantedStatus == null || d.data()['order_status'] == wantedStatus)
            .toList();

        if (docs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.receipt_long_outlined,
                      size: 48, color: Color(0xFFC9CDD4)),
                  const SizedBox(height: 12),
                  Text(
                    TranslationHelper.get('no_active_orders'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Color(0xFF677489)),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) => OrderCard(
            language: widget.language,
            order: docs[i],
            onAccept: () => _updateStatus(docs[i], 'accepted'),
            onRefuse: () => _refuseOrder(docs[i]),
            onStartPreparing: () => _updateStatus(docs[i], 'preparing'),
            onMarkReady: () => _updateStatus(docs[i], 'ready'),
            onOpenChat: docs[i].data()['conversation_id'] != null
                ? () => showAlert(TranslationHelper.get('chat_coming_soon'))
                : null,
          ),
        );
      },
    );
  }
}

/// One order card - status pill, age + delivery status, every line (with
/// its variant/selected group options), total breakdown, and whichever
/// single action currently applies to `order_status`
/// (placed -> accept/refuse, accepted -> start preparing, preparing ->
/// mark ready; "ready" has none - the owner just waits for pickup).
class OrderCard extends StatelessWidget {
  final String language;
  final QueryDocumentSnapshot<Map<String, dynamic>> order;
  final VoidCallback onAccept;
  final VoidCallback onRefuse;
  final VoidCallback onStartPreparing;
  final VoidCallback onMarkReady;
  // Null when this order has no conversation_id - the icon it would show
  // is simply omitted rather than shown disabled.
  final VoidCallback? onOpenChat;

  const OrderCard({
    required this.language,
    required this.order,
    required this.onAccept,
    required this.onRefuse,
    required this.onStartPreparing,
    required this.onMarkReady,
    this.onOpenChat,
    super.key,
  });

  bool get _isArabic => language == 'ar';

  @override
  Widget build(BuildContext context) {
    final data = order.data();
    final orderNumber = data['order_number'] as String? ?? order.id;
    final status = data['order_status'] as String? ?? 'placed';
    final deliveryStatus = data['delivery_status'] as String? ?? 'pending';
    final orderEnd = data['order_end'] as bool? ?? false;
    final createdAt = (data['created_at'] as Timestamp?)?.toDate();
    final subtotal = (data['subtotal'] as num?) ?? 0;
    final deliveryFee = (data['delivery_fee'] as num?) ?? 0;
    final total = (data['total'] as num?) ?? 0;
    final lines = (data['lines'] as Map?) ?? {};
    final notes = (data['notes'] as String? ?? '').trim();
    final currency = TranslationHelper.get('currency_unit');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  TranslationHelper.get('order_number_label', {'number': orderNumber}),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
              ),
              if (onOpenChat != null) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: onOpenChat,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.chat_bubble_outline_rounded,
                        size: 18, color: Color(0xFF9AA1AC)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _buildStatusPill(status, orderEnd, deliveryStatus),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_timeAgo(createdAt)} · ${TranslationHelper.get('delivery_status_$deliveryStatus')}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
          ),
          const SizedBox(height: 10),
          for (final entry in lines.entries) _buildLine(entry.value),
          if (notes.isNotEmpty) _buildNotes(notes),
          const Divider(height: 20, color: Color(0xFFF0F1F4)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${total.toStringAsFixed(0)} $currency',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              Text(
                TranslationHelper.get('order_cost_breakdown', {
                  'subtotal': subtotal.toStringAsFixed(0),
                  'delivery': deliveryFee.toStringAsFixed(0),
                }),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!orderEnd) _buildActions(status),
        ],
      ),
    );
  }

  Widget _buildLine(dynamic rawLine) {
    final line = (rawLine as Map).cast<String, dynamic>();
    final nameAr = line['name_ar'] as String? ?? '';
    final nameFr = line['name_fr'] as String? ?? '';
    final name = _isArabic && nameAr.isNotEmpty ? nameAr : nameFr;
    final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
    final variant = (line['variant'] as Map?)?.cast<String, dynamic>();
    final variantName = variant == null
        ? null
        : (_isArabic
            ? variant['name_ar'] as String?
            : variant['name_fr'] as String?);

    final optionLabels = <String>[];
    for (final rawGroup in (line['groups'] as List? ?? const [])) {
      final group = (rawGroup as Map).cast<String, dynamic>();
      for (final rawSelected in (group['selected'] as List? ?? const [])) {
        final selected = (rawSelected as Map).cast<String, dynamic>();
        final optName = _isArabic
            ? (selected['name_ar'] as String? ?? '')
            : (selected['name_fr'] as String? ?? '');
        if (optName.isEmpty) continue;
        final price = (selected['price'] as num?) ?? 0;
        optionLabels.add(price > 0 ? '+$optName' : optName);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            variantName != null && variantName.isNotEmpty
                ? '${quantity}x $name ($variantName)'
                : '${quantity}x $name',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF2E3A59),
            ),
          ),
          if (optionLabels.isNotEmpty)
            Text(
              optionLabels.join(', '),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
            ),
        ],
      ),
    );
  }

  /// The customer's own free-text note from checkout (push_order_page.dart's
  /// note_for_store_hint field) - shown right under the item lines so the
  /// owner sees it before accepting/preparing, not buried further down.
  Widget _buildNotes(String notes) {
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8EC),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.sticky_note_2_outlined,
              size: 15, color: Color(0xFFB8631A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notes,
              style: const TextStyle(
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                color: Color(0xFF7A5D3A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Only ever reached via search - the main board's own query already
  /// filters to `order_end == false`, so an ended order can't show up
  /// there. Once ended, `order_status` alone ("ready", "cancelled", ...)
  /// doesn't say whether the order actually completed - `delivery_status`
  /// is what confirms it was delivered; anything else ended (only
  /// "cancelled" today) falls back to showing `order_status` as-is.
  Widget _buildStatusPill(String status, bool orderEnd, String deliveryStatus) {
    late final Color bg;
    late final Color fg;
    late final String label;
    if (orderEnd && deliveryStatus == 'delivered') {
      bg = const Color(0xFFE6F7EA);
      fg = const Color(0xFF1B8A3E);
      label = TranslationHelper.get('delivery_status_delivered');
    } else {
      switch (status) {
        case 'placed':
          bg = const Color(0xFFFFF3E0);
          fg = const Color(0xFFFF9800);
          label = TranslationHelper.get('order_status_new_pill_label');
          break;
        case 'accepted':
          bg = const Color(0xFFEFE7FD);
          fg = const Color(0xFF7C4DFF);
          label = TranslationHelper.get('order_status_accepted_label');
          break;
        case 'preparing':
          bg = const Color(0xFFE3F0FF);
          fg = const Color(0xFF2F80ED);
          label = TranslationHelper.get('order_status_preparing_label');
          break;
        case 'ready':
          bg = const Color(0xFFE6F7EA);
          fg = const Color(0xFF1B8A3E);
          label = TranslationHelper.get('order_status_ready_label');
          break;
        default:
          bg = const Color(0xFFFDF1F0);
          fg = const Color(0xFFE74C3C);
          label = TranslationHelper.get('order_status_cancelled');
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }

  Widget _buildActions(String status) {
    switch (status) {
      case 'placed':
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onRefuse,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE74C3C),
                  side: const BorderSide(color: Color(0xFFF3C4C0)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(TranslationHelper.get('refuse_button'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: onAccept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(TranslationHelper.get('accept_button'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        );
      case 'accepted':
        return _buildFullWidthButton(
            TranslationHelper.get('start_preparing_button'), onStartPreparing);
      case 'preparing':
        return _buildFullWidthButton(
            TranslationHelper.get('mark_ready_button'), onMarkReady);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildFullWidthButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFF9800),
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

String _timeAgo(DateTime? time) {
  if (time == null) return '';
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return TranslationHelper.get('time_ago_now');
  if (diff.inMinutes < 60) {
    return TranslationHelper.get('time_ago_minutes', {'n': diff.inMinutes});
  }
  if (diff.inHours < 24) {
    return TranslationHelper.get('time_ago_hours', {'n': diff.inHours});
  }
  return TranslationHelper.get('time_ago_days', {'n': diff.inDays});
}

/// Find one order by its `order_number` - a plain, unstyled (matching the
/// design) white header rather than the orange gradient the rest of the
/// owner section uses, since this is a focused utility screen, not a
/// section of its own.
class _OrderSearchPage extends StatefulWidget {
  final String language;
  final String storeId;
  const _OrderSearchPage(this.language, this.storeId);

  @override
  State<_OrderSearchPage> createState() => _OrderSearchPageState();
}

class _OrderSearchPageState extends State<_OrderSearchPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _controller = TextEditingController();

  bool get _isArabic => widget.language == 'ar';

  bool _isSearching = false;
  bool _searched = false;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _results = [];

  @override
  void dispose() {
    _controller.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _isSearching) return;
    setState(() {
      _isSearching = true;
      _searched = true;
    });
    try {
      final snap = await _firestore
          .collection('orders')
          .where('store_id', isEqualTo: widget.storeId)
          .where('order_number', isEqualTo: query)
          .limit(5)
          .get();
      if (!mounted) return;
      setState(() {
        _results = snap.docs;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSearching = false);
      showAlert(
        TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              if (alertCard != null) alertCard!,
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
            children: [
              InkWell(
                onTap: () => Navigator.pop(context),
                child: Icon(
                  _isArabic
                      ? Icons.arrow_forward_ios_rounded
                      : Icons.arrow_back_ios_new_rounded,
                  size: 18,
                  color: const Color(0xFF3D5CFF),
                ),
              ),
              const SizedBox(width: 14),
              Text(
                TranslationHelper.get('search_order_title'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF3D5CFF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F8FA),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE1E4E9)),
                  ),
                  child: TextField(
                    controller: _controller,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: TranslationHelper.get('order_number_hint'),
                      hintStyle: const TextStyle(
                          fontSize: 13.5, color: Color(0xFF9AA1AC)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _search,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(TranslationHelper.get('search_button'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      return Center(
        child: Text(
          TranslationHelper.get('order_search_hint'),
          style: const TextStyle(color: Color(0xFF3D5CFF), fontSize: 13),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          TranslationHelper.get('order_search_not_found'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => OrderCard(
        language: widget.language,
        order: _results[i],
        onAccept: () => _updateStatus(_results[i], 'accepted'),
        onRefuse: () => _refuse(_results[i]),
        onStartPreparing: () => _updateStatus(_results[i], 'preparing'),
        onMarkReady: () => _updateStatus(_results[i], 'ready'),
        onOpenChat: _results[i].data()['conversation_id'] != null
            ? () => showAlert(TranslationHelper.get('chat_coming_soon'))
            : null,
      ),
    );
  }

  // See _StoreOrdersPageState's own _updateStatus - same callable, same
  // reasoning (advanceOrderStatus decides the timestamp field and rejects
  // an invalid transition, not the client).
  Future<void> _updateStatus(
    QueryDocumentSnapshot<Map<String, dynamic>> order,
    String newStatus,
  ) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('advanceOrderStatus')
          .call({'order_id': order.id, 'new_status': newStatus});
      if (mounted) await _search();
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _refuse(QueryDocumentSnapshot<Map<String, dynamic>> order) async {
    try {
      await order.reference.update({'order_end': true});
    } catch (_) {
      // Ignored - cancelOrder below is the authoritative action either way.
    }
    try {
      await FirebaseFunctions.instance
          .httpsCallable('cancelOrder')
          .call({'order_id': order.id});
      if (mounted) await _search();
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
  }
}
