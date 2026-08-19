import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// Opens the item-detail bottom sheet for [itemId] and, on "Ajouter au
/// panier", writes straight into [uid]'s cart for [storeId] via
/// [StoreCartService]. Self-contained - the caller doesn't need the
/// result, the cart stream it's already listening to reflects the change.
Future<void> showItemDetailSheet({
  required BuildContext context,
  required String language,
  required String uid,
  required String storeId,
  required String storeNameAr,
  required String storeNameFr,
  required String storeImage,
  required String itemId,
  required Map<String, dynamic> itemData,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _ItemDetailSheet(
      language: language,
      uid: uid,
      storeId: storeId,
      storeNameAr: storeNameAr,
      storeNameFr: storeNameFr,
      storeImage: storeImage,
      itemId: itemId,
      itemData: itemData,
    ),
  );
}

class _ItemDetailSheet extends StatefulWidget {
  final String language;
  final String uid;
  final String storeId;
  final String storeNameAr;
  final String storeNameFr;
  final String storeImage;
  final String itemId;
  final Map<String, dynamic> itemData;

  const _ItemDetailSheet({
    required this.language,
    required this.uid,
    required this.storeId,
    required this.storeNameAr,
    required this.storeNameFr,
    required this.storeImage,
    required this.itemId,
    required this.itemData,
  });

  @override
  State<_ItemDetailSheet> createState() => _ItemDetailSheetState();
}

class _ItemDetailSheetState extends State<_ItemDetailSheet>
    with AlertCardMixin {
  int _quantity = 1;
  bool _loadingGroups = true;
  bool _isAdding = false;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _groups = [];

  /// groupId -> indices selected within that group's options[] list.
  final Map<String, Set<int>> _groupSelections = {};

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  /// This sheet is only ever for composing a new addition to the cart -
  /// reducing/removing an existing line happens from the item row's own
  /// stepper on the main page, not from in here.
  Future<void> _loadGroups() async {
    try {
      final groupsSnap = await FirebaseFirestore.instance
          .collection('stores')
          .doc(widget.storeId)
          .collection('groups')
          .where('item_id', isEqualTo: widget.itemId)
          .orderBy('index')
          .get();

      if (mounted) {
        setState(() {
          _groups = groupsSnap.docs;
          _loadingGroups = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  double get _unitPrice {
    double total = (widget.itemData['price'] as num?)?.toDouble() ?? 0;
    for (final g in _groups) {
      final options = (g.data()['options'] as List?) ?? const [];
      for (final idx in _groupSelections[g.id] ?? const <int>{}) {
        if (idx >= options.length) continue;
        final opt = options[idx] as Map;
        total += (opt['price'] as num?)?.toDouble() ?? 0;
      }
    }
    return total;
  }

  bool get _canAdd {
    if (_loadingGroups) return false;
    for (final g in _groups) {
      final min = (g.data()['min'] as num?)?.toInt() ?? 0;
      if (min > 0 && (_groupSelections[g.id]?.length ?? 0) < min) return false;
    }
    return true;
  }

  void _toggleGroupOption(String groupId, int index, int min, int max) {
    setState(() {
      final selected = _groupSelections.putIfAbsent(groupId, () => <int>{});
      final singleSelect = min == 1 && max == 1;
      if (singleSelect) {
        selected
          ..clear()
          ..add(index);
        return;
      }
      if (selected.contains(index)) {
        selected.remove(index);
      } else if (max <= 0 || selected.length < max) {
        selected.add(index);
      }
    });
  }

  void _decrement() {
    if (_quantity > 1) setState(() => _quantity--);
  }

  void _increment() {
    setState(() => _quantity++);
  }

  Future<void> _addToCart() async {
    if (!_canAdd || _isAdding) return;

    setState(() => _isAdding = true);

    final groups = <Map<String, dynamic>>[];
    for (final g in _groups) {
      final data = g.data();
      final options = (data['options'] as List?) ?? const [];
      final selected = _groupSelections[g.id] ?? const <int>{};
      if (selected.isEmpty) continue;
      groups.add({
        'group_id': g.id,
        'name_ar': data['name_ar'],
        'name_fr': data['name_fr'],
        'selected': selected
            .map((idx) => {
                  'option_id': (options[idx] as Map)['option_id'],
                  'name_ar': (options[idx] as Map)['name_ar'],
                  'name_fr': (options[idx] as Map)['name_fr'],
                  'price': (options[idx] as Map)['price'],
                })
            .toList(),
      });
    }

    final lineKey = StoreCartService.lineKeyFor(widget.itemId, groups);

    final line = CartLine(
      lineKey: lineKey,
      itemId: widget.itemId,
      nameAr: widget.itemData['name_ar'] ?? '',
      nameFr: widget.itemData['name_fr'] ?? '',
      image: widget.itemData['image'] ?? '',
      quantity: _quantity,
      unitPrice: _unitPrice,
      groups: groups,
    );

    try {
      await StoreCartService.addLine(
        widget.uid,
        widget.storeId,
        storeNameAr: widget.storeNameAr,
        storeNameFr: widget.storeNameFr,
        storeImage: widget.storeImage,
        line: line,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        showAlert(TranslationHelper.get('error'), isError: true);
      }
    } finally {
      // Only reached on failure - the success path already popped the
      // sheet, so there's nothing left mounted to update.
      if (mounted) setState(() => _isAdding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.itemData['name_${widget.language}'] ??
        widget.itemData['name_fr'] ??
        '';
    final description =
        widget.itemData['description_${widget.language}'] as String? ??
            widget.itemData['description_fr'] as String?;

    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          color: Colors.black.withValues(alpha: 0.45),
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            maxChildSize: 0.92,
            minChildSize: 0.4,
            builder: (context, scrollController) => GestureDetector(
              onTap: () {},
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3E5E9),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    if (alertCard != null) alertCard!,
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                        children: [
                          if ((widget.itemData['image'] as String?)
                                  ?.isNotEmpty ==
                              true)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: AspectRatio(
                                aspectRatio: 16 / 10,
                                child: CachedNetworkImage(
                                  imageUrl: widget.itemData['image'],
                                  fit: BoxFit.cover,
                                  placeholder: (c, u) =>
                                      Container(color: Colors.grey[200]),
                                  errorWidget: (c, u, e) =>
                                      Container(color: Colors.grey[200]),
                                ),
                              ),
                            ),
                          if ((widget.itemData['image'] as String?)
                                  ?.isNotEmpty ==
                              true)
                            const SizedBox(height: 16),
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF2E3A59),
                            ),
                          ),
                          if (description != null &&
                              description.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              description,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF9AA1AC),
                                height: 1.4,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (_loadingGroups)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: CircularProgressIndicator(
                                    color: Color(0xFFFF9800)),
                              ),
                            )
                          else
                            for (final g in _groups) _buildGroup(g),
                        ],
                      ),
                    ),
                    _buildBottomBar(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _groupSubtitle(int min, int max) {
    if (min <= 0) return '';
    if (min == max) {
      return TranslationHelper.get('group_required_exact', {'count': '$min'});
    }
    if (max > min) {
      return TranslationHelper.get(
          'group_required_range', {'min': '$min', 'max': '$max'});
    }
    return TranslationHelper.get('group_required_min', {'min': '$min'});
  }

  Widget _buildGroupHeader(String title, int min, int max) {
    final required = min > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: required
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _groupSubtitle(min, max),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFFF9800),
                  ),
                ),
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F1F4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    TranslationHelper.get('optional_label'),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9AA1AC),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSelectionIndicator(bool selected, bool isRadio) {
    final size = 22.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFFF9800) : Colors.white,
        shape: isRadio ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isRadio ? null : BorderRadius.circular(6),
        border: Border.all(
          color: selected ? const Color(0xFFFF9800) : const Color(0xFFD8DCE2),
          width: 1.6,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, color: Colors.white, size: 14)
          : null,
    );
  }

  Widget _buildOptionRow({
    required String name,
    required num price,
    required bool selected,
    required bool isRadio,
    required VoidCallback onTap,
  }) {
    final priceText = price == 0
        ? TranslationHelper.get('free_label')
        : '+${price.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}';
    final priceColor =
        selected ? const Color(0xFFFF9800) : const Color(0xFF1B8A3E);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF3E0) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFFFF9800) : const Color(0xFFF0F1F4),
            width: 1.4,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            Text(
              priceText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: priceColor,
              ),
            ),
            const SizedBox(width: 10),
            _buildSelectionIndicator(selected, isRadio),
          ],
        ),
      ),
    );
  }

  Widget _buildGroup(QueryDocumentSnapshot<Map<String, dynamic>> g) {
    final data = g.data();
    final min = (data['min'] as num?)?.toInt() ?? 0;
    final max = (data['max'] as num?)?.toInt() ?? 0;
    final options = (data['options'] as List?) ?? const [];
    final isRadio = min == 1 && max == 1;
    final selected = _groupSelections[g.id] ?? const <int>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildGroupHeader(
            data['name_${widget.language}'] ?? data['name_fr'] ?? '', min, max),
        for (int i = 0; i < options.length; i++)
          _buildOptionRow(
            name: options[i]['name_${widget.language}'] ??
                options[i]['name_fr'] ??
                '',
            price: (options[i]['price'] as num?) ?? 0,
            selected: selected.contains(i),
            isRadio: isRadio,
            onTap: () => _toggleGroupOption(g.id, i, min, max),
          ),
      ],
    );
  }

  Widget _buildBottomBar() {
    final total = _unitPrice * _quantity;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF6F7F9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _quantity > 1 ? _decrement : null,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    child: Icon(Icons.remove,
                        size: 18,
                        color: _quantity > 1
                            ? const Color(0xFF677489)
                            : const Color(0xFFC9CDD4)),
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: Text(
                    '$_quantity',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.all(5),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: _increment,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF9800),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child:
                          const Icon(Icons.add, color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: (_canAdd && !_isAdding) ? _addToCart : null,
            child: Container(
              width: double.infinity,
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: _canAdd
                    ? const LinearGradient(
                        colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
                      )
                    : null,
                color: _canAdd ? null : const Color(0xFFE5E8ED),
                borderRadius: BorderRadius.circular(16),
              ),
              child: _isAdding
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : _canAdd
                      ? Row(
                          children: [
                            Text(
                              TranslationHelper.get('add_to_cart'),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${total.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        )
                      : Text(
                          TranslationHelper.get('selection_required'),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF9AA1AC),
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }
}
