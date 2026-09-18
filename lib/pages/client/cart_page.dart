import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/push_order_page.dart';
import 'package:flutter_application_1/pages/client/store_details_page.dart';
import 'package:flutter_application_1/utils/order_reorder_service.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// One store's cart - `users/{uid}/carts/{storeId}` (`lib/map.txt`) - with
/// its line items, a dashed "Ajouter un article" entry back into the
/// store's page, and a fixed checkout bar. Reached by tapping a card on
/// [CartListPage] or the "Voir le panier" bar on [StoreDetails].
class CartPage extends StatefulWidget {
  final String language;
  final String uid;
  final String storeId;

  /// Shown once as an alert card right after this page opens - used by
  /// "Recommander" flows (order history) to report a partial reorder
  /// (some lines skipped) without needing an alert system of their own on
  /// the page they navigated away from.
  final String? initialMessage;
  final bool initialMessageIsError;

  const CartPage(
    this.language,
    this.uid,
    this.storeId, {
    this.initialMessage,
    this.initialMessageIsError = false,
    super.key,
  });

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> with AlertCardMixin {
  bool get _isArabic => widget.language == 'ar';

  // A field, not a getter re-evaluated on every build: StreamBuilder resets
  // to ConnectionState.waiting when it sees a "new" Stream instance, which
  // a getter would recreate on every setState in the whole page.
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _storeStream =
      FirebaseFirestore.instance
          .collection('stores')
          .doc(widget.storeId)
          .snapshots();

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _cartStream =
      StoreCartService.watch(widget.uid, widget.storeId);

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _userStream =
      FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .snapshots();

  @override
  void initState() {
    super.initState();
    final message = widget.initialMessage;
    if (message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showAlert(message, isError: widget.initialMessageIsError);
      });
    }
    _pruneUnavailableLines();
  }

  /// A store owner can delete/deactivate an item - or just change its (or
  /// one of its group options') price - after it's already sitting in
  /// someone's cart. Nothing used to catch either: only reorder
  /// re-validated against live item/group data. Checked once whenever the
  /// cart page opens; `_cartStream` picks up both the removal and the
  /// price rewrite live, so there's nothing else to refresh here.
  Future<void> _pruneUnavailableLines() async {
    final result =
        await StoreCartService.syncWithCatalog(widget.uid, widget.storeId);
    if (!mounted) return;
    if (result.removed > 0) {
      showAlert(
        TranslationHelper.get(
          result.removed == 1
              ? 'cart_items_removed_one'
              : 'cart_items_removed_other',
          {'count': result.removed},
        ),
        isError: true,
      );
    } else if (result.updated > 0) {
      showAlert(
        TranslationHelper.get(
          result.updated == 1
              ? 'cart_prices_updated_one'
              : 'cart_prices_updated_other',
          {'count': result.updated},
        ),
      );
    }
  }

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
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _cartStream,
            builder: (context, snapshot) {
              final data = snapshot.data?.data();
              final lines = StoreCartService.linesFrom(data)
                ..sort((a, b) => a.lineKey.compareTo(b.lineKey));
              final waitingPayment = data?['waiting_payment'] == true;

              return Column(
                children: [
                  _buildAppBar(data, lines, waitingPayment),
                  if (alertCard != null) alertCard!,
                  Expanded(
                    child: lines.isEmpty
                        ? _buildEmptyState()
                        : _buildContent(data, lines, waitingPayment),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(
      Map<String, dynamic>? data, List<CartLine> lines, bool waitingPayment) {
    final storeNameAr = data?['store_name_ar'] as String? ?? '';
    final storeNameFr = data?['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final itemCount = lines.fold<int>(0, (acc, l) => acc + l.quantity);

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
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _isArabic
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: const Color(0xFFFF9800),
              ),
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
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                if (lines.isNotEmpty)
                  Text(
                    TranslationHelper.get(
                        itemCount == 1
                            ? 'cart_item_count_one'
                            : 'cart_item_count_other',
                        {'count': itemCount}),
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                  ),
              ],
            ),
          ),
          if (lines.isNotEmpty && !waitingPayment)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _clearCart(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(
                  TranslationHelper.get('clear_cart_button'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFFF9800),
                  ),
                ),
              ),
            ),
        ],
      ),
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
                Icons.shopping_cart_outlined,
                size: 60,
                color: Color(0xFFFF9800),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              TranslationHelper.get('empty_cart'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              TranslationHelper.get('empty_cart_subtitle'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    Map<String, dynamic>? data,
    List<CartLine> lines,
    bool waitingPayment,
  ) {
    final total = lines.fold<double>(0, (acc, l) => acc + l.lineTotal);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              if (waitingPayment) ...[
                _buildWaitingPaymentBanner(
                  data?['payment_code'] as String?,
                  data?['payment_image'] as String?,
                ),
                const SizedBox(height: 12),
              ],
              for (final line in lines) ...[
                _buildLineRow(line, waitingPayment),
                const SizedBox(height: 10),
              ],
              _buildAddItemButton(data, waitingPayment),
            ],
          ),
        ),
        _buildTotalBar(total),
        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _storeStream,
          builder: (context, storeSnap) {
            final storeData = storeSnap.data?.data();
            final storeStatus = storeData?['status'] as String?;
            final storeCity = storeData?['city'] as String?;
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _userStream,
              builder: (context, userSnap) {
                final userCity = (userSnap.data?.data()?['address']
                    as Map<String, dynamic>?)?['city'] as String?;
                // Both docs must have actually loaded and agree - a cart
                // can outlive the user moving to a different city (or a
                // brief moment before either doc resolves), and delivery
                // isn't possible outside the user's current city, same
                // rule as OrderReorderService.isStoreInUserCity.
                final sameCity =
                    OrderReorderService.citiesMatch(storeCity, userCity);
                final citiesLoaded =
                    storeSnap.data != null && userSnap.data != null;
                return _buildCheckoutBar(waitingPayment, storeStatus,
                    citiesLoaded: citiesLoaded, sameCity: sameCity);
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildWaitingPaymentBanner(String? paymentCode, String? paymentImage) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD9A8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hourglass_top,
                  color: Color(0xFFFF9800), size: 20),
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
                          fontSize: 11, color: Color(0xFF9AA1AC)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Only an async provider (e.g. "test_payment") sets this on the
          // cart - cash/wallet never leave a cart in `waiting_payment` at
          // all, they create the order synchronously.
          if (paymentCode != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  if (paymentImage != null && paymentImage.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: paymentImage,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        placeholder: (c, u) =>
                            Container(color: Colors.grey[200]),
                        errorWidget: (c, u, e) =>
                            Container(color: Colors.grey[200]),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          TranslationHelper.get('payment_code_label'),
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF9AA1AC)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          paymentCode,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFFF9800),
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLineRow(CartLine line, bool waitingPayment) {
    final name = (_isArabic ? line.nameAr : line.nameFr).isNotEmpty
        ? (_isArabic ? line.nameAr : line.nameFr)
        : line.nameFr;
    final subtitle = _lineOptionsSummary(line);

    return Container(
      padding: const EdgeInsets.all(10),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 60,
              height: 60,
              child: line.image.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: line.image,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(color: Colors.grey[200]),
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
                for (final part in subtitle) ...[
                  const SizedBox(height: 2),
                  Text(
                    part,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFF9AA1AC)),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${line.lineTotal.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF9800),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildStepper(line, waitingPayment),
        ],
      ),
    );
  }

  /// Every group with exactly one pick reads as its option name alone
  /// ("Medium", "Sauce maison"), joined on one line with " · "; groups
  /// with several picks (extras) get their own "+ Bacon, + Cheddar" line -
  /// `groups`/`selected` are all the cart line stores (no `min`/`max`), so
  /// "single vs multi" is inferred from how many options ended up picked.
  List<String> _lineOptionsSummary(CartLine line) {
    final singles = <String>[];
    final multiLines = <String>[];
    for (final group in line.groups) {
      final selected = (group['selected'] as List? ?? [])
          .map((s) =>
              (s as Map)['name_${widget.language}'] as String? ??
              (s)['name_fr'] as String? ??
              '')
          .where((n) => n.isNotEmpty)
          .toList();
      if (selected.isEmpty) continue;
      if (selected.length == 1) {
        singles.add(selected.first);
      } else {
        multiLines.add(selected.map((n) => '+ $n').join(', '));
      }
    }
    return [
      if (singles.isNotEmpty) singles.join(' · '),
      ...multiLines,
    ];
  }

  Widget _buildStepper(CartLine line, bool waitingPayment) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color:
            waitingPayment ? const Color(0xFFE1E4E9) : const Color(0xFFFF9800),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius:
                const BorderRadius.horizontal(left: Radius.circular(9)),
            onTap: waitingPayment ? null : () => _adjustQuantity(line, -1),
            child: const SizedBox(
              width: 32,
              height: 32,
              child: Icon(Icons.remove, color: Colors.white, size: 15),
            ),
          ),
          SizedBox(
            width: 22,
            child: Text(
              '${line.quantity}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          InkWell(
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(9)),
            onTap: waitingPayment ? null : () => _adjustQuantity(line, 1),
            child: const SizedBox(
              width: 32,
              height: 32,
              child: Icon(Icons.add, color: Colors.white, size: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddItemButton(Map<String, dynamic>? data, bool waitingPayment) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: waitingPayment ? null : () => _openStorePage(data),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: waitingPayment
                ? const Color(0xFFE1E4E9)
                : const Color(0xFFFF9800),
            width: 1.4,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_rounded,
              size: 18,
              color: waitingPayment
                  ? const Color(0xFFB4B9C2)
                  : const Color(0xFFFF9800),
            ),
            const SizedBox(width: 6),
            Text(
              TranslationHelper.get('add_item_button'),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: waitingPayment
                    ? const Color(0xFFB4B9C2)
                    : const Color(0xFFFF9800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTotalBar(double total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      color: Colors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            TranslationHelper.get('total_label'),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          Text(
            '${total.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFFFF9800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckoutBar(bool waitingPayment, String? storeStatus,
      {required bool citiesLoaded, required bool sameCity}) {
    final isClosed = storeStatus == 'close';
    final isBusy = storeStatus == 'trafic';
    // A real (loaded) mismatch, not just "still loading" - during load
    // citiesLoaded is false so this stays false too, keeping the button's
    // label neutral instead of flashing "different city" before either doc
    // has actually resolved.
    final differentCity = citiesLoaded && !sameCity;
    // storeStatus == null / !citiesLoaded means a doc hasn't loaded yet -
    // fails closed (checkout stays disabled) rather than briefly allowing a
    // tap before the real state is known.
    final disabled = waitingPayment ||
        differentCity ||
        isClosed ||
        isBusy ||
        storeStatus == null ||
        !citiesLoaded;

    final label = waitingPayment
        ? TranslationHelper.get('waiting_payment_title')
        : differentCity
            ? TranslationHelper.get('reorder_different_city')
            : isClosed
                ? TranslationHelper.get('store_closed')
                : isBusy
                    ? TranslationHelper.get('store_busy')
                    : TranslationHelper.get('go_to_checkout');

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      color: Colors.white,
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: disabled ? null : () => _goToCheckout(),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF9800),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFFFC98A),
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }

  Future<void> _adjustQuantity(CartLine line, int delta) async {
    final newQty = line.quantity + delta;
    if (newQty <= 0) {
      await StoreCartService.removeLine(
          widget.uid, widget.storeId, line.lineKey);
    } else {
      await StoreCartService.setLineQuantity(
          widget.uid, widget.storeId, line.lineKey, newQty);
    }
  }

  void _openStorePage(Map<String, dynamic>? data) {
    final storeNameAr = data?['store_name_ar'] as String? ?? '';
    final storeNameFr = data?['store_name_fr'] as String? ?? '';
    final storeImage = data?['store_image'] as String? ?? '';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoreDetails(widget.language, widget.storeId,
            widget.uid, storeNameAr, storeNameFr, storeImage),
      ),
    );
  }

  void _goToCheckout() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PushOrderPage(widget.language, widget.uid, widget.storeId),
      ),
    );
  }

  Future<void> _clearCart() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: Color(0xFFFDF1F0),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFE74C3C),
                  size: 30,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                TranslationHelper.get('confirm_clear_cart'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                TranslationHelper.get('confirm_clear_cart_message'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              ),
              const SizedBox(height: 22),
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
                        backgroundColor: const Color(0xFFE74C3C),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('clear_cart_button'),
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
    if (confirmed == true) {
      await StoreCartService.clearLines(widget.uid, widget.storeId);
    }
  }
}
