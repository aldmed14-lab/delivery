import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/cart_page.dart';
import 'package:flutter_application_1/pages/client/store_details/item_detail_sheet.dart';
import 'package:flutter_application_1/pages/client/store_details/store_info_sheet.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';

/// One item's cart state for this store: [firstLine] is the line "-"
/// reduces (there's no way to know which configuration the user means to
/// touch, so it's always the first one found); [totalQuantity] is the sum
/// across every line for this item, shown as the stepper's number.
class _ItemCartSummary {
  final CartLine firstLine;
  final int totalQuantity;

  _ItemCartSummary({required this.firstLine, required this.totalQuantity});
}

class StoreDetails extends StatefulWidget {
  final String storeId;
  final String uid;
  final String namear;
  final String namefr;
  final String imageUrl;
  final String language;

  const StoreDetails(this.language, this.storeId, this.uid, this.namear,
      this.namefr, this.imageUrl,
      {super.key});

  @override
  State<StoreDetails> createState() => _StoreDetailsState();
}

class _StoreDetailsState extends State<StoreDetails> {
  static const _headerImageHeight = 190.0;
  static const _infoCardOverlap = 24.0;

  final _firestore = FirebaseFirestore.instance;
  final _scrollController = ScrollController();

  bool _isLoading = true;
  bool _hasError = false;
  Map<String, dynamic>? _store;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _categories = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _items = [];
  double? _distanceKm;
  CachedAd? _ad;
  String _adPosition = 'store_daitails';

  String? _activeTabId;
  final Map<String, GlobalKey> _sectionKeys = {};

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _load();
    _scrollController.addListener(_updateActiveTabFromScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateActiveTabFromScroll);
    _scrollController.dispose();
    AdService.instance.flush();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final storeSnap =
          await _firestore.collection('stores').doc(widget.storeId).get();
      if (!storeSnap.exists) {
        if (mounted) setState(() => _hasError = true);
        return;
      }
      final store = storeSnap.data()!;

      final results = await Future.wait([
        _firestore
            .collection('stores')
            .doc(widget.storeId)
            .collection('categories')
            .orderBy('index')
            .get(),
        _firestore
            .collection('stores')
            .doc(widget.storeId)
            .collection('items')
            .where('exist', isEqualTo: true)
            .get(),
      ]);
      final categories = results[0].docs;
      final items = results[1].docs;

      if (!mounted) return;
      setState(() {
        _store = store;
        _categories = categories;
        _items = items;
        _isLoading = false;
      });

      _resolveDistance(store);
      _loadAd(store);
    } catch (_) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  Future<void> _resolveDistance(Map<String, dynamic> store) async {
    try {
      final storeLat = (store['lat'] as num?)?.toDouble();
      final storeLng = (store['lng'] as num?)?.toDouble();
      if (storeLat == null || storeLng == null) return;

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final address = userDoc.data()?['address'] as Map<String, dynamic>?;
      final userLat = (address?['lat'] as num?)?.toDouble();
      final userLng = (address?['lng'] as num?)?.toDouble();
      if (userLat == null || userLng == null) return;

      final meters = _distanceMeters(userLat, userLng, storeLat, storeLng);
      if (mounted) setState(() => _distanceKm = meters / 1000);
    } catch (_) {
      // Distance chip just doesn't show - not worth failing the page over.
    }
  }

  /// Haversine distance in meters - avoids pulling in a location-services
  /// dependency just for this one chip.
  double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _deg2rad(double deg) => deg * (math.pi / 180);

  /// "yyyy-MM-dd-HH" (e.g. "2026-08-17-22") matching how stores' hourly
  /// `trend_time` bucket is stamped, so it can be compared for equality.
  String _currentTrendHourKey() {
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${pad(now.month)}-${pad(now.day)}-${pad(now.hour)}';
  }

  Future<void> _loadAd(Map<String, dynamic> store) async {
    final city = store['city'] as String?;
    if (city == null) return;
    await AdService.instance.refresh(city);

    final trendLevel = (store['trend_level'] as num?)?.toInt() ?? 0;
    final trendTime = store['trend_time'] as String?;
    final isTrending = trendLevel <= 10 && trendTime == _currentTrendHourKey();
    final position = isTrending ? 'store_daitails_top10' : 'store_daitails';

    final ad = AdService.instance.nextAdFor(position);
    if (ad != null) AdService.instance.recordView(ad, position);
    AdService.instance.startAutoFlush();
    if (mounted) {
      setState(() {
        _ad = ad;
        _adPosition = position;
      });
    }
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, _adPosition);
    if (ad.actionType == 'url' && ad.actionValue.isNotEmpty) {
      openExternalUrl(ad.actionValue);
    }
    // action_type "store" isn't wired here - tapping a store ad while
    // already inside a store's page has nowhere further useful to go.
  }

  /// Top-5 items store-wide with sell_count > 0, ranked by sell_count desc.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _populaireItems {
    final withSales = _items.where((doc) {
      final sellCount = (doc.data()['sell_count'] as num?) ?? 0;
      return sellCount > 0;
    }).toList()
      ..sort((a, b) => ((b.data()['sell_count'] as num?) ?? 0)
          .compareTo((a.data()['sell_count'] as num?) ?? 0));
    return withSales.take(5).toList();
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _itemsForCategory(
      String categoryId) {
    return _items.where((doc) => doc.data()['category'] == categoryId).toList();
  }

  void _updateActiveTabFromScroll() {
    const activationLine = 150.0;
    String? closest;
    double bestDy = double.negativeInfinity;
    for (final entry in _sectionKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= activationLine && dy > bestDy) {
        bestDy = dy;
        closest = entry.key;
      }
    }
    if (closest != null && closest != _activeTabId) {
      setState(() => _activeTabId = closest);
    }
  }

  void _onTabTap(String tabId) {
    final ctx = _sectionKeys[tabId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0,
      );
    }
    setState(() => _activeTabId = tabId);
  }

  void _openItemSheet(QueryDocumentSnapshot<Map<String, dynamic>> item) {
    if (_store == null) return;
    showItemDetailSheet(
      context: context,
      language: widget.language,
      uid: widget.uid,
      storeId: widget.storeId,
      storeNameAr: _store!['name_ar'] ?? widget.namear,
      storeNameFr: _store!['name_fr'] ?? widget.namefr,
      storeImage: _store!['image'] ?? widget.imageUrl,
      itemId: item.id,
      itemData: item.data(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F9),
        body: _isLoading
            ? _buildLoadingSkeleton()
            : _hasError || _store == null
                ? _buildErrorState()
                : Stack(
                    children: [
                      _buildScrollContent(),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _buildCartBar(),
                      ),
                    ],
                  ),
      ),
    );
  }

  /// Grey placeholder shaped like the real page (header image, overlapping
  /// info card, a couple of item rows) instead of a bare centered spinner -
  /// a blank page with a small spinner floating in the middle reads as a
  /// jarring white flash; a shape already like the real content makes the
  /// wait feel like part of the page instead.
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

    Widget itemRow() => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(width: 140, height: 14),
                    const SizedBox(height: 8),
                    bar(width: 70),
                  ],
                ),
              ),
            ],
          ),
        );

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(height: _headerImageHeight, color: const Color(0xFFEDEFF2)),
            Positioned(
              top: _headerImageHeight - _infoCardOverlap,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(width: 160, height: 16),
                    const SizedBox(height: 10),
                    bar(width: 100),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: bar(height: 34)),
                        const SizedBox(width: 10),
                        Expanded(child: bar(height: 34)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              16, _infoCardOverlap + 20, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(width: 90, height: 16),
              const SizedBox(height: 12),
              itemRow(),
              itemRow(),
              itemRow(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.store_mall_directory_outlined,
                size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              TranslationHelper.get('store_not_found'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(TranslationHelper.get('go_back')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrollContent() {
    final populaire = _populaireItems;
    final hasPopulaire = populaire.isNotEmpty;

    // Drives the per-row quantity stepper (item already in cart) vs. plain
    // "+" button (not yet in cart) - keyed by itemId. An item can have
    // several distinct cart lines (different group selections), so the
    // number shown is the *sum* across all of them, while "-" still only
    // ever touches one concrete line (the first one found) since it can't
    // know which configuration the user means to reduce.
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: StoreCartService.watch(widget.uid, widget.storeId),
      builder: (context, snapshot) {
        final cartData = snapshot.data?.data();
        final waitingPayment = cartData?['waiting_payment'] == true;
        final storeStatus = _store!['status'] as String? ?? 'close';
        final storeClosed = storeStatus == 'close';
        final storeBusy = storeStatus == 'trafic';
        final cartLocked = waitingPayment || storeClosed || storeBusy;

        final linesByItem = <String, List<CartLine>>{};
        for (final line in StoreCartService.linesFrom(cartData)) {
          linesByItem.putIfAbsent(line.itemId, () => []).add(line);
        }
        final cartByItem = <String, _ItemCartSummary>{
          for (final entry in linesByItem.entries)
            entry.key: _ItemCartSummary(
              firstLine: entry.value.first,
              totalQuantity:
                  entry.value.fold<int>(0, (acc, l) => acc + l.quantity),
            ),
        };

        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              // Header image and the overlapping info card are one sliver,
              // combined via a Stack rather than a Column with a negative
              // margin on the card (Container asserts margin.isNonNegative
              // - a negative margin crashes at runtime, it just never
              // surfaced in `flutter analyze`, which doesn't execute the
              // widget tree). The image is Positioned (so it doesn't drive
              // the Stack's size); the Column - image height minus the
              // overlap, then the card - does, and paints after the image
              // so the card covers it wherever they overlap.
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _buildHeaderImage(),
                  ),
                  Column(
                    children: [
                      const SizedBox(height: _headerImageHeight - _infoCardOverlap),
                      _buildInfoCard(),
                    ],
                  ),
                ],
              ),
            ),
            if (waitingPayment)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _buildWaitingPaymentBanner(),
                ),
              )
            else if (storeClosed)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _buildStoreClosedBanner(),
                ),
              )
            else if (storeBusy)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _buildStoreBusyBanner(),
                ),
              ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarDelegate(
                isArabic: _isArabic,
                hasPopulaire: hasPopulaire,
                categories: _categories,
                language: widget.language,
                activeTabId: _activeTabId ??
                    (hasPopulaire
                        ? 'populaire'
                        : (_categories.isEmpty ? null : _categories.first.id)),
                onTap: _onTabTap,
              ),
            ),
            if (hasPopulaire)
              SliverToBoxAdapter(
                child: _buildSection('populaire',
                    _buildPopulaireSection(populaire, cartByItem, cartLocked)),
              ),
            if (_ad != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: SponsoredAdCard(
                    ad: _ad!,
                    language: widget.language,
                    onTap: () => _handleAdTap(_ad!),
                  ),
                ),
              ),
            for (final category in _categories)
              SliverToBoxAdapter(
                child: _buildSection(
                  category.id,
                  _buildCategorySection(category, cartByItem, cartLocked),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        );
      },
    );
  }

  Future<void> _adjustCartLine(CartLine line, int delta) async {
    final newQty = line.quantity + delta;
    if (newQty <= 0) {
      await StoreCartService.removeLine(
          widget.uid, widget.storeId, line.lineKey);
    } else {
      await StoreCartService.setLineQuantity(
          widget.uid, widget.storeId, line.lineKey, newQty);
    }
  }

  Widget _buildSection(String tabId, Widget child) {
    final key = _sectionKeys.putIfAbsent(tabId, () => GlobalKey());
    return KeyedSubtree(key: key, child: child);
  }

  Widget _buildHeaderImage() {
    final image = _store!['image'] as String? ?? widget.imageUrl;
    return Stack(
      children: [
        SizedBox(
          height: _headerImageHeight,
          width: double.infinity,
          child: image.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: image,
                  fit: BoxFit.cover,
                  placeholder: (c, u) => Container(color: Colors.grey[300]),
                  errorWidget: (c, u, e) => Container(color: Colors.grey[300]),
                )
              : Container(color: Colors.grey[300]),
        ),
        Positioned(
          top: 44,
          left: _isArabic ? null : 16,
          right: _isArabic ? 16 : null,
          child: _circleButton(
            icon: _isArabic ? Icons.arrow_forward : Icons.arrow_back,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          top: 44,
          left: _isArabic ? 16 : null,
          right: _isArabic ? null : 16,
          child: _circleButton(
            icon: Icons.info_outline,
            onTap: () => showStoreInfoSheet(
              context: context,
              language: widget.language,
              storeId: widget.storeId,
              phone: _store!['phone'] as String? ?? '',
              rate: (_store!['rate'] as num?)?.toDouble() ?? 0,
              rateNumbers: (_store!['rate_numbers'] as num?)?.toInt() ?? 0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }

  Widget _buildInfoCard() {
    final name = _store!['name_${widget.language}'] as String? ??
        _store!['name_fr'] as String? ??
        widget.namefr;
    final status = _store!['status'] as String? ?? 'close';
    final rate = (_store!['rate'] as num?)?.toDouble() ?? 0;
    final rateNumbers = (_store!['rate_numbers'] as num?)?.toInt() ?? 0;
    final deliveryMinutes = _store!['estimated_delivery_time'];

    late final Color statusColor;
    late final Color statusBg;
    late final String statusText;
    switch (status) {
      case 'open':
        statusColor = const Color(0xFF1B8A3E);
        statusBg = const Color(0xFFE6F7EA);
        statusText = TranslationHelper.get('store_open');
        break;
      case 'trafic':
        statusColor = const Color(0xFFB8860B);
        statusBg = const Color(0xFFFFF3E0);
        statusText = TranslationHelper.get('store_busy');
        break;
      default:
        statusColor = const Color(0xFFE74C3C);
        statusBg = const Color(0xFFFDF1F0);
        statusText = TranslationHelper.get('store_closed');
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
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
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (rateNumbers > 100)
            Row(
              children: [
                RatingBarIndicator(
                  rating: rate / rateNumbers,
                  itemBuilder: (context, _) =>
                      const Icon(Icons.star, color: Colors.amber),
                  itemCount: 5,
                  itemSize: 15,
                  unratedColor: const Color(0xFFE3E5E9),
                ),
                const SizedBox(width: 6),
                Text(
                  (rate / rateNumbers).toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '(${ratingCountLabel(rateNumbers)})',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                ),
              ],
            )
          else
            Text(
              TranslationHelper.get('no_ratings_yet'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
            ),
          if (deliveryMinutes != null || _distanceKm != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (deliveryMinutes != null)
                  Expanded(
                    child: _buildStatChip(
                      value: '$deliveryMinutes ${TranslationHelper.get('min')}',
                      label: TranslationHelper.get('delivery_time_label'),
                    ),
                  ),
                if (deliveryMinutes != null && _distanceKm != null)
                  const SizedBox(width: 10),
                if (_distanceKm != null)
                  Expanded(
                    child: _buildStatChip(
                      value: TranslationHelper.get(
                          'km_away', {'km': _distanceKm!.toStringAsFixed(1)}),
                      label: TranslationHelper.get('distance_label'),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String ratingCountLabel(int count) =>
      '$count ${TranslationHelper.get('reviews_count_label')}';

  Widget _buildStatChip({required String value, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xFF9AA1AC),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingPaymentBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD9A8)),
      ),
      child: Row(
        children: [
          const Icon(Icons.hourglass_top, color: Color(0xFFFF9800), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TranslationHelper.get('waiting_payment_title'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  TranslationHelper.get('waiting_payment_message'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9AA1AC),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreClosedBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF1F0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF5C6C0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.storefront_outlined,
              color: Color(0xFFE74C3C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TranslationHelper.get('store_closed'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  TranslationHelper.get('store_closed_message'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9AA1AC),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreBusyBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD9A8)),
      ),
      child: Row(
        children: [
          const Icon(Icons.access_time_filled_rounded,
              color: Color(0xFFB8860B), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TranslationHelper.get('store_busy'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  TranslationHelper.get('store_busy_message'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9AA1AC),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPopulaireSection(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> items,
      Map<String, _ItemCartSummary> cartByItem,
      bool cartLocked) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            TranslationHelper.get('populaire'),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          const SizedBox(height: 10),
          for (final item in items)
            _buildItemRow(item,
                cartSummary: cartByItem[item.id], cartLocked: cartLocked),
        ],
      ),
    );
  }

  Widget _buildCategorySection(
      QueryDocumentSnapshot<Map<String, dynamic>> category,
      Map<String, _ItemCartSummary> cartByItem,
      bool cartLocked) {
    final data = category.data();
    final title = data['name_${widget.language}'] ?? data['name_fr'] ?? '';
    final showType = data['show_type'] as String? ?? 'column';
    final items = _itemsForCategory(category.id);
    if (items.isEmpty) return const SizedBox.shrink();

    QueryDocumentSnapshot<Map<String, dynamic>>? featured;
    for (final item in items) {
      final sellCount = (item.data()['sell_count'] as num?) ?? 0;
      final featuredCount = (featured?.data()['sell_count'] as num?) ?? -1;
      if (sellCount > featuredCount) featured = item;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          const SizedBox(height: 10),
          if (showType == 'row')
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) => SizedBox(
                  width: 140,
                  child: _buildItemCard(items[i],
                      cartSummary: cartByItem[items[i].id],
                      cartLocked: cartLocked),
                ),
              ),
            )
          else
            for (final item in items)
              _buildItemRow(item,
                  featured: item.id == featured?.id,
                  cartSummary: cartByItem[item.id],
                  cartLocked: cartLocked),
        ],
      ),
    );
  }

  Widget _buildItemRow(QueryDocumentSnapshot<Map<String, dynamic>> item,
      {bool featured = false,
      _ItemCartSummary? cartSummary,
      bool cartLocked = false}) {
    final data = item.data();
    final name = data['name_${widget.language}'] as String? ??
        data['name_fr'] as String? ??
        '';
    final image = data['image'] as String? ?? '';
    final price = (data['price'] as num?) ?? 0;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: cartLocked ? null : () => _openItemSheet(item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: featured
              ? Border.all(color: const Color(0xFFFF9800), width: 1.4)
              : null,
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
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 72,
                height: 72,
                child: image.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: image,
                        fit: BoxFit.cover,
                        placeholder: (c, u) =>
                            Container(color: Colors.grey[200]),
                        errorWidget: (c, u, e) =>
                            Container(color: Colors.grey[200]),
                      )
                    : Container(color: Colors.grey[200]),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${price.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFF9800),
                    ),
                  ),
                ],
              ),
            ),
            if (cartLocked)
              const Icon(Icons.lock_outline, color: Color(0xFFC9CDD4), size: 20)
            else
              cartSummary != null
                  ? _buildQuantityStepper(
                      cartSummary.firstLine,
                      cartSummary.totalQuantity,
                      () => _openItemSheet(item),
                    )
                  : _addButton(() => _openItemSheet(item)),
          ],
        ),
      ),
    );
  }

  /// "-" reduces/removes [line] directly (the only place that does) - "+"
  /// opens the item sheet to compose a fresh addition instead of blindly
  /// bumping this line's quantity, since a new addition may need its own
  /// group selections. Buttons get their own generously-sized tap targets
  /// (not just the icon's bounds) so they don't misfire into each other.
  Widget _buildQuantityStepper(
      CartLine line, int displayQuantity, VoidCallback onIncrement,
      {bool small = false}) {
    final boxSize = small ? 30.0 : 36.0;
    final radius = small ? 8.0 : 10.0;
    final iconSize = small ? 13.0 : 15.0;
    return Container(
      height: boxSize,
      decoration: BoxDecoration(
        color: const Color(0xFFFF9800),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius:
                BorderRadius.horizontal(left: Radius.circular(radius)),
            onTap: () => _adjustCartLine(line, -1),
            child: SizedBox(
              width: boxSize,
              height: boxSize,
              child: Icon(Icons.remove, color: Colors.white, size: iconSize),
            ),
          ),
          SizedBox(
            width: small ? 18 : 22,
            child: Text(
              '$displayQuantity',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: small ? 12 : 13,
              ),
            ),
          ),
          InkWell(
            borderRadius:
                BorderRadius.horizontal(right: Radius.circular(radius)),
            onTap: onIncrement,
            child: SizedBox(
              width: boxSize,
              height: boxSize,
              child: Icon(Icons.add, color: Colors.white, size: iconSize),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(QueryDocumentSnapshot<Map<String, dynamic>> item,
      {_ItemCartSummary? cartSummary, bool cartLocked = false}) {
    final data = item.data();
    final name = data['name_${widget.language}'] as String? ??
        data['name_fr'] as String? ??
        '';
    final image = data['image'] as String? ?? '';
    final price = (data['price'] as num?) ?? 0;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: cartLocked ? null : () => _openItemSheet(item),
      child: Container(
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
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: image.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: image,
                        fit: BoxFit.cover,
                        placeholder: (c, u) =>
                            Container(color: Colors.grey[200]),
                        errorWidget: (c, u, e) =>
                            Container(color: Colors.grey[200]),
                      )
                    : Container(color: Colors.grey[200]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (!cartLocked && cartSummary != null) ...[
                    // The stepper is wider than the plain "+" button - on
                    // its own full-width row below the price instead of
                    // squeezed beside it, so it can't push the price text
                    // outside the (narrow, 140px) card.
                    Text(
                      '${price.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF9800),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _buildQuantityStepper(
                      cartSummary.firstLine,
                      cartSummary.totalQuantity,
                      () => _openItemSheet(item),
                      small: true,
                    ),
                  ] else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${price.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFF9800),
                          ),
                        ),
                        if (cartLocked)
                          const Icon(Icons.lock_outline,
                              color: Color(0xFFC9CDD4), size: 16)
                        else
                          _addButton(() => _openItemSheet(item), small: true),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addButton(VoidCallback onTap, {bool small = false}) {
    final size = small ? 26.0 : 34.0;
    final radius = small ? 8.0 : 10.0;
    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFFF9800),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(Icons.add, color: Colors.white, size: small ? 15 : 18),
      ),
    );
  }

  Widget _buildCartBar() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: StoreCartService.watch(widget.uid, widget.storeId),
      builder: (context, snapshot) {
        final lines = StoreCartService.linesFrom(snapshot.data?.data());
        final itemCount = lines.fold<int>(0, (acc, l) => acc + l.quantity);
        final total = lines.fold<double>(0, (acc, l) => acc + l.lineTotal);
        if (itemCount == 0) return const SizedBox.shrink();

        final status = _store?['status'] as String? ?? 'close';
        final storeLocked = status == 'close' || status == 'trafic';

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: storeLocked
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CartPage(
                              widget.language, widget.uid, widget.storeId),
                        ),
                      ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: storeLocked
                        ? const [Color(0xFFC9CDD4), Color(0xFFB4B9C2)]
                        : const [Color(0xFFFF9800), Color(0xFFFB6D0A)],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: (storeLocked
                              ? const Color(0xFFB4B9C2)
                              : const Color(0xFFFF9800))
                          .withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '$itemCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        TranslationHelper.get(storeLocked
                            ? (status == 'close'
                                ? 'store_closed'
                                : 'store_busy')
                            : 'view_cart'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Text(
                      '${total.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Sticky category tab bar: a "Populaire" chip first (if that section
/// exists), then one per category, with a right-edge fade hinting more
/// scroll.
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final bool isArabic;
  final bool hasPopulaire;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> categories;
  final String language;
  final String? activeTabId;
  final ValueChanged<String> onTap;

  _TabBarDelegate({
    required this.isArabic,
    required this.hasPopulaire,
    required this.categories,
    required this.language,
    required this.activeTabId,
    required this.onTap,
  });

  @override
  double get minExtent => 56;
  @override
  double get maxExtent => 56;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: const Color(0xFFF6F7F9),
      child: Stack(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              if (hasPopulaire)
                _chip('populaire', TranslationHelper.get('populaire')),
              for (final c in categories)
                _chip(c.id,
                    c.data()['name_$language'] ?? c.data()['name_fr'] ?? ''),
            ],
          ),
          Positioned(
            right: isArabic ? null : 0,
            left: isArabic ? 0 : null,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                width: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin:
                        isArabic ? Alignment.centerRight : Alignment.centerLeft,
                    end:
                        isArabic ? Alignment.centerLeft : Alignment.centerRight,
                    colors: [
                      const Color(0xFFF6F7F9).withValues(alpha: 0),
                      const Color(0xFFF6F7F9),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String id, String label) {
    final selected = id == activeTabId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => onTap(id),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFF9800) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: selected
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 6,
                    ),
                  ],
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : const Color(0xFF677489),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return oldDelegate.activeTabId != activeTabId ||
        oldDelegate.categories.length != categories.length;
  }
}
