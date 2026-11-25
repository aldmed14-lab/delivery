import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// One category row - a plain mutable copy of its doc's data (same reason
/// as store_menu_page.dart's own `_ItemRow`: `QueryDocumentSnapshot` is
/// sealed and can't be wrapped to reflect an optimistic local edit/reorder
/// before Firestore's own write lands).
class _CategoryRow {
  final String id;
  final DocumentReference<Map<String, dynamic>> ref;
  Map<String, dynamic> data;

  _CategoryRow({required this.id, required this.ref, required this.data});
}

/// Owner's category manager (`stores/{storeId}/categories`, `lib/map.txt`) -
/// add/edit/delete/reorder, reached from store_menu_page.dart's header.
/// Reordering renumbers every category's `index` in one batch, matching how
/// store_menu_page.dart's own category chips and store_item_edit_page.dart's
/// category dropdown are ordered.
class StoreCategoriesPage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreCategoriesPage(this.language, this.storeId, {super.key});

  @override
  State<StoreCategoriesPage> createState() => _StoreCategoriesPageState();
}

class _StoreCategoriesPageState extends State<StoreCategoriesPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;
  List<_CategoryRow> _categories = [];

  bool _isReordering = false;

  CollectionReference<Map<String, dynamic>> get _categoriesRef => _firestore
      .collection('stores')
      .doc(widget.storeId)
      .collection('categories');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final categoriesSnap = await _categoriesRef.orderBy('index').get();
      if (!mounted) return;
      setState(() {
        _categories = categoriesSnap.docs
            .map(
                (d) => _CategoryRow(id: d.id, ref: d.reference, data: d.data()))
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

  String _categoryName(Map<String, dynamic> data) {
    final nameAr = data['name_ar'] as String? ?? '';
    final nameFr = data['name_fr'] as String? ?? '';
    final name = _isArabic ? nameAr : nameFr;
    return name.isNotEmpty ? name : nameFr;
  }

  /// Moves the category at [index] by exactly one slot ([direction] -1 = up,
  /// +1 = down), swapping its `index` with that one neighbor - not a free
  /// drag-and-drop list move, which could shift every category in between
  /// depending on how far the drag travelled instead of just the two
  /// actually involved.
  Future<void> _swap(int index, int direction) async {
    if (_isReordering) return;
    final otherIndex = index + direction;
    if (otherIndex < 0 || otherIndex >= _categories.length) return;

    final a = _categories[index];
    final b = _categories[otherIndex];
    final aIndex = a.data['index'];
    final bIndex = b.data['index'];

    // Optimistic - matches store_menu_page.dart's own toggle pattern: show
    // the swap instantly, roll back only if the write fails. Each row keeps
    // its own name/show_type - only its `index` field and its slot in the
    // displayed list change, swapped with the other row's.
    setState(() {
      a.data = {...a.data, 'index': bIndex};
      b.data = {...b.data, 'index': aIndex};
      _categories[index] = b;
      _categories[otherIndex] = a;
      _isReordering = true;
    });
    try {
      final online = await InternetConnectionService().checkNow();
      if (!online) throw Exception('offline');
      final batch = _firestore.batch();
      batch.update(a.ref, {'index': bIndex});
      batch.update(b.ref, {'index': aIndex});
      await batch.commit();
    } catch (e) {
      if (mounted) {
        setState(() {
          a.data = {...a.data, 'index': aIndex};
          b.data = {...b.data, 'index': bIndex};
          _categories[index] = a;
          _categories[otherIndex] = b;
        });
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isReordering = false);
    }
  }

  Future<void> _openEditor({_CategoryRow? existing}) async {
    final data = existing?.data;
    final nameFrController =
        TextEditingController(text: data?['name_fr'] as String? ?? '');
    final nameArController =
        TextEditingController(text: data?['name_ar'] as String? ?? '');
    var showType = data?['show_type'] as String? ?? 'row';

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            title: Text(TranslationHelper.get(existing == null
                ? 'add_category_title'
                : 'edit_category_title')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameFrController,
                  decoration: InputDecoration(
                    labelText: TranslationHelper.get('category_name_fr_label'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameArController,
                  decoration: InputDecoration(
                    labelText: TranslationHelper.get('category_name_ar_label'),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    TranslationHelper.get('category_show_type_label'),
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'row',
                      label: Text(TranslationHelper.get('show_type_row')),
                    ),
                    ButtonSegment(
                      value: 'column',
                      label: Text(TranslationHelper.get('show_type_column')),
                    ),
                  ],
                  selected: {showType},
                  onSelectionChanged: (v) =>
                      setDialogState(() => showType = v.first),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(TranslationHelper.get('cancel')),
              ),
              ElevatedButton(
                onPressed: () {
                  if (nameFrController.text.trim().isEmpty) {
                    showAlert(TranslationHelper.get('category_name_required'),
                        isError: true);
                    return;
                  }
                  Navigator.pop(context, true);
                },
                child: Text(TranslationHelper.get('save')),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved != true) {
      nameFrController.dispose();
      nameArController.dispose();
      return;
    }

    final payload = {
      'name_fr': nameFrController.text.trim(),
      'name_ar': nameArController.text.trim(),
      'show_type': showType,
    };
    nameFrController.dispose();
    nameArController.dispose();

    try {
      if (existing == null) {
        final ref = await _categoriesRef.add({
          ...payload,
          'index': _categories.length,
        });
        if (!mounted) return;
        setState(() => _categories = [
              ..._categories,
              _CategoryRow(
                  id: ref.id,
                  ref: ref,
                  data: {...payload, 'index': _categories.length}),
            ]);
      } else {
        await existing.ref.update(payload);
        if (!mounted) return;
        setState(() => existing.data = {...existing.data, ...payload});
      }
    } catch (e) {
      if (mounted) {
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
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              if (alertCard != null) alertCard!,
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _loadError != null
                        ? _buildErrorState()
                        : _buildBody(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Text(
        TranslationHelper.get(
            isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
        style: const TextStyle(color: Color(0xFF9AA1AC)),
      ),
    );
  }

  Widget _buildHeader() {
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
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              TranslationHelper.get('manage_categories_title'),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _openEditor(),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.add, size: 20, color: Color(0xFFFF9800)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_categories.isEmpty) {
      return Center(
        child: Text(
          TranslationHelper.get('no_categories_yet'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: _categories.length,
      itemBuilder: (context, i) => _buildCategoryRow(i),
    );
  }

  Widget _buildCategoryRow(int index) {
    final category = _categories[index];
    final showType = category.data['show_type'] as String? ?? 'row';
    return Container(
      key: ValueKey(category.id),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _moveButton(Icons.keyboard_arrow_up_rounded,
                  index > 0 ? () => _swap(index, -1) : null),
              _moveButton(
                  Icons.keyboard_arrow_down_rounded,
                  index < _categories.length - 1
                      ? () => _swap(index, 1)
                      : null),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: () => _openEditor(existing: category),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _categoryName(category.data),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      TranslationHelper.get(showType == 'column'
                          ? 'show_type_column'
                          : 'show_type_row'),
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF9800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _moveButton(IconData icon, VoidCallback? onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          icon,
          size: 20,
          color:
              onTap == null ? const Color(0xFFE1E4E9) : const Color(0xFF9AA1AC),
        ),
      ),
    );
  }
}
