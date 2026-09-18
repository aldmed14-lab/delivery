import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/cart_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';

/// List of the user's active per-store carts, read from
/// `users/{uid}/carts` (one doc per store, per `lib/map.txt`). Each doc
/// already carries its own `store_name_ar`/`store_name_fr`/`store_image`
/// (written by [StoreCartService.addLine]), so no extra `stores` lookups
/// are needed to render a card.
class CartListPage extends StatefulWidget {
  final String uid;
  final String language;

  /// Called instead of popping the route when set - used when this page is
  /// hosted as a persistent tab inside HomeShell (there's nothing to pop:
  /// it was never pushed), to switch back to the Home tab instead. Null
  /// when CartListPage is pushed directly (e.g. from a store's checkout flow),
  /// where a normal pop is correct.
  final VoidCallback? onBack;

  const CartListPage(this.language, this.uid, {this.onBack, super.key});

  @override
  State<CartListPage> createState() => _CartListPageState();
}

class _CartListPageState extends State<CartListPage> {
  final _firestore = FirebaseFirestore.instance;
  CachedAd? _ad;

  bool get _isArabic => widget.language == 'ar';

  Stream<QuerySnapshot<Map<String, dynamic>>> get _cartsStream => _firestore
      .collection('users')
      .doc(widget.uid)
      .collection('carts')
      .where('waiting_payment', isEqualTo: false)
      .snapshots();

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  // No dispose-time AdService.flush()/refresh() here - HomeShell owns the
  // background refresh/flush timers for the whole session (see
  // home_shell.dart), so every ad-showing page just reads whatever's
  // already cached instead of managing that lifecycle itself.
  void _loadAd() {
    final ad = AdService.instance.nextAdFor('carts_list');
    if (ad != null) AdService.instance.recordView(ad, 'carts_list');
    if (mounted) setState(() => _ad = ad);
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, 'carts_list');
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
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _cartsStream,
          builder: (context, snapshot) {
            final carts = (snapshot.data?.docs ?? [])
                .where(
                    (d) => ((d.data()['lines'] as Map?)?.isNotEmpty ?? false))
                .toList();

            return Column(
              children: [
                _buildAppBar(carts),
                Expanded(
                    child: SafeArea(
                        top: false, child: _buildBody(snapshot, carts))),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAppBar(List<QueryDocumentSnapshot<Map<String, dynamic>>> carts) {
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
          const SizedBox(width: 38),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  TranslationHelper.get('title'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                if (carts.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${carts.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFFF9800),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 38),
        ],
      ),
    );
  }

  Widget _buildBody(
    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> carts,
  ) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF9800)),
        ),
      );
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

    if (carts.isEmpty) return _buildEmptyState();

    // Built as one explicit widget list (rather than deriving the ad's
    // position from the cart index inside itemBuilder) so the ad slot
    // can't collide with the footer note's own index check - with
    // exactly one cart both used to land on index 1, and the footer
    // check ran first, silently swallowing the ad slot every time.
    final items = <Widget>[
      _buildCartCard(carts[0]),
      if (_ad != null)
        SponsoredAdCard(
          ad: _ad!,
          language: widget.language,
          onTap: () => _handleAdTap(_ad!),
        ),
      for (final cart in carts.skip(1)) _buildCartCard(cart),
      _buildFooterNote(),
    ];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      itemCount: items.length,
      separatorBuilder: (_, i) => const SizedBox(height: 12),
      itemBuilder: (context, index) => items[index],
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
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: widget.onBack ?? () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  TranslationHelper.get('browse_stores'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooterNote() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        TranslationHelper.get('cart_per_store_note'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: Color(0xFF9AA1AC)),
      ),
    );
  }

  Widget _buildCartCard(QueryDocumentSnapshot<Map<String, dynamic>> cart) {
    final data = cart.data();
    final storeId = cart.id;
    final storeNameAr = data['store_name_ar'] as String? ?? '';
    final storeNameFr = data['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final storeImage = data['store_image'] as String? ?? '';

    final lines = StoreCartService.linesFrom(data);
    final totalQuantity = lines.fold<int>(0, (acc, l) => acc + l.quantity);
    final totalPrice = lines.fold<double>(0, (acc, l) => acc + l.lineTotal);

    // `_cartsStream` already filters to `waiting_payment == false` - a
    // cart waiting on payment surfaces on OrdersListPage instead, so this
    // card never needs to render that state.
    return Dismissible(
      key: ValueKey(cart.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: _isArabic ? Alignment.centerLeft : Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: const Color(0xFFE74C3C),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(),
      onDismissed: (_) => cart.reference.delete(),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                CartPage(widget.language, widget.uid, storeId),
          ),
        ),
        child: Container(
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
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 68,
                  height: 68,
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
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2E3A59),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      TranslationHelper.get(
                          totalQuantity == 1
                              ? 'cart_item_count_one'
                              : 'cart_item_count_other',
                          {'count': totalQuantity}),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF9AA1AC),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${totalPrice.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFFF9800),
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _deleteFromCard(cart),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: const Color(0xFFE74C3C).withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderImage() {
    return Container(
      color: const Color(0xFFFFEFD9),
      child: const Icon(
        Icons.store_rounded,
        color: Color(0xFFFF9800),
        size: 28,
      ),
    );
  }

  Future<bool> _confirmDelete() => _confirmDeleteDialog(
      'confirm_delete_cart', 'confirm_delete_cart_message');

  Future<void> _deleteFromCard(
      QueryDocumentSnapshot<Map<String, dynamic>> cart) async {
    if (cart.data()['waiting_payment'] == true) return;
    if (await _confirmDelete()) await cart.reference.delete();
  }

  Future<bool> _confirmDeleteDialog(String titleKey, String messageKey) async {
    final result = await showDialog<bool>(
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
                TranslationHelper.get(titleKey),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                TranslationHelper.get(messageKey),
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
                        TranslationHelper.get('delete'),
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
    return result ?? false;
  }
}
