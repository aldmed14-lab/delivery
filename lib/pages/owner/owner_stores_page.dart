import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/owner/owner_store_detail_page.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// The stores this account manages - `users/{uid}/stores` (`lib/map.txt`)
/// lists which stores the user is linked to, but that link alone isn't
/// proof of *current* access: a store's `owners/{uid}` sub-doc is the
/// actual authority (it can be missing entirely, or `status: "removed"`,
/// if the owner was since taken off the store elsewhere), so every listed
/// store is cross-checked against it before showing.
class OwnerStoresPage extends StatefulWidget {
  final String language;
  const OwnerStoresPage(this.language, {super.key});

  @override
  State<OwnerStoresPage> createState() => _OwnerStoresPageState();
}

class _OwnerStoresPageState extends State<OwnerStoresPage> {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  List<Map<String, dynamic>> _stores = [];
  bool _isLoading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _loadStores();
  }

  Future<void> _loadStores() async {
    try {
      final linksSnap = await _firestore
          .collection('users')
          .doc(_uid)
          .collection('stores')
          .get();
      final resolved = await Future.wait(linksSnap.docs.map(_resolveStore));
      if (!mounted) return;
      setState(() {
        _stores = resolved.whereType<Map<String, dynamic>>().toList();
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

  /// Returns null (meaning: don't list this store) when the owner link is
  /// missing or removed, or the store itself no longer exists.
  Future<Map<String, dynamic>?> _resolveStore(
      QueryDocumentSnapshot<Map<String, dynamic>> link) async {
    final storeId = link.id;

    final ownerSnap = await _firestore
        .collection('stores')
        .doc(storeId)
        .collection('owners')
        .doc(_uid)
        .get();
    if (!ownerSnap.exists || ownerSnap.data()?['status'] == 'removed') {
      return null;
    }

    final storeSnap = await _firestore.collection('stores').doc(storeId).get();
    if (!storeSnap.exists) return null;
    final storeData = storeSnap.data()!;
    final linkData = link.data();

    return {
      'store_id': storeId,
      // The `stores` doc is the canonical name - `users/{uid}/stores`'s own
      // name_ar/name_fr is just a denormalized copy (written once when the
      // link was made) that can go stale if the store's name changes
      // later, so it's only a fallback here, not the primary source.
      'name_ar': (storeData['name_ar'] as String?) ??
          (linkData['name_ar'] as String?) ??
          '',
      'name_fr': (storeData['name_fr'] as String?) ??
          (linkData['name_fr'] as String?) ??
          '',
      'image': (linkData['image'] as String?) ??
          (storeData['image'] as String?) ??
          '',
      'city': storeData['city'] as String? ?? '',
    };
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
          Text(
            TranslationHelper.get('my_stores'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoadingSkeleton();

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              TranslationHelper.get(
                  isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _loadError = null;
                });
                _loadStores();
              },
              child: Text(TranslationHelper.get('retry')),
            ),
          ],
        ),
      );
    }

    if (_stores.isEmpty) return _buildEmptyState();

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _stores.length,
      separatorBuilder: (_, i) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildStoreCard(_stores[index]),
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
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: row()),
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
                Icons.storefront_outlined,
                size: 56,
                color: Color(0xFFFF9800),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              TranslationHelper.get('no_owner_stores'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              TranslationHelper.get('no_owner_stores_subtitle'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoreCard(Map<String, dynamic> store) {
    final storeNameAr = store['name_ar'] as String? ?? '';
    final storeNameFr = store['name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final storeImage = store['image'] as String? ?? '';
    final city = store['city'] as String? ?? '';

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              OwnerStoreDetailPage(widget.language, store['store_id'] as String),
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
                  if (city.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      city,
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              _isArabic ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
              color: const Color(0xFFC9CDD4),
            ),
          ],
        ),
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
