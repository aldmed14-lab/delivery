import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/cart_page.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/order_reorder_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// One past order's full breakdown - items, price summary, delivery
/// address/time - read from the top-level `orders` collection
/// (`lib/map.txt`). Reached from [OrderHistoryListPage]'s "Détails" button.
class OrderHistoryDetailPage extends StatefulWidget {
  final String language;
  final String orderId;
  const OrderHistoryDetailPage(this.language, this.orderId, {super.key});

  @override
  State<OrderHistoryDetailPage> createState() =>
      _OrderHistoryDetailPageState();
}

class _OrderHistoryDetailPageState extends State<OrderHistoryDetailPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  // A field, not called inline in build(): building a new Future every
  // build (e.g. from a setState the alert card triggers) would replay the
  // loading skeleton on every unrelated state change instead of just once.
  late final Future<DocumentSnapshot<Map<String, dynamic>>> _orderFuture =
      _firestore.collection('orders').doc(widget.orderId).get();

  bool _isReordering = false;

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
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
                child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  future: _orderFuture,
                  builder: (context, snapshot) => _buildBody(snapshot),
                ),
              ),
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
          Text(
            TranslationHelper.get('order_detail_title'),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
      AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>> snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return _buildLoadingSkeleton();
    }

    if (snapshot.hasError) {
      return Center(
        child: Text(
          TranslationHelper.get(
              isConnectivityError(snapshot.error!) ? 'no_internet' : 'error'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }

    final doc = snapshot.data;
    if (doc == null || !doc.exists) {
      return Center(
        child: Text(
          TranslationHelper.get('order_not_found'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }

    return _buildContent(doc.data()!);
  }

  Widget _buildLoadingSkeleton() {
    Widget bar({double width = double.infinity, double height = 12}) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFEDEFF2),
            borderRadius: BorderRadius.circular(6),
          ),
        );
    Widget card({double height = 90}) => Container(
          width: double.infinity,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        card(height: 84),
        const SizedBox(height: 20),
        bar(width: 80),
        const SizedBox(height: 10),
        card(height: 130),
        const SizedBox(height: 20),
        bar(width: 100),
        const SizedBox(height: 10),
        card(height: 150),
      ],
    );
  }

  Widget _buildContent(Map<String, dynamic> data) {
    final storeId = data['store_id'] as String? ?? '';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _buildHeaderCard(data),
              const SizedBox(height: 20),
              _buildSectionLabel('articles_section_label'),
              const SizedBox(height: 8),
              _buildArticlesCard(data),
              const SizedBox(height: 20),
              _buildSectionLabel('summary_section_label'),
              const SizedBox(height: 8),
              _buildSummaryCard(data),
              const SizedBox(height: 20),
              _buildSectionLabel('delivery_section_label'),
              const SizedBox(height: 8),
              _buildDeliveryCard(data),
            ],
          ),
        ),
        if (storeId.isNotEmpty) _buildReorderBar(storeId, data),
      ],
    );
  }

  Widget _buildSectionLabel(String key) {
    return Text(
      TranslationHelper.get(key).toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: Color(0xFF9AA1AC),
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildHeaderCard(Map<String, dynamic> data) {
    final storeNameAr = data['store_name_ar'] as String? ?? '';
    final storeNameFr = data['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final storeImage = data['store_image'] as String? ?? '';
    final status = data['order_status'] as String? ?? 'completed';
    final orderNumber = data['order_number'] as String? ?? '';
    final isCancelled = status == 'cancelled';
    final statusLabel = TranslationHelper.get(
        isCancelled ? 'order_status_cancelled' : 'order_status_delivered');
    final statusColor =
        isCancelled ? const Color(0xFFE74C3C) : const Color(0xFF1B8A3E);
    final statusBg =
        isCancelled ? const Color(0xFFFDF1F0) : const Color(0xFFE6F7EA);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 56,
              height: 56,
              child: storeImage.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: storeImage,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(color: Colors.grey[200]),
                      errorWidget: (c, u, e) => _buildPlaceholderImage(),
                    )
                  : _buildPlaceholderImage(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  storeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59)),
                ),
                const SizedBox(height: 3),
                Text(
                  TranslationHelper.get('order_number_label', {'number': orderNumber}),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFFFF9800)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration:
                BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(10)),
            child: Text(
              statusLabel,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: statusColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderImage() {
    return Container(
      color: const Color(0xFFFFEFD9),
      child: const Icon(Icons.store_rounded, color: Color(0xFFFF9800), size: 24),
    );
  }

  Widget _buildArticlesCard(Map<String, dynamic> data) {
    final linesMap = (data['lines'] as Map?) ?? {};
    final lines = _mergeLinesByItem(linesMap.values
        .map((v) => (v as Map).cast<String, dynamic>())
        .toList());

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          for (final line in lines) _buildArticleRow(line),
        ],
      ),
    );
  }

  /// An item can have several lines (different group selections, e.g. one
  /// "large" pick and one "medium" pick of the same pizza) - merged here by
  /// `item_id` so each item shows as a single row (quantities/totals
  /// summed across its lines) instead of one row per line.
  List<Map<String, dynamic>> _mergeLinesByItem(List<Map<String, dynamic>> lines) {
    final merged = <String, Map<String, dynamic>>{};
    final order = <String>[];
    for (final line in lines) {
      final itemId = line['item_id'] as String? ?? line.hashCode.toString();
      final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
      final unitPrice = (line['price'] as num?)?.toDouble() ?? 0;
      final total = (line['total'] as num?)?.toDouble() ?? unitPrice * quantity;

      final existing = merged[itemId];
      if (existing == null) {
        order.add(itemId);
        merged[itemId] = {
          ...line,
          'quantity': quantity,
          'total': total,
        };
      } else {
        existing['quantity'] = (existing['quantity'] as int) + quantity;
        existing['total'] = (existing['total'] as double) + total;
      }
    }
    return [for (final id in order) merged[id]!];
  }

  Widget _buildArticleRow(Map<String, dynamic> line) {
    final nameAr = line['name_ar'] as String? ?? '';
    final nameFr = line['name_fr'] as String? ?? '';
    final name = (_isArabic ? nameAr : nameFr).isNotEmpty
        ? (_isArabic ? nameAr : nameFr)
        : nameFr;
    final quantity = (line['quantity'] as num?)?.toInt() ?? 1;
    final unitPrice = (line['price'] as num?)?.toDouble() ?? 0;
    final total = (line['total'] as num?)?.toDouble() ?? unitPrice * quantity;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(
            '${quantity}x',
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFFF9800)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF2E3A59)),
            ),
          ),
          Text(
            '${total.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
            style: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF2E3A59)),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(Map<String, dynamic> data) {
    final subtotal = (data['subtotal'] as num?)?.toDouble() ?? 0;
    final deliveryFee = (data['delivery_fee'] as num?)?.toDouble() ?? 0;
    final serviceFee = (data['service_fee'] as num?)?.toDouble() ?? 0;
    final discount = (data['discount'] as num?)?.toDouble() ?? 0;
    final total = (data['total'] as num?)?.toDouble() ?? 0;
    final currency = TranslationHelper.get('currency_unit');

    Widget row(String labelKey, double value, {bool negative = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              TranslationHelper.get(labelKey),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
            ),
            Text(
              '${negative ? '-' : ''}${value.toStringAsFixed(0)} $currency',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: negative ? const Color(0xFF1B8A3E) : const Color(0xFF2E3A59),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          row('subtotal_label', subtotal),
          row('delivery_fee_label', deliveryFee),
          row('service_fee_label', serviceFee),
          if (discount > 0) row('discount_label', discount, negative: true),
          const Divider(height: 20, color: Color(0xFFEDEFF2)),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  TranslationHelper.get('total_label'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF2E3A59)),
                ),
                Text(
                  '${total.toStringAsFixed(0)} $currency',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFFFF9800)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliveryCard(Map<String, dynamic> data) {
    final paymentType = data['payment_type'] as String? ?? '';
    final timestamp = (data['completed_at'] as Timestamp?) ??
        (data['delivered_at'] as Timestamp?) ??
        (data['created_at'] as Timestamp?);
    final dateLabel = timestamp == null ? '' : _formatDateTime(timestamp.toDate());

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.payments_outlined, color: Color(0xFFFF9800), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _paymentTypeLabel(paymentType),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF2E3A59)),
                ),
                if (dateLabel.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    dateLabel,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `payment_type` (`lib/map.txt`, matching `users_transactions`) is
  /// either "cash", "wallet_balance", or the name of a specific payment
  /// provider - shown as-is when it's not one of the two known values.
  String _paymentTypeLabel(String paymentType) {
    switch (paymentType) {
      case 'cash':
        return TranslationHelper.get('payment_type_cash');
      case 'wallet_balance':
        return TranslationHelper.get('payment_type_wallet_balance');
      default:
        return paymentType.isNotEmpty
            ? paymentType
            : TranslationHelper.get('payment_type_cash');
    }
  }

  String _formatDateTime(DateTime date) {
    final month = TranslationHelper.get('month_${date.month}').toLowerCase();
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day} $month ${date.year}, $hour:$minute';
  }

  Widget _buildReorderBar(String storeId, Map<String, dynamic> data) {
    return FutureBuilder<bool>(
      future: OrderReorderService.canReorder(_uid, storeId),
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -4)),
            ],
          ),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isReordering ? null : () => _reorder(data),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFFFC98A),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _isReordering
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
                    )
                  : Text(
                      TranslationHelper.get('reorder_button'),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _reorder(Map<String, dynamic> data) async {
    if (_isReordering) return;
    setState(() => _isReordering = true);
    try {
      final result = await OrderReorderService.reorder(uid: _uid, orderData: data);
      switch (result.outcome) {
        case ReorderOutcome.storeClosed:
          showAlert(TranslationHelper.get('reorder_store_inactive'), isError: true);
          break;
        case ReorderOutcome.differentCity:
          showAlert(TranslationHelper.get('reorder_different_city'), isError: true);
          break;
        case ReorderOutcome.waitingPayment:
          showAlert(TranslationHelper.get('reorder_waiting_payment'), isError: true);
          break;
        case ReorderOutcome.allUnavailable:
          showAlert(TranslationHelper.get('reorder_all_unavailable'), isError: true);
          break;
        case ReorderOutcome.partial:
          _openCartPage(
            data['store_id'] as String? ?? '',
            message: TranslationHelper.get(
                'reorder_partial', {'skipped': result.skippedCount}),
            isError: true,
          );
          break;
        case ReorderOutcome.success:
          _openCartPage(data['store_id'] as String? ?? '');
          break;
      }
    } finally {
      if (mounted) setState(() => _isReordering = false);
    }
  }

  void _openCartPage(String storeId, {String? message, bool isError = false}) {
    if (!mounted || storeId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CartPage(
          widget.language,
          _uid,
          storeId,
          initialMessage: message,
          initialMessageIsError: isError,
        ),
      ),
    );
  }
}
