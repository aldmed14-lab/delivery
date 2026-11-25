import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/pages/delivery/delivery_order_detail_page.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// Driver's assigned-orders board - every order currently handed to this
/// driver (`delivery_id == uid && order_end == false`). This list is
/// read-only: advancing a delivery's status (and cancelling it) only ever
/// happens from [DeliveryOrderDetailPage], not from a card here.
class DeliveryOrdersPage extends StatefulWidget {
  final String language;
  const DeliveryOrdersPage(this.language, {super.key});

  @override
  State<DeliveryOrdersPage> createState() => _DeliveryOrdersPageState();
}

class _DeliveryOrdersPageState extends State<DeliveryOrdersPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _ordersStream =
      _firestore
          .collection('orders')
          .where('delivery_id', isEqualTo: _uid)
          .where('order_end', isEqualTo: false)
          .snapshots();

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
      color: const Color(0xFF1B2A4A),
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
                color: Colors.white.withValues(alpha: 0.12),
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
              TranslationHelper.get('delivery_orders_page_title'),
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
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _ordersStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              TranslationHelper.get(isConnectivityError(snapshot.error!)
                  ? 'no_internet'
                  : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              TranslationHelper.get('delivery_ongoing_section'),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF9AA1AC),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),
            if (docs.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Center(
                  child: Text(
                    TranslationHelper.get('delivery_no_ongoing'),
                    style: const TextStyle(color: Color(0xFF9AA1AC)),
                  ),
                ),
              )
            else
              for (final order in docs) ...[
                _DeliveryOrderCard(language: widget.language, order: order),
                const SizedBox(height: 12),
              ],
          ],
        );
      },
    );
  }
}

class _DeliveryOrderCard extends StatelessWidget {
  final String language;
  final QueryDocumentSnapshot<Map<String, dynamic>> order;

  const _DeliveryOrderCard({required this.language, required this.order});

  bool get _isArabic => language == 'ar';

  // Reuses the same delivery_status_* keys store_orders_page.dart's
  // OrderCard already shows to the owner - one status vocabulary, not two.
  String _statusLabel(String status) =>
      TranslationHelper.get('delivery_status_$status');

  @override
  Widget build(BuildContext context) {
    final data = order.data();
    final orderNumber = data['order_number'] as String? ?? order.id;
    final status = data['delivery_status'] as String? ?? 'assigned';
    final storeName = _isArabic
        ? (data['store_name_ar'] as String? ?? '')
        : (data['store_name_fr'] as String? ?? '');
    final userAddress = (data['user_address'] as Map?)?.cast<String, dynamic>();
    final total = (data['total'] as num?) ?? 0;
    final currency = TranslationHelper.get('currency_unit');

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeliveryOrderDetailPage(language, order.id),
        ),
      ),
      child: Container(
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
                    TranslationHelper.get(
                        'order_number_label', {'number': orderNumber}),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusLabel(status),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFF9800),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (storeName.isNotEmpty)
              Text(
                TranslationHelper.get(
                    'delivery_pickup_label', {'store': storeName}),
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFF677489)),
              ),
            if (userAddress != null) ...[
              const SizedBox(height: 2),
              Text(
                TranslationHelper.get('delivery_dropoff_label', {
                  'lat': (userAddress['lat'] as num?)?.toStringAsFixed(4) ?? '',
                  'lng': (userAddress['lng'] as num?)?.toStringAsFixed(4) ?? '',
                }),
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFF677489)),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${total.toStringAsFixed(0)} $currency',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  TranslationHelper.get('delivery_show_details_button'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF9800),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _isArabic
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  size: 18,
                  color: const Color(0xFFFF9800),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
