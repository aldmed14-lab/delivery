import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:flutter_application_1/widgets/discard_changes_dialog.dart';

/// One option inside a group - `option_id` is minted once, right when the
/// option is added, and never regenerated afterwards (so an already-placed
/// cart line referencing it - `carts.*.lines.*.groups[].selected[].option_id`,
/// lib/map.txt - keeps meaning the same thing even if this item is edited
/// again before that cart is checked out).
class _OptionForm {
  final String optionId;
  final TextEditingController nameFr;
  final TextEditingController nameAr;
  final TextEditingController price;

  _OptionForm({
    String? optionId,
    String nameFr = '',
    String nameAr = '',
    String price = '',
  })  : optionId = optionId ?? const Uuid().v4(),
        nameFr = TextEditingController(text: nameFr),
        nameAr = TextEditingController(text: nameAr),
        price = TextEditingController(text: price);

  void dispose() {
    nameFr.dispose();
    nameAr.dispose();
    price.dispose();
  }
}

/// One options group (`stores/{storeId}/groups`, linked to this item via
/// `item_id`) - `id` is the existing doc id when editing one, null for a
/// group added in this session (not yet saved).
class _GroupForm {
  String? id;
  final TextEditingController nameFr;
  final TextEditingController nameAr;
  final TextEditingController min;
  final TextEditingController max;
  final List<_OptionForm> options;

  _GroupForm({
    this.id,
    String nameFr = '',
    String nameAr = '',
    String min = '0',
    String max = '1',
    List<_OptionForm>? options,
  })  : nameFr = TextEditingController(text: nameFr),
        nameAr = TextEditingController(text: nameAr),
        min = TextEditingController(text: min),
        max = TextEditingController(text: max),
        options = options ?? [];

  void dispose() {
    nameFr.dispose();
    nameAr.dispose();
    min.dispose();
    max.dispose();
    for (final o in options) {
      o.dispose();
    }
  }
}

/// Add/edit a single menu item, and its option groups
/// (`stores/{storeId}/groups`, linked back via `item_id`). Null [itemId] =
/// creating a new item.
class StoreItemEditPage extends StatefulWidget {
  final String language;
  final String storeId;
  final String? itemId;
  const StoreItemEditPage(this.language, this.storeId, {this.itemId, super.key});

  @override
  State<StoreItemEditPage> createState() => _StoreItemEditPageState();
}

class _StoreItemEditPageState extends State<StoreItemEditPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _nameFrController = TextEditingController();
  final _nameArController = TextEditingController();
  final _descFrController = TextEditingController();
  final _descArController = TextEditingController();
  final _priceController = TextEditingController(text: '0');

  bool get _isArabic => widget.language == 'ar';
  bool get _isNew => widget.itemId == null;

  bool _isLoading = true;
  bool _isSaving = false;
  Object? _loadError;
  String _image = '';
  bool _exist = true;
  String? _categoryId;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _categories = [];
  final List<_GroupForm> _groups = [];

  // What's actually saved, as one comparable string covering every field
  // (including groups/options) - refreshed after both _load() and a
  // successful _save(), so a stray back-tap with pending edits can be caught.
  String _savedSignature = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameFrController.dispose();
    _nameArController.dispose();
    _descFrController.dispose();
    _descArController.dispose();
    _priceController.dispose();
    for (final g in _groups) {
      g.dispose();
    }
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final categoriesSnap = await _firestore
          .collection('stores')
          .doc(widget.storeId)
          .collection('categories')
          .orderBy('index')
          .get();
      _categories = categoriesSnap.docs;
      _categoryId = _categories.isNotEmpty ? _categories.first.id : null;

      if (!_isNew) {
        final results = await Future.wait([
          _firestore
              .collection('stores')
              .doc(widget.storeId)
              .collection('items')
              .doc(widget.itemId)
              .get(),
          _firestore
              .collection('stores')
              .doc(widget.storeId)
              .collection('groups')
              .where('item_id', isEqualTo: widget.itemId)
              .orderBy('index')
              .get(),
        ]);
        final itemSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
        final groupsSnap = results[1] as QuerySnapshot<Map<String, dynamic>>;

        if (!itemSnap.exists) {
          if (!mounted) return;
          setState(() {
            _loadError = StateError('item-not-found');
            _isLoading = false;
          });
          return;
        }
        final data = itemSnap.data()!;
        _nameFrController.text = data['name_fr'] as String? ?? '';
        _nameArController.text = data['name_ar'] as String? ?? '';
        _descFrController.text = data['description_fr'] as String? ?? '';
        _descArController.text = data['description_ar'] as String? ?? '';
        _priceController.text =
            ((data['price'] as num?)?.toInt() ?? 0).toString();
        _image = data['image'] as String? ?? '';
        _exist = data['exist'] as bool? ?? true;
        final category = data['category'] as String?;
        if (category != null && _categories.any((c) => c.id == category)) {
          _categoryId = category;
        }

        for (final doc in groupsSnap.docs) {
          final gData = doc.data();
          final options = ((gData['options'] as List?) ?? const [])
              .map((o) => o as Map<String, dynamic>)
              .map((o) => _OptionForm(
                    optionId: o['option_id'] as String?,
                    nameFr: o['name_fr'] as String? ?? '',
                    nameAr: o['name_ar'] as String? ?? '',
                    price: ((o['price'] as num?)?.toInt() ?? 0).toString(),
                  ))
              .toList();
          _groups.add(_GroupForm(
            id: doc.id,
            nameFr: gData['name_fr'] as String? ?? '',
            nameAr: gData['name_ar'] as String? ?? '',
            min: ((gData['min'] as num?)?.toInt() ?? 0).toString(),
            max: ((gData['max'] as num?)?.toInt() ?? 1).toString(),
            options: options,
          ));
        }
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _syncSavedSnapshot();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoading = false;
      });
    }
  }

  String _formSignature() {
    final groupsSig = _groups
        .map((g) => [
              g.nameFr.text.trim(),
              g.nameAr.text.trim(),
              g.min.text.trim(),
              g.max.text.trim(),
              g.options
                  .map((o) =>
                      '${o.nameFr.text.trim()}|${o.nameAr.text.trim()}|${o.price.text.trim()}')
                  .join(';'),
            ].join('~'))
        .join('##');

    return [
      _nameFrController.text.trim(),
      _nameArController.text.trim(),
      _descFrController.text.trim(),
      _descArController.text.trim(),
      _priceController.text.trim(),
      _categoryId ?? '',
      _exist.toString(),
      groupsSig,
    ].join('|||');
  }

  void _syncSavedSnapshot() {
    _savedSignature = _formSignature();
  }

  bool _hasUnsavedChanges() {
    if (_isLoading || _loadError != null) return false;
    return _formSignature() != _savedSignature;
  }

  Future<void> _handleBack() async {
    if (!_hasUnsavedChanges()) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await confirmDiscardChanges(context, isArabic: _isArabic);
    if (!mounted) return;
    if (discard) Navigator.of(context).pop();
  }

  void _addGroup() {
    setState(() => _groups.add(_GroupForm()));
  }

  void _removeGroup(int index) {
    setState(() {
      _groups[index].dispose();
      _groups.removeAt(index);
    });
  }

  void _addOption(_GroupForm group) {
    setState(() => group.options.add(_OptionForm()));
  }

  void _removeOption(_GroupForm group, int index) {
    setState(() {
      group.options[index].dispose();
      group.options.removeAt(index);
    });
  }

  /// min < options.length, max <= options.length, max >= min - and (kept
  /// as its own explicit check, even though it already follows from
  /// min < options.length above) a group where max == min can't equal
  /// options.length either: requiring every single option leaves nothing
  /// to actually choose, so that's not a meaningful "group" of options.
  String? _validateGroup(_GroupForm group, String groupLabel) {
    final n = group.options.length;
    if (n == 0) {
      return TranslationHelper.get('group_needs_options', {'group': groupLabel});
    }
    final min = int.tryParse(group.min.text.trim());
    final max = int.tryParse(group.max.text.trim());
    if (min == null || max == null) {
      return TranslationHelper.get('group_invalid_min_max', {'group': groupLabel});
    }
    if (min < 0 || min >= n) {
      return TranslationHelper.get('group_min_out_of_range', {'group': groupLabel});
    }
    if (max > n) {
      return TranslationHelper.get('group_max_out_of_range', {'group': groupLabel});
    }
    if (max < min) {
      return TranslationHelper.get('group_max_below_min', {'group': groupLabel});
    }
    if (max == min && max >= n) {
      return TranslationHelper.get('group_max_equals_min_all', {'group': groupLabel});
    }
    return null;
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final nameFr = _nameFrController.text.trim();
    if (nameFr.isEmpty) {
      showAlert(TranslationHelper.get('item_name_required'), isError: true);
      return;
    }
    if (_categoryId == null) {
      showAlert(TranslationHelper.get('category_required'), isError: true);
      return;
    }
    for (var i = 0; i < _groups.length; i++) {
      final group = _groups[i];
      final label = group.nameFr.text.trim().isNotEmpty
          ? group.nameFr.text.trim()
          : '#${i + 1}';
      final error = _validateGroup(group, label);
      if (error != null) {
        showAlert(error, isError: true);
        return;
      }
    }

    setState(() => _isSaving = true);
    try {
      final itemsRef = _firestore
          .collection('stores')
          .doc(widget.storeId)
          .collection('items');
      final itemRef = _isNew ? itemsRef.doc() : itemsRef.doc(widget.itemId);

      await itemRef.set({
        'name_fr': nameFr,
        'name_ar': _nameArController.text.trim(),
        'description_fr': _descFrController.text.trim(),
        'description_ar': _descArController.text.trim(),
        'price': int.tryParse(_priceController.text.trim()) ?? 0,
        'category': _categoryId,
        'exist': _exist,
        'image': _image,
        'options': const [],
      }, SetOptions(merge: true));

      final groupsRef = _firestore
          .collection('stores')
          .doc(widget.storeId)
          .collection('groups');
      final existingGroups =
          await groupsRef.where('item_id', isEqualTo: itemRef.id).get();

      final batch = _firestore.batch();
      for (final doc in existingGroups.docs) {
        batch.delete(doc.reference);
      }
      for (var i = 0; i < _groups.length; i++) {
        final group = _groups[i];
        batch.set(groupsRef.doc(), {
          'item_id': itemRef.id,
          'index': i,
          'name_fr': group.nameFr.text.trim(),
          'name_ar': group.nameAr.text.trim(),
          'min': int.tryParse(group.min.text.trim()) ?? 0,
          'max': int.tryParse(group.max.text.trim()) ?? 1,
          'options': [
            for (final o in group.options)
              {
                'option_id': o.optionId,
                'name_fr': o.nameFr.text.trim(),
                'name_ar': o.nameAr.text.trim(),
                'price': int.tryParse(o.price.text.trim()) ?? 0,
              },
          ],
        });
      }
      await batch.commit();

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Directionality(
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
                        _buildSaveBar(),
                      ],
                    ),
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
            onTap: _handleBack,
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
            TranslationHelper.get(
                _isNew ? 'new_item_title' : 'edit_item_title'),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildImagePreviewRow(),
        const SizedBox(height: 22),
        _buildSectionLabel('details_section_label'),
        const SizedBox(height: 10),
        _buildDetailsCard(),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildSectionLabel('groups_section_label'),
            InkWell(
              onTap: _addGroup,
              child: Text(
                TranslationHelper.get('add_group_link'),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFFF9800),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_groups.isEmpty)
          Text(
            TranslationHelper.get('no_groups_message'),
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
          )
        else
          for (var i = 0; i < _groups.length; i++) ...[
            _buildGroupCard(i),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  Widget _buildSectionLabel(String key) => Text(
        TranslationHelper.get(key),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      );

  Widget _buildImagePreviewRow() {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 52,
            height: 52,
            child: _image.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: _image,
                    fit: BoxFit.cover,
                    placeholder: (c, u) => Container(color: Colors.grey[200]),
                    errorWidget: (c, u, e) => Container(color: Colors.grey[200]),
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
                _nameFrController.text.isNotEmpty
                    ? _nameFrController.text
                    : TranslationHelper.get('item_name_placeholder'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              Text(
                '${_priceController.text.isEmpty ? '0' : _priceController.text} ${TranslationHelper.get('currency_unit')}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFFF9800),
                ),
              ),
            ],
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(19),
          onTap: () =>
              showAlert(TranslationHelper.get('change_image_coming_soon')),
          child: Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Color(0xFFFF9800),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add, color: Colors.white, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
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
          _buildFieldLabel('name_fr_field_label'),
          const SizedBox(height: 6),
          _buildTextField(_nameFrController,
              hint: TranslationHelper.get('item_name_fr_hint'),
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          _buildFieldLabel('name_ar_field_label'),
          const SizedBox(height: 6),
          _buildTextField(_nameArController,
              hint: TranslationHelper.get('item_name_ar_hint'),
              isArabicField: true),
          const SizedBox(height: 14),
          _buildFieldLabel('description_fr_field_label'),
          const SizedBox(height: 6),
          _buildTextField(_descFrController,
              hint: TranslationHelper.get('item_description_hint'),
              maxLines: 2),
          const SizedBox(height: 14),
          _buildFieldLabel('description_ar_field_label'),
          const SizedBox(height: 6),
          _buildTextField(_descArController,
              hint: TranslationHelper.get('item_description_hint'),
              isArabicField: true,
              maxLines: 2),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('price_field_label'),
                    const SizedBox(height: 6),
                    _buildTextField(_priceController,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {})),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('category_field_label'),
                    const SizedBox(height: 6),
                    _buildCategoryDropdown(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                TranslationHelper.get('available_label'),
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2E3A59),
                ),
              ),
              Switch(
                value: _exist,
                activeThumbColor: const Color(0xFFFF9800),
                onChanged: (v) => setState(() => _exist = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFieldLabel(String key) => Text(
        TranslationHelper.get(key),
        style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
      );

  Widget _buildTextField(
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboardType,
    int maxLines = 1,
    bool isArabicField = false,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      textDirection: isArabicField ? TextDirection.rtl : TextDirection.ltr,
      onChanged: onChanged,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: Color(0xFF2E3A59),
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w400, color: Color(0xFFC9CDD4)),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        border: const UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFFEDEFF2))),
        enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFFEDEFF2))),
        focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFFFF9800))),
      ),
    );
  }

  Widget _buildCategoryDropdown() {
    if (_categories.isEmpty) {
      return Text(
        TranslationHelper.get('no_categories_message'),
        style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
      );
    }
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _categoryId,
        isExpanded: true,
        icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFFFF9800)),
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Color(0xFF2E3A59),
        ),
        items: [
          for (final cat in _categories)
            DropdownMenuItem(
              value: cat.id,
              child: Text(_isArabic
                  ? (cat.data()['name_ar'] as String? ?? '')
                  : (cat.data()['name_fr'] as String? ?? '')),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _categoryId = v);
        },
      ),
    );
  }

  Widget _buildGroupCard(int groupIndex) {
    final group = _groups[groupIndex];
    return Container(
      padding: const EdgeInsets.all(14),
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
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  group.nameFr,
                  hint: TranslationHelper.get('group_name_fr_hint'),
                ),
              ),
              InkWell(
                onTap: () => _removeGroup(groupIndex),
                child: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.close, size: 18, color: Color(0xFF9AA1AC)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTextField(
            group.nameAr,
            hint: TranslationHelper.get('group_name_ar_hint'),
            isArabicField: true,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('min_selection_label'),
                    const SizedBox(height: 4),
                    _buildTextField(group.min,
                        keyboardType: TextInputType.number),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('max_selection_label'),
                    const SizedBox(height: 4),
                    _buildTextField(group.max,
                        keyboardType: TextInputType.number),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('options_label'),
          const SizedBox(height: 8),
          for (var i = 0; i < group.options.length; i++) ...[
            _buildOptionRow(group, i),
            const SizedBox(height: 8),
          ],
          InkWell(
            onTap: () => _addOption(group),
            child: Text(
              TranslationHelper.get('add_option_link'),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: Color(0xFFFF9800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionRow(_GroupForm group, int optionIndex) {
    final option = group.options[optionIndex];
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: _buildTextField(option.nameFr,
              hint: TranslationHelper.get('option_name_fr_hint')),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 2,
          child: _buildTextField(option.nameAr,
              hint: TranslationHelper.get('option_name_ar_hint'),
              isArabicField: true),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _buildTextField(option.price,
              hint: TranslationHelper.get('price_field_label'),
              keyboardType: TextInputType.number),
        ),
        InkWell(
          onTap: () => _removeOption(group, optionIndex),
          child: const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.close, size: 16, color: Color(0xFF9AA1AC)),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isSaving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF9800),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  )
                : Text(
                    TranslationHelper.get('save_item_button'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ),
    );
  }
}
