import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/cart_page.dart';
import 'package:flutter_application_1/pages/client/order_history_detail_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/order_reorder_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';

/// Past (finished) orders, grouped by month, from the top-level `orders`
/// collection (`lib/map.txt`) filtered to `order_end: true` - orders still
/// in progress live on [OrdersListPage] instead. `order_status` itself
/// only ever reaches "placed" | "accepted" | "preparing" | "ready" |
/// "cancelled" - a delivered order stays at "ready" and is told apart from
/// one still in progress purely by `order_end`, not by its own status
/// value.
class OrderHistoryListPage extends StatefulWidget {
  final String language;
  const OrderHistoryListPage(this.language, {super.key});

  @override
  State<OrderHistoryListPage> createState() => _OrderHistoryListPageState();
}

class _OrderHistoryListPageState extends State<OrderHistoryListPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  CachedAd? _ad;

  // Reordering isn't atomic (read the cart, maybe clear it, then add each
  // line) - two reorders racing on the *same store's* cart at once (e.g.
  // tapping "Recommander" on two different orders from the same store
  // before the first finishes) can interleave and clobber each other's
  // lines. Tracked separately from [_reorderingOrderIds] (which just
  // drives each button's own disabled/spinner state) since two orders can
  // point at the same store.
  final Set<String> _reorderingOrderIds = {};
  final Set<String> _reorderingStoreIds = {};

  // Cached per store so every order card for the same store doesn't each
  // re-fetch it. Caches the Future itself, not just its resolved value -
  // an async method returns a *new* Future object on every call even on a
  // resolved-value cache hit, which would still reset the FutureBuilder at
  // every call site on each rebuild (e.g. from pagination's setState).
  final Map<String, Future<bool>> _canReorderFutures = {};

  Future<bool> _canReorder(String storeId) {
    return _canReorderFutures.putIfAbsent(
        storeId, () => OrderReorderService.canReorder(_uid, storeId));
  }

  bool get _isArabic => widget.language == 'ar';

  static const _pageSize = 15;

  Query<Map<String, dynamic>> get _baseQuery => _firestore
      .collection('orders')
      .where('user_id', isEqualTo: _uid)
      .where('order_end', isEqualTo: true)
      .orderBy('created_at', descending: true);

  final _scrollController = ScrollController();
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _orders = [];
  DocumentSnapshot<Map<String, dynamic>>? _lastOrderDoc;
  bool _isLoadingInitial = true;
  bool _isLoadingMore = false;
  bool _hasMoreOrders = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _loadAd();
    _loadInitialOrders();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    disposeAlert();
    // No AdService.flush() here - HomeShell owns the background flush
    // timer for the whole session (see home_shell.dart).
    super.dispose();
  }

  void _onScroll() {
    if (_isLoadingMore || !_hasMoreOrders) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMoreOrders();
    }
  }

  Future<void> _loadInitialOrders() async {
    try {
      final snap = await _baseQuery.limit(_pageSize).get();
      if (!mounted) return;
      setState(() {
        _orders.addAll(snap.docs);
        _lastOrderDoc = snap.docs.isEmpty ? null : snap.docs.last;
        _hasMoreOrders = snap.docs.length == _pageSize;
        _isLoadingInitial = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoadingInitial = false;
      });
    }
  }

  Future<void> _loadMoreOrders() async {
    if (_lastOrderDoc == null || !_hasMoreOrders || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final snap = await _baseQuery
          .startAfterDocument(_lastOrderDoc!)
          .limit(_pageSize)
          .get();
      if (!mounted) return;
      setState(() {
        _orders.addAll(snap.docs);
        if (snap.docs.isNotEmpty) _lastOrderDoc = snap.docs.last;
        _hasMoreOrders = snap.docs.length == _pageSize;
        _isLoadingMore = false;
      });
    } catch (_) {
      // Leaves _hasMoreOrders as-is - scrolling near the bottom again
      // retries instead of surfacing a page-breaking error for what's
      // just the "load more" tail end of the list.
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  // No refresh()/startAutoFlush() here - HomeShell already keeps the
  // shared ad cache refreshed and the flush timer running for the whole
  // session (see home_shell.dart); this just reads whatever's cached.
  void _loadAd() {
    final ad = AdService.instance.nextAdFor('histories_list');
    if (ad != null) AdService.instance.recordView(ad, 'histories_list');
    if (mounted) setState(() => _ad = ad);
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, 'histories_list');
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
        body: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              if (alertCard != null) alertCard!,
              Expanded(child: _buildBody()),
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
          Expanded(
            child: Text(
              TranslationHelper.get('nav_order_history'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
          const SizedBox(width: 38),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoadingInitial) {
      return _buildLoadingSkeleton();
    }

    if (_loadError != null) {
      return Center(
        child: Text(
          TranslationHelper.get(
              isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }

    if (_orders.isEmpty) return _buildEmptyState();

    // Orders already arrive newest-first (each page is appended in order),
    // so consecutive same-month runs can be grouped in a single pass
    // without re-sorting.
    final items = <Widget>[];
    String? lastMonthKey;
    for (var i = 0; i < _orders.length; i++) {
      final order = _orders[i];
      final createdAt = (order.data()['created_at'] as Timestamp?)?.toDate();
      final monthKey =
          createdAt == null ? '' : '${createdAt.year}-${createdAt.month}';
      if (monthKey != lastMonthKey) {
        if (items.isNotEmpty) items.add(const SizedBox(height: 8));
        items.add(_buildMonthHeader(createdAt));
        lastMonthKey = monthKey;
      }
      items.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _buildOrderCard(order),
      ));
      if (i == 0 && _ad != null) {
        items.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SponsoredAdCard(
            ad: _ad!,
            language: widget.language,
            onTap: () => _handleAdTap(_ad!),
          ),
        ));
      }
    }

    if (_isLoadingMore) {
      items.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF9800)),
          ),
        ),
      ));
    }

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: items,
    );
  }

  /// Grey placeholder cards shaped like [_buildOrderCard], shown instead
  /// of a bare centered spinner while the first snapshot is still
  /// loading - a blank page with a small spinner floating in the middle
  /// reads as a jarring white flash; cards already shaped like the real
  /// content make the wait feel like part of the page instead.
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

    Widget card() => Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 56,
                    height: 56,
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
                        bar(width: 120, height: 14),
                        const SizedBox(height: 8),
                        bar(width: 160),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: bar(height: 34)),
                  const SizedBox(width: 10),
                  Expanded(child: bar(height: 34)),
                ],
              ),
            ],
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        bar(width: 90, height: 12),
        const SizedBox(height: 10),
        card(),
        const SizedBox(height: 12),
        card(),
        const SizedBox(height: 12),
        card(),
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
                Icons.receipt_long_rounded,
                size: 56,
                color: Color(0xFFFF9800),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              TranslationHelper.get('no_order_history'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              TranslationHelper.get('no_order_history_subtitle'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _monthLabel(DateTime? date) {
    if (date == null) return '';
    return TranslationHelper.get('month_${date.month}');
  }

  Widget _buildMonthHeader(DateTime? date) {
    final label =
        date == null ? '' : '${_monthLabel(date).toUpperCase()} ${date.year}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildOrderCard(QueryDocumentSnapshot<Map<String, dynamic>> order) {
    final data = order.data();
    final storeNameAr = data['store_name_ar'] as String? ?? '';
    final storeNameFr = data['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final storeImage = data['store_image'] as String? ?? '';
    final status = data['order_status'] as String? ?? 'ready';
    final total = (data['total'] as num?)?.toDouble() ?? 0;
    final createdAt = (data['created_at'] as Timestamp?)?.toDate();
    final storeId = data['store_id'] as String? ?? '';
    final isReordering = _reorderingOrderIds.contains(order.id);
    // Every order card for the same store is disabled while any one of
    // them is mid-reorder (see [_reorder]'s same-store guard) - only the
    // card that was actually tapped shows the spinner, the rest just go
    // inert instead of letting a race slip through or interrupting with
    // an alert on tap.
    final isBlockedBySameStore =
        !isReordering && _reorderingStoreIds.contains(storeId);

    final linesMap = (data['lines'] as Map?) ?? {};
    final itemCount = linesMap.values.fold<int>(0, (acc, line) {
      final quantity = ((line as Map)['quantity'] as num?)?.toInt() ?? 0;
      return acc + quantity;
    });

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
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                          placeholder: (c, u) =>
                              Container(color: Colors.grey[200]),
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
                        color: Color(0xFF2E3A59),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_orderDateLabel(createdAt)} · '
                      '${TranslationHelper.get(itemCount == 1 ? 'cart_item_count_one' : 'cart_item_count_other', {
                            'count': itemCount
                          })} · '
                      '${total.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF9AA1AC),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<bool>(
            future: _canReorder(storeId),
            builder: (context, snapshot) {
              // Hidden by default until proven reorderable, rather than
              // shown by default until proven otherwise - a moment of
              // "Détails" alone is fine; a tappable "Recommander" for a
              // closed store or one in another city isn't.
              final canReorder = snapshot.data ?? false;
              return _buildActionsRow(
                  order, isReordering, isBlockedBySameStore, canReorder);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildActionsRow(
    QueryDocumentSnapshot<Map<String, dynamic>> order,
    bool isReordering,
    bool isBlockedBySameStore,
    bool canReorder,
  ) {
    final detailsButton = OutlinedButton(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OrderHistoryDetailPage(widget.language, order.id),
        ),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 11),
        side: const BorderSide(color: Color(0xFFE1E4E9)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        TranslationHelper.get('order_details_button'),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Color(0xFF2E3A59),
        ),
      ),
    );

    if (!canReorder) {
      return SizedBox(width: double.infinity, child: detailsButton);
    }

    return Row(
      children: [
        Expanded(child: detailsButton),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton(
            onPressed: (isReordering || isBlockedBySameStore)
                ? null
                : () => _reorder(order),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFEFD9),
              foregroundColor: const Color(0xFFB8631A),
              disabledBackgroundColor: isBlockedBySameStore
                  ? const Color(0xFFF1F2F4)
                  : const Color(0xFFFFEFD9),
              disabledForegroundColor:
                  isBlockedBySameStore ? const Color(0xFFB4B9C2) : null,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: isReordering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFFB8631A)),
                    ),
                  )
                : Text(
                    TranslationHelper.get('reorder_button'),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceholderImage() {
    return Container(
      color: const Color(0xFFFFEFD9),
      child: const Icon(
        Icons.store_rounded,
        color: Color(0xFFFF9800),
        size: 24,
      ),
    );
  }

  String _orderDateLabel(DateTime? date) {
    if (date == null) return '';
    return '${date.day} ${_monthLabel(date).toLowerCase()}';
  }

  Future<void> _reorder(
      QueryDocumentSnapshot<Map<String, dynamic>> order) async {
    final data = order.data();
    final storeId = data['store_id'] as String? ?? '';
    if (storeId.isEmpty) return;

    // Reordering isn't atomic - it reads the cart, maybe clears it, then
    // writes each line back. If a second reorder for the *same store*
    // (from another order, or a double-tap past the button's own disabled
    // state) started while this one is still running, letting both
    // proceed would interleave their reads/writes and could silently drop
    // lines either one added. Only one reorder per store runs at a time;
    // every other order card for that store has its button disabled for
    // the duration (see [_buildOrderCard]), so reaching here at all means
    // a race slipped through - just drop it silently rather than one more
    // alert.
    if (_reorderingOrderIds.contains(order.id) ||
        _reorderingStoreIds.contains(storeId)) {
      return;
    }
    setState(() {
      _reorderingOrderIds.add(order.id);
      _reorderingStoreIds.add(storeId);
    });

    try {
      await _doReorder(storeId, data);
    } finally {
      if (mounted) {
        setState(() {
          _reorderingOrderIds.remove(order.id);
          _reorderingStoreIds.remove(storeId);
        });
      } else {
        _reorderingOrderIds.remove(order.id);
        _reorderingStoreIds.remove(storeId);
      }
    }
  }

  Future<void> _doReorder(String storeId, Map<String, dynamic> data) async {
    _canReorderFutures.remove(storeId);
    final result =
        await OrderReorderService.reorder(uid: _uid, orderData: data);
    switch (result.outcome) {
      case ReorderOutcome.storeClosed:
        showAlert(TranslationHelper.get('reorder_store_inactive'),
            isError: true);
        break;
      case ReorderOutcome.differentCity:
        showAlert(TranslationHelper.get('reorder_different_city'),
            isError: true);
        break;
      case ReorderOutcome.waitingPayment:
        showAlert(TranslationHelper.get('reorder_waiting_payment'),
            isError: true);
        break;
      case ReorderOutcome.allUnavailable:
        showAlert(TranslationHelper.get('reorder_all_unavailable'),
            isError: true);
        break;
      case ReorderOutcome.partial:
        _openCartPage(
          storeId,
          message: TranslationHelper.get(
              'reorder_partial', {'skipped': result.skippedCount}),
          isError: true,
        );
        break;
      case ReorderOutcome.success:
        _openCartPage(storeId);
        break;
    }
  }

  void _openCartPage(String storeId, {String? message, bool isError = false}) {
    if (!mounted) return;
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
