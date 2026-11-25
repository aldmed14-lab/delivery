import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_application_1/pages/client/live_order_page.dart';
import 'package:flutter_application_1/pages/shared/demande_page.dart';
import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:flutter_application_1/utils/location_service.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/user_profile_cache.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// A single tappable option in the bottom panel - either one of the
/// top-level common questions or a follow-up sub-question.
class _Chip {
  final String label;
  final VoidCallback onTap;
  const _Chip(this.label, this.onTap);
}

/// The "..." bubble shown in place of the bot's answer while it's still
/// loading - three dots pulsing in sequence, looping until [_hideTyping]
/// removes the bubble that wraps this.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (var i = 0; i < 3; i++) _dot(i)],
      ),
    );
  }

  Widget _dot(int index) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = (_controller.value + index * 0.2) % 1.0;
        final opacity = 0.3 + 0.7 * (0.5 - 0.5 * math.cos(2 * math.pi * t));
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.5),
          child: Opacity(
            opacity: opacity,
            child: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                  color: Color(0xFF9AA1AC), shape: BoxShape.circle),
            ),
          ),
        );
      },
    );
  }
}

/// Chat-style help assistant ("Assistant Talabaty" in the design) - see
/// `lib/note.txt` for the full question-by-question spec this implements.
/// Three ways in:
///  - plain (profile page): common top-level questions
///  - [startAtTransactionSearch] (transactions_page.dart): asks for a
///    transaction number first
///  - [orderId] (order_history_detail_page.dart): jumps straight to that
///    order - still-open or delivered <3 days ago shows the report
///    sub-questions, older just shows the order's info with a notice
class HelpPage extends StatefulWidget {
  final String language;
  final String? orderId;
  final bool startAtTransactionSearch;

  const HelpPage(
    this.language, {
    this.orderId,
    this.startAtTransactionSearch = false,
    super.key,
  });

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> with AlertCardMixin {
  // Every Firestore read below is chained with `.timeout(_networkTimeout)` -
  // without it, a stuck/slow read leaves `_busy` stuck true forever (no
  // error, no answer, and every tap after it - including on other
  // questions - silently swallowed by the `if (_busy) return;` guards until
  // whatever was stuck finally resolves, at which point several delayed
  // answers can land together). A timeout turns that into a normal caught
  // exception (already classified as a connectivity error by
  // isConnectivityError) instead of an indefinite hang.
  static const _networkTimeout = Duration(seconds: 12);

  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final _scrollController = ScrollController();

  final List<Widget> _messages = [];
  final List<Widget Function()> _panelStack = [];
  Widget? _panel;
  bool _busy = false;

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _addBotText(TranslationHelper.get('help_greeting'));
    _bootstrap();
  }

  @override
  void dispose() {
    disposeAlert();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final orderId = widget.orderId;
    if (orderId != null) {
      setState(() => _busy = true);
      _showTyping();
      try {
        final doc = await _firestore
            .collection('orders')
            .doc(orderId)
            .get()
            .timeout(_networkTimeout);
        if (!mounted) return;
        final data = doc.data();
        if (data == null) {
          _hideTyping();
          _showTopLevelChips();
        } else {
          // _onOrderPicked shows its own typing bubble for the
          // existing-report check that follows - this one just covers the
          // initial order fetch, so it's left visible in between rather
          // than flickering hidden/shown for one Firestore round trip.
          await _onOrderPicked(orderId, data, announce: false);
        }
      } catch (e) {
        if (mounted) {
          _hideTyping();
          _addBotText(TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'));
          _showTopLevelChips();
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    } else if (widget.startAtTransactionSearch) {
      _showTransactionNumberCard();
    } else {
      _showTopLevelChips();
    }
  }

  // ---------------------------------------------------------------------
  // Panel stack / message log plumbing
  // ---------------------------------------------------------------------

  void _pushPanel(Widget Function() builder) {
    _panelStack.add(builder);
    setState(() => _panel = builder());
  }

  /// Replaces the current panel without growing the back stack - used when
  /// a flow resets to the top-level list (going "back" from there should
  /// leave the app, not replay the sub-question that led here).
  void _resetPanel(Widget Function() builder) {
    _panelStack
      ..clear()
      ..add(builder);
    setState(() => _panel = builder());
  }

  void _popPanel() {
    if (_panelStack.length <= 1) return;
    _panelStack.removeLast();
    setState(() => _panel = _panelStack.last());
  }

  void _showTopLevelChips() {
    _resetPanel(() => _chipsPanel([
          _Chip(TranslationHelper.get('help_q_where_order'), _onWhereIsMyOrder),
          _Chip(TranslationHelper.get('help_q_transaction_problem'),
              _onTransactionProblem),
          _Chip(TranslationHelper.get('help_q_delivery_fee'), _onDeliveryFee),
          _Chip(TranslationHelper.get('help_q_refund'), _onRefund),
          _Chip(TranslationHelper.get('help_q_become_delivery'),
              _onBecomeDelivery),
          _Chip(
              TranslationHelper.get('help_q_become_partner'), _onBecomePartner),
        ]));
  }

  void _showTransactionNumberCard() {
    _resetPanel(() => _TransactionNumberCard(
          isArabic: _isArabic,
          onSubmit: _searchTransactionNumber,
        ));
  }

  void _addUser(String text) {
    setState(() => _messages.add(_bubble(
        Text(
          text,
          style: const TextStyle(fontSize: 13.5, color: Colors.white),
        ),
        isUser: true)));
    _scrollToBottom();
  }

  void _addBotText(String text) {
    setState(() => _messages.add(_bubble(
          Text(
            text,
            style: const TextStyle(
                fontSize: 13.5, color: Color(0xFF2E3A59), height: 1.4),
          ),
          isUser: false,
        )));
    _scrollToBottom();
  }

  void _addBotWidget(Widget child) {
    setState(() => _messages.add(_bubble(child, isUser: false)));
    _scrollToBottom();
  }

  // A typing bubble shown while the bot's answer is still loading (a
  // Firestore round trip, not instant like a static answer) - always the
  // last message while visible, popped off again the moment the real
  // answer/error is about to be added.
  bool _typingVisible = false;

  void _showTyping() {
    if (_typingVisible) return;
    _typingVisible = true;
    setState(() => _messages.add(_bubble(const _TypingDots(), isUser: false)));
    _scrollToBottom();
  }

  void _hideTyping() {
    if (!_typingVisible) return;
    _typingVisible = false;
    setState(() => _messages.removeLast());
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _bubble(Widget child, {required bool isUser}) {
    return Align(
      alignment: isUser
          ? (_isArabic ? Alignment.centerLeft : Alignment.centerRight)
          : (_isArabic ? Alignment.centerRight : Alignment.centerLeft),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFFF9800) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: isUser
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
        ),
        child: child,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // "Où est ma commande ?"
  // ---------------------------------------------------------------------

  Future<void> _onWhereIsMyOrder() async {
    _addUser(TranslationHelper.get('help_q_where_order'));
    if (_busy) return;
    setState(() => _busy = true);
    _showTyping();
    try {
      var snap = await _firestore
          .collection('orders')
          .where('user_id', isEqualTo: _uid)
          .where('order_end', isEqualTo: false)
          .orderBy('created_at', descending: true)
          .get()
          .timeout(_networkTimeout);
      var isFallback = false;
      if (snap.docs.isEmpty) {
        isFallback = true;
        final cutoff = Timestamp.fromDate(
            DateTime.now().subtract(const Duration(days: 3)));
        // `order_end == true` is redundant in meaning (the query above just
        // found no `order_end == false` orders, so anything left is ended)
        // but not in practice: it lets this use the existing
        // (user_id, order_end, created_at) composite index. Without it this
        // needs a (user_id, created_at) one that `orders` doesn't have, and
        // the missing index surfaced as a generic "error" instead of the
        // "no order found" message whenever a user had no active order.
        snap = await _firestore
            .collection('orders')
            .where('user_id', isEqualTo: _uid)
            .where('order_end', isEqualTo: true)
            .where('created_at', isGreaterThan: cutoff)
            .orderBy('created_at', descending: true)
            .limit(5)
            .get()
            .timeout(_networkTimeout);
      }
      if (!mounted) return;
      _hideTyping();
      if (snap.docs.isEmpty) {
        _addBotText(TranslationHelper.get('help_no_order_found'));
        _showTopLevelChips();
        return;
      }
      _addBotText(TranslationHelper.get(isFallback
          ? 'help_no_active_order_intro'
          : 'help_active_orders_intro'));
      _addBotWidget(_orderListCard(snap.docs));
      _pushPanel(() => _chipsPanel(const []));
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _orderListCard(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final doc in docs) ...[
          _orderRow(doc.id, doc.data()),
          if (doc != docs.last)
            const Divider(height: 16, color: Color(0xFFF0F1F4)),
        ],
      ],
    );
  }

  Widget _orderRow(String orderId, Map<String, dynamic> data) {
    final number = data['order_number'] as String? ?? orderId;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // Not `_busy ? null : ...` - this row is built once (inside the try
      // block that's still busy) and never rebuilt afterward, so a snapshot
      // of `_busy` baked in here would freeze it as null forever. `_busy` is
      // read live instead, at the moment of the actual tap.
      onTap: () {
        if (_busy) return;
        _onOrderPicked(orderId, data);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    TranslationHelper.get(
                        'order_number_label', {'number': number}),
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2E3A59)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _orderStatusLabel(data),
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                  ),
                ],
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

  /// Mirrors the label mapping orders_list_page.dart already uses for the
  /// client's own live order board, so the same order reads the same way
  /// here as it does there.
  String _orderStatusLabel(Map<String, dynamic> data) {
    if (data['order_status'] == 'cancelled') {
      return TranslationHelper.get('order_status_cancelled');
    }
    if (data['order_end'] == true) {
      return TranslationHelper.get('order_status_delivered');
    }
    final deliveryStatus = data['delivery_status'] as String?;
    if (deliveryStatus == 'on_the_way' || deliveryStatus == 'arrived') {
      return TranslationHelper.get('order_status_${deliveryStatus}_label');
    }
    final orderStatus = data['order_status'] as String? ?? 'placed';
    const known = {'placed', 'accepted', 'preparing', 'ready'};
    return TranslationHelper.get(
        'order_status_${known.contains(orderStatus) ? orderStatus : 'placed'}_label');
  }

  Future<void> _onOrderPicked(String orderId, Map<String, dynamic> data,
      {bool announce = true}) async {
    if (announce) {
      final number = data['order_number'] as String? ?? orderId;
      _addUser(TranslationHelper.get('order_number_label', {'number': number}));
    }
    final orderEnded = data['order_end'] == true;
    final createdAt = (data['created_at'] as Timestamp?)?.toDate();
    final recent = createdAt != null &&
        DateTime.now().difference(createdAt) < const Duration(days: 3);
    final allowComplaint = !orderEnded || recent;

    if (!allowComplaint) {
      _hideTyping();
      _addBotWidget(_orderInfoCard(data, showTrack: false));
      _addBotText(TranslationHelper.get('help_order_too_old_notice'));
      _showTopLevelChips();
      return;
    }

    setState(() => _busy = true);
    _showTyping();
    try {
      final existing = await _firestore
          .collection('reports')
          .where('order_id', isEqualTo: orderId)
          .where('reporter', isEqualTo: _uid)
          .where('status', whereIn: ['pending', 'processing'])
          .limit(1)
          .get()
          .timeout(_networkTimeout);
      if (!mounted) return;
      _hideTyping();
      if (existing.docs.isNotEmpty) {
        _addBotWidget(_existingReportCard(existing.docs.first.data()));
        _showTopLevelChips();
        return;
      }
      _addBotWidget(
          _orderInfoCard(data, showTrack: !orderEnded, orderId: orderId));
      _pushPanel(() => _chipsPanel(_orderIssueChips(orderId, data)));
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _orderInfoCard(Map<String, dynamic> data,
      {required bool showTrack, String? orderId}) {
    final storeName = _isArabic
        ? (data['store_name_ar'] as String? ?? '')
        : (data['store_name_fr'] as String? ?? '');
    final number = data['order_number'] as String? ?? orderId ?? '';
    final createdAt = (data['created_at'] as Timestamp?)?.toDate();
    final cancelledAt = (data['cancelled_at'] as Timestamp?)?.toDate();
    final deliveredAt =
        ((data['delivered_at'] ?? data['completed_at']) as Timestamp?)
            ?.toDate();
    final currency = TranslationHelper.get('currency_unit');
    String money(String key) =>
        '${((data[key] as num?) ?? 0).toStringAsFixed(0)} $currency';
    final discount = (data['discount'] as num?) ?? 0;
    final lines = _mergeLinesByItem(data);

    Widget row(String labelKey, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(TranslationHelper.get(labelKey),
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC))),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontSize: bold ? 13.5 : 12.5,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
                      color: const Color(0xFF2E3A59)),
                ),
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          storeName.isNotEmpty
              ? storeName
              : TranslationHelper.get('unknown_store'),
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59)),
        ),
        if (number.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            TranslationHelper.get('order_number_label', {'number': number}),
            style: const TextStyle(fontSize: 12.5, color: Color(0xFFFF9800)),
          ),
        ],
        const SizedBox(height: 8),
        row('help_order_status_label', _orderStatusLabel(data)),
        if (createdAt != null)
          row('help_order_date_label', _dateLabel(createdAt)),
        if (cancelledAt != null)
          row('help_order_cancelled_at_label', _dateLabel(cancelledAt)),
        if (deliveredAt != null && data['order_status'] != 'cancelled')
          row('help_order_delivered_at_label', _dateLabel(deliveredAt)),
        row('help_order_payment_label',
            _paymentLabel(data['payment_type'] as String? ?? '')),
        if (lines.isNotEmpty) ...[
          const Divider(height: 18, color: Color(0xFFF0F1F4)),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${(line['quantity'] as num?)?.toInt() ?? 1}x ${_lineName(line)}',
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFF2E3A59)),
              ),
            ),
        ],
        const Divider(height: 18, color: Color(0xFFF0F1F4)),
        row('subtotal_label', money('subtotal')),
        row('delivery_fee_label', money('delivery_fee')),
        row('service_fee_label', money('service_fee')),
        if (discount > 0)
          row('discount_label', '-${discount.toStringAsFixed(0)} $currency'),
        row('total_label', money('total'), bold: true),
        if (showTrack && orderId != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LiveOrderPage(widget.language, orderId),
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF9800),
                side: const BorderSide(color: Color(0xFFFF9800)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(TranslationHelper.get('help_track_live_button')),
            ),
          ),
        ],
      ],
    );
  }

  /// Same meaning as order_history_detail_page.dart's label: `payment_type`
  /// is "cash_payment", "wallet_balance", or a provider's own name - shown
  /// as-is when it's not one of the two known values.
  String _paymentLabel(String paymentType) {
    switch (paymentType) {
      case 'cash_payment':
        return TranslationHelper.get('payment_type_cash');
      case 'wallet_balance':
        return TranslationHelper.get('payment_type_wallet_balance');
      default:
        return paymentType.isNotEmpty
            ? paymentType
            : TranslationHelper.get('payment_type_cash');
    }
  }

  String _lineName(Map<String, dynamic> line) {
    final nameAr = line['name_ar'] as String? ?? '';
    final nameFr = line['name_fr'] as String? ?? '';
    return _isArabic && nameAr.isNotEmpty ? nameAr : nameFr;
  }

  Widget _existingReportCard(Map<String, dynamic> report) {
    final reportType = report['report_type'] as String? ?? '';
    final reason = report['reason'] as String?;
    final status = report['status'] as String? ?? 'pending';
    final message = report['messages'] as String? ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          TranslationHelper.get('help_existing_report_intro'),
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF2E3A59)),
        ),
        const SizedBox(height: 6),
        Text(
          // reason is the specific complaint title ("Commande jamais
          // livrée", "Articles manquants", ...) - falls back to the old
          // coarse report_type label for a report created before this field
          // existed.
          TranslationHelper.get(reason != null
              ? 'help_report_reason_$reason'
              : 'help_report_type_$reportType'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF2E3A59)),
        ),
        const SizedBox(height: 2),
        Text(
          TranslationHelper.get('help_report_status_$status'),
          style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(message,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF677489))),
        ],
      ],
    );
  }

  /// What can be reported about this particular order. A cancelled order was
  /// never delivered, so "I didn't receive it" / "missing items" make no
  /// sense for it - instead, if it was paid online (anything but cash) the
  /// user can ask where their refund is.
  List<_Chip> _orderIssueChips(String orderId, Map<String, dynamic> data) {
    final cancelled = data['order_status'] == 'cancelled';
    final paymentType = data['payment_type'] as String? ?? '';
    final paidOnline = paymentType.isNotEmpty && paymentType != 'cash_payment';
    return [
      if (!cancelled) ...[
        _Chip(TranslationHelper.get('help_q_order_not_received'),
            () => _onOrderIssueChosen('not_received', orderId, data)),
        _Chip(TranslationHelper.get('help_q_order_missing'),
            () => _onOrderIssueChosen('missing', orderId, data)),
      ],
      if (cancelled && paidOnline)
        _Chip(TranslationHelper.get('help_q_refund_not_received'),
            () => _onRefundNotReceived(orderId, data)),
      _Chip(TranslationHelper.get('help_q_order_problem'),
          () => _onOrderIssueChosen('problem', orderId, data)),
    ];
  }

  /// A cancelled, online-paid order should have two `users_transactions`
  /// docs sharing its `order_id`: the original payment and (written by
  /// cancelOrder.js) a `refund`. Found -> just show it. Missing (or failed)
  /// -> a report message is prepared for the user, who only has to send it.
  Future<void> _onRefundNotReceived(
      String orderId, Map<String, dynamic> order) async {
    _addUser(TranslationHelper.get('help_q_refund_not_received'));
    if (_busy) return;
    setState(() => _busy = true);
    _showTyping();
    try {
      final snap = await _firestore
          .collection('users_transactions')
          .where('user_id', isEqualTo: _uid)
          .where('order_id', isEqualTo: orderId)
          .get()
          .timeout(_networkTimeout);
      if (!mounted) return;
      _hideTyping();

      Map<String, dynamic>? refund;
      for (final doc in snap.docs) {
        final tx = doc.data();
        if (tx['type'] == 'refund' && tx['status'] != 'failed') {
          refund = tx;
          break;
        }
      }

      if (refund != null) {
        _addBotText(TranslationHelper.get('help_refund_found_intro'));
        _addBotWidget(_transactionCard(refund));
        _addBotText(TranslationHelper.get(refund['status'] == 'pending'
            ? 'help_refund_pending_notice'
            : 'help_refund_completed_notice'));
        _showTopLevelChips();
        return;
      }

      _addBotText(TranslationHelper.get('help_refund_missing_notice'));
      _pushPanel(() => _MessageCard(
            isArabic: _isArabic,
            fixedMessage: TranslationHelper.get('help_refund_report_message'),
            onSend: (_, __) => _sendRefundReport(orderId, order),
            onCancel: _popPanel,
          ));
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendRefundReport(
      String orderId, Map<String, dynamic> order) async {
    await _createReport(
      reportType: 'user_system',
      reason: 'refund_not_received',
      reported: 'system',
      // Stored in French like the other fixed report messages (the admin
      // side reads these), not in the user's own language.
      message: 'Commande annulée : remboursement non reçu.',
      orderId: orderId,
      transactionId: order['transaction_id'] as String?,
      cityId: order['city_id'] as String?,
      priority: 'high',
    );
    if (!mounted) return;
    _addBotText(TranslationHelper.get('help_report_sent'));
    _showTopLevelChips();
  }

  void _onOrderIssueChosen(
      String kind, String orderId, Map<String, dynamic> order) {
    switch (kind) {
      case 'not_received':
        _addUser(TranslationHelper.get('help_q_order_not_received'));
        _pushPanel(() => _MessageCard(
              isArabic: _isArabic,
              fixedMessage:
                  TranslationHelper.get('help_order_not_received_message'),
              onSend: (_, __) => _sendOrderReport(
                reportType: 'user_order',
                reason: 'order_not_received',
                orderId: orderId,
                order: order,
                message: 'Je n\'ai pas reçu ma commande.',
              ),
              onCancel: _popPanel,
            ));
        break;
      case 'missing':
        _addUser(TranslationHelper.get('help_q_order_missing'));
        final lines = _mergeLinesByItem(order);
        _pushPanel(() => _MissingItemsCard(
              isArabic: _isArabic,
              lines: lines,
              onSend: (message) => _sendOrderReport(
                reportType: 'user_store',
                reason: 'items_missing',
                orderId: orderId,
                order: order,
                message: message,
              ),
              onCancel: _popPanel,
            ));
        break;
      case 'problem':
        _addUser(TranslationHelper.get('help_q_order_problem'));
        _pushPanel(() => _MessageCard(
              isArabic: _isArabic,
              hint: TranslationHelper.get('help_problem_hint'),
              showImageButton: true,
              onSend: (message, images) => _sendOrderReport(
                reportType: 'user_store',
                reason: 'order_problem',
                orderId: orderId,
                order: order,
                message: message,
                images: images,
              ),
              onCancel: _popPanel,
            ));
        break;
    }
  }

  List<Map<String, dynamic>> _mergeLinesByItem(Map<String, dynamic> order) {
    final linesMap = (order['lines'] as Map?) ?? {};
    final merged = <String, Map<String, dynamic>>{};
    final orderKeys = <String>[];
    for (final raw in linesMap.values) {
      final line = (raw as Map).cast<String, dynamic>();
      final itemId = line['item_id'] as String? ?? line.hashCode.toString();
      final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
      final existing = merged[itemId];
      if (existing == null) {
        orderKeys.add(itemId);
        merged[itemId] = {...line, 'quantity': quantity};
      } else {
        existing['quantity'] = (existing['quantity'] as int) + quantity;
      }
    }
    return [for (final id in orderKeys) merged[id]!];
  }

  Future<void> _sendOrderReport({
    required String reportType,
    required String reason,
    required String orderId,
    required Map<String, dynamic> order,
    required String message,
    List<String> images = const [],
  }) async {
    await _createReport(
      reportType: reportType,
      reason: reason,
      reported: order['store_id'] as String? ?? '',
      message: message,
      images: images,
      orderId: orderId,
      transactionId: order['transaction_id'] as String?,
      cityId: order['city_id'] as String?,
      priority: 'high',
    );
    if (!mounted) return;
    _addBotText(TranslationHelper.get('help_report_sent'));
    _showTopLevelChips();
  }

  // ---------------------------------------------------------------------
  // "Problème avec une transaction"
  // ---------------------------------------------------------------------

  Future<void> _onTransactionProblem() async {
    _addUser(TranslationHelper.get('help_q_transaction_problem'));
    if (_busy) return;
    setState(() => _busy = true);
    _showTyping();
    try {
      final cutoff =
          Timestamp.fromDate(DateTime.now().subtract(const Duration(days: 3)));
      final snap = await _firestore
          .collection('users_transactions')
          .where('user_id', isEqualTo: _uid)
          .where('created_at', isGreaterThan: cutoff)
          .orderBy('created_at', descending: true)
          .limit(5)
          .get()
          .timeout(_networkTimeout);
      if (!mounted) return;
      _hideTyping();
      if (snap.docs.isEmpty) {
        _addBotText(TranslationHelper.get('help_no_transaction_found'));
        _showTopLevelChips();
        return;
      }
      _addBotText(TranslationHelper.get('help_recent_transactions_intro'));
      _addBotWidget(_transactionListCard(snap.docs));
      _pushPanel(() => _chipsPanel(const []));
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _searchTransactionNumber(String number) async {
    _addUser(number);
    if (_busy) return;
    setState(() => _busy = true);
    _showTyping();
    try {
      final snap = await _firestore
          .collection('users_transactions')
          .where('transaction_number', isEqualTo: number)
          .where('user_id', isEqualTo: _uid)
          .limit(1)
          .get()
          .timeout(_networkTimeout);
      if (!mounted) return;
      if (snap.docs.isEmpty) {
        _hideTyping();
        _addBotText(TranslationHelper.get('help_transaction_not_found'));
        _showTopLevelChips();
        return;
      }
      await _onTransactionPicked(snap.docs.first.id, snap.docs.first.data());
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _transactionListCard(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final doc in docs) ...[
          _transactionRow(doc.id, doc.data()),
          if (doc != docs.last)
            const Divider(height: 16, color: Color(0xFFF0F1F4)),
        ],
      ],
    );
  }

  Widget _transactionRow(String transactionId, Map<String, dynamic> data) {
    final number = data['transaction_number'] as String? ?? transactionId;
    final type = data['type'] as String? ?? 'order_payment';
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // Live `_busy` check at tap time - see _orderRow's comment.
      onTap: () {
        if (_busy) return;
        _onTransactionPicked(transactionId, data);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '#$number — ${TranslationHelper.get('transaction_type_$type')}',
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2E3A59)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${amount.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                  ),
                ],
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

  Future<void> _onTransactionPicked(
      String transactionId, Map<String, dynamic> data,
      {bool announce = true}) async {
    if (announce) {
      final number = data['transaction_number'] as String? ?? transactionId;
      final type = data['type'] as String? ?? 'order_payment';
      _addUser('#$number — ${TranslationHelper.get('transaction_type_$type')}');
    }
    setState(() => _busy = true);
    _showTyping();
    try {
      final existing = await _firestore
          .collection('reports')
          .where('transaction_id', isEqualTo: transactionId)
          .where('reporter', isEqualTo: _uid)
          .where('status', whereIn: ['pending', 'processing'])
          .limit(1)
          .get()
          .timeout(_networkTimeout);
      if (!mounted) return;
      _hideTyping();
      if (existing.docs.isNotEmpty) {
        _addBotWidget(_existingReportCard(existing.docs.first.data()));
        _showTopLevelChips();
        return;
      }
      _addBotWidget(_transactionCard(data));
      final type = data['type'] as String? ?? 'order_payment';
      final chips = <_Chip>[
        if (type == 'order_payment' || type == 'withdraw')
          _Chip(TranslationHelper.get('help_q_tx_not_mine'),
              () => _onTxIssueChosen('not_mine', transactionId, data)),
        if (type == 'deduction')
          _Chip(TranslationHelper.get('help_q_tx_why_deduction'),
              () => _onTxIssueChosen('why_deduction', transactionId, data)),
        _Chip(TranslationHelper.get('help_q_tx_error'),
            () => _onTxIssueChosen('error', transactionId, data)),
      ];
      _pushPanel(() => _chipsPanel(chips));
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _transactionCard(Map<String, dynamic> data) {
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    final createdAt = (data['created_at'] as Timestamp?)?.toDate();
    final type = data['type'] as String? ?? 'order_payment';
    final status = data['status'] as String? ?? 'completed';
    final paymentType = data['payment_type'] as String? ?? '';
    Widget row(String labelKey, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(TranslationHelper.get(labelKey),
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC))),
              Text(value,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59))),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('help_transaction_amount_label',
            '${amount.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}'),
        if (createdAt != null)
          row('help_transaction_date_label', _dateLabel(createdAt)),
        row('help_transaction_type_label',
            TranslationHelper.get('transaction_type_$type')),
        row('help_transaction_status_label',
            TranslationHelper.get('transaction_status_$status')),
        if (paymentType.isNotEmpty)
          row('help_transaction_payment_type_label', paymentType),
      ],
    );
  }

  void _onTxIssueChosen(
      String kind, String transactionId, Map<String, dynamic> tx) {
    switch (kind) {
      case 'not_mine':
        _addUser(TranslationHelper.get('help_q_tx_not_mine'));
        _pushPanel(() => _MessageCard(
              isArabic: _isArabic,
              hint: TranslationHelper.get('help_tx_not_mine_hint'),
              onSend: (message, _) => _sendTxReport(
                transactionId: transactionId,
                tx: tx,
                message: message,
                priority: 'high',
                reason: 'tx_not_mine',
              ),
              onCancel: _popPanel,
            ));
        break;
      case 'why_deduction':
        _addUser(TranslationHelper.get('help_q_tx_why_deduction'));
        _pushPanel(() => _chipsPanel([
              _Chip(
                TranslationHelper.get('help_make_report_chip'),
                () {
                  _pushPanel(() => _MessageCard(
                        isArabic: _isArabic,
                        hint: TranslationHelper.get('help_tx_deduction_hint'),
                        onSend: (message, _) => _sendTxReport(
                          transactionId: transactionId,
                          tx: tx,
                          message: message,
                          priority: 'high',
                          reason: 'tx_deduction',
                        ),
                        onCancel: _popPanel,
                      ));
                },
              ),
            ]));
        break;
      case 'error':
        _addUser(TranslationHelper.get('help_q_tx_error'));
        _pushPanel(() => _MessageCard(
              isArabic: _isArabic,
              hint: TranslationHelper.get('help_tx_error_hint'),
              onSend: (message, _) => _sendTxReport(
                transactionId: transactionId,
                tx: tx,
                message: message,
                priority: 'normal',
                reason: 'tx_error',
              ),
              onCancel: _popPanel,
            ));
        break;
    }
  }

  Future<void> _sendTxReport({
    required String transactionId,
    required Map<String, dynamic> tx,
    required String message,
    required String priority,
    required String reason,
  }) async {
    final summary = tx['summary_section'] as Map?;
    await _createReport(
      reportType: 'user_system',
      reason: reason,
      reported: 'system',
      message: message,
      transactionId: transactionId,
      orderId: tx['order_id'] as String?,
      cityId: summary?['city_id'] as String?,
      priority: priority,
    );
    if (!mounted) return;
    _addBotText(TranslationHelper.get('help_report_sent'));
    _showTopLevelChips();
  }

  // ---------------------------------------------------------------------
  // "Frais de livraison" / "Demander un remboursement" / partner
  // ---------------------------------------------------------------------

  Future<void> _onDeliveryFee() async {
    _addUser(TranslationHelper.get('help_q_delivery_fee'));
    if (_busy) return;
    setState(() => _busy = true);
    _showTyping();
    try {
      // The active location's city (LocationService) - fees by city id.
      final cityId = LocationService.instance.cityId;
      final Map<String, dynamic>? city = cityId == null
          ? null
          : await CitiesService.instance
              .fetchCityDoc(cityId)
              .timeout(_networkTimeout);
      if (!mounted) return;
      _hideTyping();
      if (city == null) {
        _addBotText(TranslationHelper.get('help_delivery_fee_generic'));
      } else {
        final base = (city['delivery_fee'] as num?) ?? 0;
        final km = (city['km_fee'] as num?) ?? 0;
        final service = (city['service_fee'] as num?) ?? 0;
        final rainFee = (city['rain_fee'] as num?) ?? 0;
        final isRaining = city['rain'] == true;
        final currency = TranslationHelper.get('currency_unit');
        final rainNote = isRaining
            ? TranslationHelper.get('help_delivery_fee_rain_note',
                {'amount': rainFee, 'currency': currency})
            : '';
        _addBotText(TranslationHelper.get('help_delivery_fee_explanation', {
          'base': base,
          'km': km,
          'service': service,
          'currency': currency,
          'rain': rainNote,
        }));
      }
      _showTopLevelChips();
    } catch (e) {
      if (mounted) {
        _hideTyping();
        _addBotText(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        _showTopLevelChips();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onRefund() {
    _addUser(TranslationHelper.get('help_q_refund'));
    _addBotText(TranslationHelper.get('help_refund_message'));
    _showTopLevelChips();
  }

  void _onBecomePartner() {
    if (_blockIfAlreadyHasRole('help_q_become_partner')) return;
    _showApplyCard(
      questionKey: 'help_q_become_partner',
      messageKey: 'help_become_partner_message',
      type: DemandeType.store,
    );
  }

  void _onBecomeDelivery() {
    if (_blockIfAlreadyHasRole('help_q_become_delivery')) return;
    _showApplyCard(
      questionKey: 'help_q_become_delivery',
      messageKey: 'help_become_delivery_message',
      type: DemandeType.delivery,
    );
  }

  /// `role` (UserProfileCache) is only ever "owner"/"delivery"/null, and a
  /// user only ever holds one of the two - an existing driver can't also
  /// apply to become a store owner, and vice versa, not just "can't apply
  /// again for the role they already have". So this blocks BOTH apply flows
  /// the moment role is non-null, showing the message that matches the
  /// user's own actual role rather than whichever button they just tapped.
  /// Returns true (and shows the message) if blocked.
  bool _blockIfAlreadyHasRole(String questionKey) {
    final role = UserProfileCache.instance.role;
    if (role != 'owner' && role != 'delivery') return false;
    _addUser(TranslationHelper.get(questionKey));
    _addBotText(TranslationHelper.get(role == 'owner'
        ? 'help_already_store_message'
        : 'help_already_delivery_message'));
    _showTopLevelChips();
    return true;
  }

  /// One question ("become a partner" / "become a delivery driver"), one
  /// answer with a "Commencer" button that opens the matching application
  /// form (DemandePage) - the two flows differ only in which type is passed.
  /// Only reached once the role check above has already ruled out the user
  /// already being that role.
  void _showApplyCard({
    required String questionKey,
    required String messageKey,
    required DemandeType type,
  }) {
    _addUser(TranslationHelper.get(questionKey));
    _addBotWidget(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          TranslationHelper.get(messageKey),
          style: const TextStyle(
              fontSize: 13.5, color: Color(0xFF2E3A59), height: 1.4),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => _openDemande(type),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF9800),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(TranslationHelper.get('help_start_button')),
          ),
        ),
      ],
    ));
    _showTopLevelChips();
  }

  Future<void> _openDemande(DemandeType type) async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => DemandePage(widget.language, type)),
    );
    if (sent == true && mounted) {
      _addBotText(TranslationHelper.get('help_demande_sent'));
      _showTopLevelChips();
    }
  }

  String _dateLabel(DateTime date) {
    final month = TranslationHelper.get('month_${date.month}').toLowerCase();
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day} $month ${date.year}, $hour:$minute';
  }

  // ---------------------------------------------------------------------
  // report creation
  // ---------------------------------------------------------------------

  Future<void> _createReport({
    required String reportType,
    required String reason,
    required String reported,
    required String message,
    List<String> images = const [],
    String? orderId,
    String? transactionId,
    /// reports.city_id - straight from the order's / transaction's own
    /// city_id (lib/map.txt); null just leaves the report unrouted.
    String? cityId,
    required String priority,
  }) async {
    await _firestore.collection('reports').add({
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
      'report_type': reportType,
      // The specific complaint, shown as the report's title
      // (help_report_reason_$reason) - report_type stays the coarse
      // reporter/reported pair (map.txt) reserved for a future non-user
      // reporter, it was never meant to carry this level of detail.
      'reason': reason,
      'reported': reported,
      'reporter': _uid,
      'city_id': cityId,
      'status': 'pending',
      'action': 'none',
      'transaction_id': transactionId,
      'order_id': orderId,
      'priority': priority,
      'messages': message,
      'images': images,
    });
  }

  // ---------------------------------------------------------------------
  // Chrome
  // ---------------------------------------------------------------------

  Widget _chipsPanel(List<_Chip> chips) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chips.isNotEmpty) ...[
            Text(
              TranslationHelper.get('help_faq_label'),
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF9AA1AC),
                  letterSpacing: 0.5),
            ),
            const SizedBox(height: 8),
          ],
          // "Retour" is one more button in the same row as the questions,
          // styled exactly like them, instead of a separate text link.
          if (chips.isNotEmpty || _panelStack.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_panelStack.length > 1) _backChip(),
                for (final chip in chips) _chipButton(chip),
              ],
            ),
        ],
      ),
    );
  }

  Widget _backChip() {
    return _chipButton(
      _Chip(TranslationHelper.get('help_back'), _popPanel),
      icon: _isArabic ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
    );
  }

  Widget _chipButton(_Chip chip, {IconData? icon}) {
    return OutlinedButton(
      // Live `_busy` check at tap time, not baked in at build time - see
      // _orderRow's comment for why (this panel can be (re)built while
      // `_busy` is still true, right before its own handler's `finally`
      // resets it).
      onPressed: () {
        if (_busy) return;
        chip.onTap();
      },
      style: OutlinedButton.styleFrom(
        backgroundColor: const Color(0xFFFFF3E0),
        foregroundColor: const Color(0xFFB8631A),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              chip.label,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              if (alertCard != null) alertCard!,
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  // A copy, not `_messages` itself: ListView's delegate only
                  // rebuilds when the children list *instance* changes, so
                  // mutating the same list in place left new bubbles unpainted
                  // until something else forced a rebuild.
                  children: [..._messages],
                ),
              ),
              _panel ?? const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _isArabic
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: const Color(0xFF2E3A59),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child:
                const Icon(Icons.help_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              TranslationHelper.get('help_assistant_title'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A card asking for a transaction number (way 2 - opened from the
/// transactions page). Not found -> the page falls back to the top-level
/// question list, same as the plain entry point.
class _TransactionNumberCard extends StatefulWidget {
  final bool isArabic;
  final ValueChanged<String> onSubmit;
  const _TransactionNumberCard(
      {required this.isArabic, required this.onSubmit});

  @override
  State<_TransactionNumberCard> createState() => _TransactionNumberCardState();
}

class _TransactionNumberCardState extends State<_TransactionNumberCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -4))
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: TranslationHelper.get('help_transaction_number_hint'),
                filled: true,
                fillColor: const Color(0xFFF7F8FA),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: () {
              final value = _controller.text.trim();
              if (value.isEmpty) return;
              widget.onSubmit(value);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF9800),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(TranslationHelper.get('help_search_button')),
          ),
        ],
      ),
    );
  }
}

/// A free-text (or fixed-message) report card: either shows [fixedMessage]
/// as-is with just Envoyer/Annuler, or a text field the user fills in. The
/// image button ([showImageButton]) has no working upload behind it yet -
/// no image_picker/firebase_storage dependency is wired into this project -
/// it just tells the user it's coming, same pattern this app already uses
/// for other not-yet-built features.
class _MessageCard extends StatefulWidget {
  final bool isArabic;
  final String? fixedMessage;
  final String? hint;
  final bool showImageButton;
  final Future<void> Function(String message, List<String> images) onSend;
  final VoidCallback onCancel;

  const _MessageCard({
    required this.isArabic,
    this.fixedMessage,
    this.hint,
    this.showImageButton = false,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<_MessageCard> createState() => _MessageCardState();
}

class _MessageCardState extends State<_MessageCard> with AlertCardMixin {
  // Unlike every other upload in the app (demande_page.dart,
  // store_info_edit_page.dart/store_item_edit_page.dart), a report photo has
  // no size cap - it's evidence for a support case (a screenshot, a photo of
  // a wrong/missing item), and compressing/rejecting it could hide the
  // detail that actually matters.
  static const _maxImages = 3;

  final _controller = TextEditingController();
  final _images = <String>[];
  bool _sending = false;
  bool _uploadingImage = false;
  bool _sent = false;

  @override
  void dispose() {
    // A report photo is uploaded to Storage the moment it's picked (so the
    // thumbnail can show right away), before the report itself is ever
    // created - if this card goes away without a successful send (Annuler,
    // or just navigating back), those uploads would otherwise leak forever
    // with nothing ever referencing them. Best-effort, not awaited - dispose
    // can't be async, and a failed cleanup delete here is a harmless orphan
    // rather than a correctness problem.
    if (!_sent) {
      for (final url in _images) {
        FirebaseStorage.instance.refFromURL(url).delete().catchError((_) {});
      }
    }
    _controller.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _send() async {
    final message = widget.fixedMessage ?? _controller.text.trim();
    if (message.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(message, _images);
      _sent =
          true; // the report now owns these images - dispose() must not delete them
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _pickImage() async {
    if (_uploadingImage || _images.length >= _maxImages) return;
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 45,
        maxWidth: 1024,
      );
    } catch (e) {
      showAlert(TranslationHelper.get('error'), isError: true);
      return;
    }
    if (picked == null) return;

    setState(() => _uploadingImage = true);
    try {
      final online = await InternetConnectionService().checkNow();
      if (!online) throw Exception('offline');
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
      final ref =
          FirebaseStorage.instance.ref('reports/$uid/${const Uuid().v4()}.jpg');
      await ref.putFile(File(picked.path));
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() => _images.add(url));
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -4))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (alertCard != null) alertCard!,
          if (widget.fixedMessage != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.fixedMessage!,
                style:
                    const TextStyle(fontSize: 13.5, color: Color(0xFF2E3A59)),
              ),
            )
          else
            TextField(
              controller: _controller,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: widget.hint,
                filled: true,
                fillColor: const Color(0xFFF7F8FA),
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          if (widget.showImageButton) ...[
            const SizedBox(height: 8),
            if (_images.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final url in _images) _imageThumb(url)],
                ),
              ),
            if (_images.isNotEmpty) const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _images.length >= _maxImages
                    ? null
                    : (_uploadingImage ? null : _pickImage),
                icon: _uploadingImage
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF9AA1AC)),
                      )
                    : const Icon(Icons.image_outlined,
                        size: 17, color: Color(0xFF9AA1AC)),
                label: Text(
                  TranslationHelper.get('help_add_image_button'),
                  style:
                      const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF677489),
                    side: const BorderSide(color: Color(0xFFE5E8ED)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(TranslationHelper.get('help_cancel_button')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: _sending ? null : _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF9800),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(TranslationHelper.get('help_send')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _imageThumb(String url) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(url, width: 56, height: 56, fit: BoxFit.cover),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              setState(() => _images.remove(url));
              FirebaseStorage.instance
                  .refFromURL(url)
                  .delete()
                  .catchError((_) {});
            },
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                color: Color(0xFFE74C3C),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded,
                  size: 13, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

/// The "missing items" card - a +/- counter per line (0..its ordered
/// quantity), "Continuer" only enabled once at least one item is > 0, then
/// a composed message like "x1 Burger, x2 Frites" is handed to [onSend].
class _MissingItemsCard extends StatefulWidget {
  final bool isArabic;
  final List<Map<String, dynamic>> lines;
  final Future<void> Function(String) onSend;
  final VoidCallback onCancel;

  const _MissingItemsCard({
    required this.isArabic,
    required this.lines,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<_MissingItemsCard> createState() => _MissingItemsCardState();
}

class _MissingItemsCardState extends State<_MissingItemsCard>
    with AlertCardMixin {
  late final Map<String, int> _missing = {
    for (final line in widget.lines)
      (line['item_id'] as String? ?? line.hashCode.toString()): 0,
  };
  bool _sending = false;

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  // The report message is always written in French (read by admin), so the
  // French name is preferred whatever language the user's app is in.
  String _name(Map<String, dynamic> line) {
    final fr = line['name_fr'] as String? ?? '';
    if (fr.isNotEmpty) return fr;
    final ar = line['name_ar'] as String? ?? '';
    return ar;
  }

  Future<void> _send() async {
    if (_sending) return;
    final parts = <String>[];
    for (final line in widget.lines) {
      final id = line['item_id'] as String? ?? line.hashCode.toString();
      final count = _missing[id] ?? 0;
      if (count > 0) parts.add('x$count ${_name(line)}');
    }
    if (parts.isEmpty) return;
    setState(() => _sending = true);
    try {
      await widget.onSend('Articles manquants : ${parts.join(', ')}.');
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
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
    final hasAny = _missing.values.any((v) => v > 0);
    return Container(
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxHeight: 380),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -4))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (alertCard != null) alertCard!,
          Text(
            TranslationHelper.get('help_missing_items_intro'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [for (final line in widget.lines) _lineRow(line)],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF677489),
                    side: const BorderSide(color: Color(0xFFE5E8ED)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(TranslationHelper.get('help_cancel_button')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_sending || !hasAny) ? null : _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF9800),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFFFD9A6),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(TranslationHelper.get('help_continue_button')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lineRow(Map<String, dynamic> line) {
    final id = line['item_id'] as String? ?? line.hashCode.toString();
    final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
    final count = _missing[id] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _name(line),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF2E3A59)),
            ),
          ),
          _stepperButton(
              Icons.remove,
              count > 0
                  ? () => setState(() => _missing[id] = count - 1)
                  : null),
          SizedBox(
            width: 28,
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59)),
            ),
          ),
          _stepperButton(
              Icons.add,
              count < quantity
                  ? () => setState(() => _missing[id] = count + 1)
                  : null),
        ],
      ),
    );
  }

  Widget _stepperButton(IconData icon, VoidCallback? onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3E0),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 14,
            color: onTap == null
                ? const Color(0xFFC9CDD4)
                : const Color(0xFFFF9800)),
      ),
    );
  }
}
