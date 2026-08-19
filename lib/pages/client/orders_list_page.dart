import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/cart_page.dart';
import 'package:flutter_application_1/pages/client/live_order_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';

/// The client's live view of what's happening right now - carts stuck
/// waiting on payment (`users/{uid}/carts` with `waiting_payment: true`)
/// and in-progress orders (top-level `orders`, `order_status` not yet
/// "completed"/"cancelled"). Finished orders live on
/// [OrderHistoryListPage] instead.
class OrdersListPage extends StatefulWidget {
  final String language;
  const OrdersListPage(this.language, {super.key});

  @override
  State<OrdersListPage> createState() => _OrdersListPageState();
}

class _OrdersListPageState extends State<OrdersListPage> {
  static const _activeStatuses = ['placed', 'accepted', 'preparing', 'ready'];

  // Order statuses meaning "the store is still assembling it" - anything
  // past that (ready, or any delivery_status beyond pending) reads as
  // "on its way" instead. Coarser than the full order/delivery status
  // pipeline in `lib/map.txt`, but this is an overview list - the exact
  // stage-by-stage detail belongs to [LiveOrderPage].
  static const _deliveringDeliveryStatuses = [
    'assigned',
    'arrived_to_store',
    'picked_up',
    'on_the_way',
    'arrived',
  ];

  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  CachedAd? _ad;

  bool get _isArabic => widget.language == 'ar';

  // Fields, not getters: StreamBuilder resets to ConnectionState.waiting
  // when it sees a "new" Stream instance, which a getter would recreate on
  // every setState in the whole page (e.g. just the ad loading in).
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _waitingCartsStream =
      _firestore
          .collection('users')
          .doc(_uid)
          .collection('carts')
          .where('waiting_payment', isEqualTo: true)
          .snapshots();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _activeOrdersStream =
      _firestore
          .collection('orders')
          .where('user_id', isEqualTo: _uid)
          .where('order_status', whereIn: _activeStatuses)
          .orderBy('created_at', descending: true)
          .snapshots();

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  @override
  void dispose() {
    AdService.instance.flush();
    super.dispose();
  }

  Future<void> _loadAd() async {
    try {
      final userDoc = await _firestore.collection('users').doc(_uid).get();
      final city =
          (userDoc.data()?['address'] as Map<String, dynamic>?)?['city']
              as String?;
      if (city == null || city.isEmpty) return;
      await AdService.instance.refresh(city);
      final ad = AdService.instance.nextAdFor('orders_list');
      if (ad != null) AdService.instance.recordView(ad, 'orders_list');
      AdService.instance.startAutoFlush();
      if (mounted) setState(() => _ad = ad);
    } catch (_) {
      // Ad slot just stays empty - not worth failing the page over.
    }
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, 'orders_list');
    if (ad.actionType == 'url' && ad.actionValue.isNotEmpty) {
      openExternalUrl(ad.actionValue);
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
            Expanded(
              child: SafeArea(
                top: false,
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _waitingCartsStream,
                  builder: (context, cartsSnap) {
                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _activeOrdersStream,
                      builder: (context, ordersSnap) =>
                          _buildBody(cartsSnap, ordersSnap),
                    );
                  },
                ),
              ),
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
      child: Text(
        TranslationHelper.get('nav_current_orders'),
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildBody(
    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> cartsSnap,
    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> ordersSnap,
  ) {
    if (cartsSnap.connectionState == ConnectionState.waiting ||
        ordersSnap.connectionState == ConnectionState.waiting) {
      return _buildLoadingSkeleton();
    }

    final error = cartsSnap.error ?? ordersSnap.error;
    if (error != null) {
      return Center(
        child: Text(
          TranslationHelper.get(
              isConnectivityError(error) ? 'no_internet' : 'error'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }

    final waitingCarts = cartsSnap.data?.docs ?? [];
    final activeOrders = ordersSnap.data?.docs ?? [];

    if (waitingCarts.isEmpty && activeOrders.isEmpty) return _buildEmptyState();

    final items = <Widget>[];
    if (waitingCarts.isNotEmpty) {
      items.add(_buildSectionLabel('waiting_payment_title', const Color(0xFFE74C3C)));
      items.add(const SizedBox(height: 10));
      for (final cart in waitingCarts) {
        items.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildWaitingCartCard(cart),
        ));
      }
      if (_ad != null) {
        items.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SponsoredAdCard(
            ad: _ad!,
            language: widget.language,
            onTap: () => _handleAdTap(_ad!),
          ),
        ));
      }
      items.add(const SizedBox(height: 8));
    }

    if (activeOrders.isNotEmpty) {
      items.add(_buildSectionLabel('nav_current_orders', const Color(0xFF1B8A3E)));
      items.add(const SizedBox(height: 10));
      for (final order in activeOrders) {
        items.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildActiveOrderCard(order),
        ));
      }
      if (waitingCarts.isEmpty && _ad != null) {
        items.add(SponsoredAdCard(
          ad: _ad!,
          language: widget.language,
          onTap: () => _handleAdTap(_ad!),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: items,
    );
  }

  Widget _buildSectionLabel(String key, Color dotColor) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          TranslationHelper.get(key),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF2E3A59),
          ),
        ),
      ],
    );
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
    Widget row() => Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(width: 140, height: 14),
                    const SizedBox(height: 8),
                    bar(width: 80),
                  ],
                ),
              ),
            ],
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        bar(width: 100, height: 13),
        const SizedBox(height: 10),
        row(),
        const SizedBox(height: 16),
        bar(width: 100, height: 13),
        const SizedBox(height: 10),
        row(),
        const SizedBox(height: 10),
        row(),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 130,
              height: 130,
              decoration: const BoxDecoration(
                color: Color(0xFFFFEFD9),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.receipt_long_outlined,
                size: 56,
                color: Color(0xFFFF9800),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              TranslationHelper.get('no_active_orders'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              TranslationHelper.get('no_active_orders_subtitle'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaitingCartCard(QueryDocumentSnapshot<Map<String, dynamic>> cart) {
    final data = cart.data();
    final storeNameAr = data['store_name_ar'] as String? ?? '';
    final storeNameFr = data['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final storeImage = data['store_image'] as String? ?? '';
    final lines = StoreCartService.linesFrom(data);
    final itemCount = lines.fold<int>(0, (acc, l) => acc + l.quantity);
    final total = lines.fold<double>(0, (acc, l) => acc + l.lineTotal);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CartPage(widget.language, _uid, cart.id),
        ),
      ),
      child: _buildOrderLikeCard(
        storeName: storeName,
        storeImage: storeImage,
        itemCount: itemCount,
        total: total,
        pillLabel: TranslationHelper.get('payment_required_label'),
        pillColor: const Color(0xFFE74C3C),
        pillBg: const Color(0xFFFDF1F0),
      ),
    );
  }

  Widget _buildActiveOrderCard(QueryDocumentSnapshot<Map<String, dynamic>> order) {
    final data = order.data();
    final storeNameAr = data['store_name_ar'] as String? ?? '';
    final storeNameFr = data['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final storeImage = data['store_image'] as String? ?? '';
    final linesMap = (data['lines'] as Map?) ?? {};
    final itemCount = linesMap.values.fold<int>(
        0, (acc, l) => acc + (((l as Map)['quantity'] as num?)?.toInt() ?? 0));
    final total = (data['total'] as num?)?.toDouble() ?? 0;

    final orderStatus = data['order_status'] as String? ?? 'placed';
    final deliveryStatus = data['delivery_status'] as String? ?? 'pending';
    final isDelivering = orderStatus == 'ready' ||
        _deliveringDeliveryStatuses.contains(deliveryStatus);
    final progress = isDelivering ? 0.75 : 0.3;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LiveOrderPage(widget.language, order.id),
        ),
      ),
      child: _buildOrderLikeCard(
        storeName: storeName,
        storeImage: storeImage,
        itemCount: itemCount,
        total: total,
        pillLabel: TranslationHelper.get(isDelivering
            ? 'order_status_delivering_label'
            : 'order_status_preparing_label'),
        pillColor: isDelivering ? const Color(0xFF1B8A3E) : const Color(0xFFB8860B),
        pillBg: isDelivering ? const Color(0xFFE6F7EA) : const Color(0xFFFFF3E0),
        progress: progress,
        progressColor: isDelivering ? const Color(0xFF1B8A3E) : const Color(0xFFFF9800),
      ),
    );
  }

  Widget _buildOrderLikeCard({
    required String storeName,
    required String storeImage,
    required int itemCount,
    required double total,
    required String pillLabel,
    required Color pillColor,
    required Color pillBg,
    double? progress,
    Color? progressColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
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
        children: [
          Row(
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
              const SizedBox(width: 14),
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
                        color: Color(0xFF2E3A59),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${TranslationHelper.get(itemCount == 1 ? 'cart_item_count_one' : 'cart_item_count_other', {
                            'count': itemCount
                          })} · ${total.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration:
                    BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  pillLabel,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800, color: pillColor),
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: const Color(0xFFEDEFF2),
                valueColor: AlwaysStoppedAnimation<Color>(progressColor!),
              ),
            ),
          ],
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
}
