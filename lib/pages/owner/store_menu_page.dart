import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/pages/owner/store_item_edit_page.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// One menu item row - a plain mutable copy of its doc's data (rather than
/// a `QueryDocumentSnapshot`, which is sealed and can't be wrapped to
/// reflect an optimistic local edit before Firestore's own write lands).
class _ItemRow {
  final String id;
  final DocumentReference<Map<String, dynamic>> ref;
  Map<String, dynamic> data;

  _ItemRow({required this.id, required this.ref, required this.data});
}

/// Owner's menu manager - search/filter every item, flip `exist`
/// (available/unavailable) inline, or tap a row (or the header "+") to
/// open [StoreItemEditPage].
class StoreMenuPage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreMenuPage(this.language, this.storeId, {super.key});

  @override
  State<StoreMenuPage> createState() => _StoreMenuPageState();
}

class _StoreMenuPageState extends State<StoreMenuPage> with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _searchController = TextEditingController();

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _categories = [];
  List<_ItemRow> _items = [];

  String? _selectedCategoryId; // null = "Tout" (all categories)
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    try {
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
            .get(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = results[0].docs;
        _items = results[1]
            .docs
            .map((d) => _ItemRow(id: d.id, ref: d.reference, data: d.data()))
            .toList();
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

  String _itemName(Map<String, dynamic> data) {
    final nameAr = data['name_ar'] as String? ?? '';
    final nameFr = data['name_fr'] as String? ?? '';
    final name = _isArabic ? nameAr : nameFr;
    return name.isNotEmpty ? name : (nameFr.isNotEmpty ? nameFr : '');
  }

  String _categoryName(QueryDocumentSnapshot<Map<String, dynamic>> cat) {
    final data = cat.data();
    final nameAr = data['name_ar'] as String? ?? '';
    final nameFr = data['name_fr'] as String? ?? '';
    final name = _isArabic ? nameAr : nameFr;
    return name.isNotEmpty ? name : nameFr;
  }

  /// Null-safe lookup instead of an unguarded `firstWhere` - `_categories`
  /// is only ever refreshed by _load(), so a stray `_selectedCategoryId`
  /// pointing at nothing can't happen today, but it's cheap insurance for
  /// whenever category deletion ships.
  QueryDocumentSnapshot<Map<String, dynamic>>? get _selectedCategory {
    if (_selectedCategoryId == null) return null;
    for (final cat in _categories) {
      if (cat.id == _selectedCategoryId) return cat;
    }
    return null;
  }

  List<_ItemRow> get _visibleItems {
    final category = _selectedCategory;
    return _items.where((item) {
      if (category != null && item.data['category'] != category.id) {
        return false;
      }
      if (_searchQuery.isEmpty) return true;
      return _itemName(item.data).toLowerCase().contains(_searchQuery);
    }).toList();
  }

  Future<void> _toggleExist(_ItemRow item, bool value) async {
    // Firestore's offline write cache resolves `.update()` successfully the
    // moment it's queued locally, WITHOUT actual connectivity - it doesn't
    // wait for a server round-trip, so `await` below can complete with no
    // error at all while genuinely offline, and the catch block's rollback
    // never runs. Check real reachability explicitly first.
    final online = await InternetConnectionService().checkNow();
    if (!online) {
      if (mounted) showAlert(TranslationHelper.get('no_internet'), isError: true);
      return;
    }
    // Optimistic - flips instantly, rolled back only if the write fails.
    setState(() => item.data = {...item.data, 'exist': value});
    try {
      await item.ref.update({'exist': value});
    } catch (e) {
      if (mounted) {
        setState(() => item.data = {...item.data, 'exist': !value});
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
  }

  void _openItemEditor({String? itemId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            StoreItemEditPage(widget.language, widget.storeId, itemId: itemId),
      ),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _buildErrorState()
                : Column(
                    children: [
                      _buildHeader(),
                      if (alertCard != null) alertCard!,
                      Expanded(child: _buildBody()),
                    ],
                  ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              TranslationHelper.get(
                  isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(TranslationHelper.get('go_back')),
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
                  TranslationHelper.get('manage_menu_title'),
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
                onTap: () => _openItemEditor(),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, size: 20, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, color: Color(0xFF9AA1AC), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    textDirection:
                        _isArabic ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: TranslationHelper.get('search_item_hint'),
                      hintStyle:
                          const TextStyle(fontSize: 13.5, color: Color(0xFF9AA1AC)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final items = _visibleItems;
    return Column(
      children: [
        const SizedBox(height: 12),
        _buildCategoryChips(),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment:
                _isArabic ? Alignment.centerRight : Alignment.centerLeft,
            child: Text(
              _selectedCategory == null
                  ? TranslationHelper.get('all')
                  : _categoryName(_selectedCategory!),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF9AA1AC),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    TranslationHelper.get('no_menu_items'),
                    style: const TextStyle(color: Color(0xFF9AA1AC)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _buildItemRow(items[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildCategoryChips() {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _buildCategoryChip(null, TranslationHelper.get('all')),
          for (final cat in _categories) ...[
            const SizedBox(width: 8),
            _buildCategoryChip(cat.id, _categoryName(cat)),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryChip(String? categoryId, String label) {
    final selected = _selectedCategoryId == categoryId;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _selectedCategoryId = categoryId),
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
    );
  }

  Widget _buildItemRow(_ItemRow item) {
    final data = item.data;
    final name = _itemName(data);
    final price = (data['price'] as num?) ?? 0;
    final image = data['image'] as String? ?? '';
    final exist = data['exist'] as bool? ?? true;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
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
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 48,
              height: 48,
              child: image.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: image,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(color: Colors.grey[200]),
                      errorWidget: (c, u, e) => Container(color: Colors.grey[200]),
                    )
                  : Container(color: Colors.grey[200]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () => _openItemEditor(itemId: item.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${price.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFF9800),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Switch(
            value: exist,
            activeThumbColor: const Color(0xFFFF9800),
            onChanged: (v) => _toggleExist(item, v),
          ),
        ],
      ),
    );
  }
}
