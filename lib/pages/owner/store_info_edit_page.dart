import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:flutter_application_1/widgets/discard_changes_dialog.dart';

/// Same vocabulary home_page.dart filters stores by (`tags`, arrayContains) -
/// picking from anything outside this list would make a store unreachable
/// by every category filter on the client.
const _availableTags = [
  'fast food',
  'pizza',
  'coffee',
  'desserts',
  'burger',
  'shawerma',
  'kebab',
  'fish',
  'healthy',
  'drinks',
];
const _maxTags = 3;

/// Owner-editable store profile: name (both languages), category tags (up
/// to 3, not exactly 3), minimum order, and the store's own address pin.
class StoreInfoEditPage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreInfoEditPage(this.language, this.storeId, {super.key});

  @override
  State<StoreInfoEditPage> createState() => _StoreInfoEditPageState();
}

class _StoreInfoEditPageState extends State<StoreInfoEditPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _nameFrController = TextEditingController();
  final _nameArController = TextEditingController();
  final _minOrderController = TextEditingController();

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isUploadingImage = false;
  Object? _loadError;
  String _image = '';
  final Set<String> _selectedTags = {};
  double? _lat;
  double? _lng;
  String _locationName = '';
  /// stores.city_id - fixed (set by the admin page); a pin edit can't move
  /// the store to another city.
  String _storeCityId = '';

  // Snapshot of what's actually saved, so a stray back-tap with unsaved
  // edits can be caught instead of silently discarding them - refreshed
  // both right after _load() and after a successful _save().
  String _savedNameFr = '';
  String _savedNameAr = '';
  String _savedImage = '';
  int _savedMinOrder = 0;
  Set<String> _savedTags = {};
  double? _savedLat;
  double? _savedLng;
  String _savedLocationName = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameFrController.dispose();
    _nameArController.dispose();
    _minOrderController.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final snap =
          await _firestore.collection('stores').doc(widget.storeId).get();
      if (!snap.exists) {
        if (!mounted) return;
        setState(() {
          _loadError = StateError('store-not-found');
          _isLoading = false;
        });
        return;
      }
      final data = snap.data()!;
      _nameFrController.text = data['name_fr'] as String? ?? '';
      _nameArController.text = data['name_ar'] as String? ?? '';
      _minOrderController.text =
          ((data['min_order_price'] as num?)?.toInt() ?? 0).toString();

      if (!mounted) return;
      setState(() {
        _image = data['image'] as String? ?? '';
        _selectedTags
          ..clear()
          ..addAll(
              ((data['tags'] as List?) ?? const []).map((t) => t.toString()));
        _lat = (data['lat'] as num?)?.toDouble();
        _lng = (data['lng'] as num?)?.toDouble();
        _locationName = data['location_name'] as String? ?? '';
        _storeCityId = data['city_id'] as String? ?? '';
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

  void _syncSavedSnapshot() {
    _savedNameFr = _nameFrController.text.trim();
    _savedNameAr = _nameArController.text.trim();
    _savedImage = _image;
    _savedMinOrder = int.tryParse(_minOrderController.text.trim()) ?? 0;
    _savedTags = Set.of(_selectedTags);
    _savedLat = _lat;
    _savedLng = _lng;
    _savedLocationName = _locationName;
  }

  bool _hasUnsavedChanges() {
    if (_isLoading || _loadError != null) return false;
    final minOrder = int.tryParse(_minOrderController.text.trim()) ?? 0;
    return _nameFrController.text.trim() != _savedNameFr ||
        _nameArController.text.trim() != _savedNameAr ||
        _image != _savedImage ||
        minOrder != _savedMinOrder ||
        _selectedTags.length != _savedTags.length ||
        !_selectedTags.containsAll(_savedTags) ||
        _lat != _savedLat ||
        _lng != _savedLng ||
        _locationName != _savedLocationName;
  }

  Future<void> _handleBack() async {
    if (!_hasUnsavedChanges()) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await confirmDiscardChanges(context, isArabic: _isArabic);
    if (discard && mounted) Navigator.of(context).pop();
  }

  // Toggles a tag on/off - the cap only ever blocks ADDING a 4th, removing
  // one (even down to 0) is always allowed, since the spec here is "at
  // most 3", not "exactly 3".
  void _toggleTag(String tag) {
    if (_selectedTags.contains(tag)) {
      setState(() => _selectedTags.remove(tag));
      return;
    }
    if (_selectedTags.length >= _maxTags) {
      showAlert(TranslationHelper.get('max_categories_message'), isError: true);
      return;
    }
    setState(() => _selectedTags.add(tag));
  }

  Future<void> _editLocation() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // A modal bottom sheet's default drag-to-dismiss listens for vertical
      // drags anywhere over its content, including the map - so a swipe
      // meant to pan the map was instead winning the gesture arena and
      // moving/dismissing the sheet. There's no separate close button, but
      // tapping the scrim outside the sheet still dismisses it.
      enableDrag: false,
      builder: (_) => _LocationEditSheet(
        language: widget.language,
        initialLat: _lat,
        initialLng: _lng,
        initialLocationName: _locationName,
        currentCityId: _storeCityId,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _lat = result['lat'] as double?;
      _lng = result['lng'] as double?;
      _locationName = result['location_name'] as String? ?? _locationName;
    });
  }

  /// Same pattern as store_item_edit_page.dart's own `_pickImage`: uploads
  /// right away (so the preview updates immediately) under a fresh id -
  /// never a fixed "profile.jpg" path, which would fight the CDN/image
  /// cache on every re-upload - but only actually lands in Firestore once
  /// `_save()` commits, same as every other field on this page. The old
  /// image (if any) is left in Storage rather than deleted here, for the
  /// same reason: it's still the live value until _save() commits.
  // Same cap as demande_page.dart's ID/vehicle/store-application photos -
  // kept consistent across every image upload in the app rather than each
  // page inventing its own limit.
  static const _maxImageBytes = 150 * 1024;

  Future<void> _pickImage() async {
    if (_isUploadingImage) return;
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 45,
        maxWidth: 1024,
      );
    } catch (e) {
      showAlert(TranslationHelper.get('error'), isError: true);
      return;
    }
    if (picked == null) return;
    if (await File(picked.path).length() > _maxImageBytes) {
      showAlert(TranslationHelper.get('demande_image_too_large'),
          isError: true);
      return;
    }

    setState(() => _isUploadingImage = true);
    try {
      final online = await InternetConnectionService().checkNow();
      if (!online) throw Exception('offline');
      final ref = FirebaseStorage.instance
          .ref('stores/${widget.storeId}/profile/${const Uuid().v4()}.jpg');
      await ref.putFile(File(picked.path));
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() => _image = url);
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final nameFr = _nameFrController.text.trim();
    if (nameFr.isEmpty) {
      showAlert(TranslationHelper.get('store_name_required'), isError: true);
      return;
    }
    final minOrder = int.tryParse(_minOrderController.text.trim()) ?? 0;

    setState(() => _isSaving = true);
    try {
      await _firestore.collection('stores').doc(widget.storeId).update({
        'name_fr': nameFr,
        'name_ar': _nameArController.text.trim(),
        'image': _image,
        'tags': _selectedTags.toList(),
        'min_order_price': minOrder,
        if (_lat != null) 'lat': _lat,
        if (_lng != null) 'lng': _lng,
        'location_name': _locationName,
      });
      // Only after the Firestore write actually lands - _savedImage still
      // holds the URL that was live before this save. A re-upload already
      // replaced it in Storage with a new file (see _pickImage), so the old
      // one is now unreferenced by anything and would otherwise leak
      // forever. Best-effort: a failed delete just leaves a harmless orphan.
      if (_savedImage.isNotEmpty && _savedImage != _image) {
        FirebaseStorage.instance
            .refFromURL(_savedImage)
            .delete()
            .catchError((_) {});
      }
      _syncSavedSnapshot();
      if (mounted) showAlert(TranslationHelper.get('changes_saved'));
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
          Expanded(
            child: Text(
              TranslationHelper.get('store_info_edit_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _isUploadingImage ? null : _pickImage,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(20),
              ),
              child: _isUploadingImage
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      TranslationHelper.get('change_image_button'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
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
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _image.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: _image,
                        fit: BoxFit.cover,
                        placeholder: (c, u) =>
                            Container(color: Colors.grey[200]),
                        errorWidget: (c, u, e) => _buildImagePlaceholder(),
                      )
                    : _buildImagePlaceholder(),
                if (_isUploadingImage)
                  Container(
                    color: Colors.black.withValues(alpha: 0.35),
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        _buildSectionLabel('details_section_label'),
        const SizedBox(height: 10),
        Container(
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
              _buildFieldLabel('store_name_fr_label'),
              const SizedBox(height: 6),
              _buildTextField(_nameFrController),
              const SizedBox(height: 16),
              _buildFieldLabel('store_name_ar_label'),
              const SizedBox(height: 6),
              _buildTextField(_nameArController, isArabicField: true),
              const SizedBox(height: 16),
              _buildFieldLabel('category_label'),
              const SizedBox(height: 8),
              _buildTagPicker(),
              const SizedBox(height: 16),
              _buildFieldLabel('min_order_price_label'),
              const SizedBox(height: 6),
              _buildTextField(_minOrderController,
                  keyboardType: TextInputType.number,
                  suffix: TranslationHelper.get('currency_unit')),
            ],
          ),
        ),
        const SizedBox(height: 22),
        _buildSectionLabel('address_section_label'),
        const SizedBox(height: 10),
        _buildAddressCard(),
      ],
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      color: const Color(0xFFEDEFF2),
      child: const Center(
        child: Icon(Icons.image_outlined, size: 36, color: Color(0xFFC9CDD4)),
      ),
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

  Widget _buildFieldLabel(String key) => Text(
        TranslationHelper.get(key),
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFF9AA1AC),
        ),
      );

  Widget _buildTextField(
    TextEditingController controller, {
    TextInputType? keyboardType,
    String? suffix,
    bool isArabicField = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textDirection: isArabicField ? TextDirection.rtl : TextDirection.ltr,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: Color(0xFF2E3A59),
      ),
      decoration: InputDecoration(
        isDense: true,
        suffixText: suffix,
        suffixStyle: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
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

  Widget _buildTagPicker() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tag in _availableTags)
          _buildTagChip(tag, _selectedTags.contains(tag)),
      ],
    );
  }

  Widget _buildTagChip(String tag, bool selected) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _toggleTag(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFF9800) : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(20),
          border: selected ? null : Border.all(color: const Color(0xFFE1E4E9)),
        ),
        child: Text(
          TranslationHelper.get(tag),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : const Color(0xFF677489),
          ),
        ),
      ),
    );
  }

  Widget _buildAddressCard() {
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
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Color(0xFFFFF3E0),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.location_on,
                color: Color(0xFFFF9800), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildFieldLabel('location_name_label'),
                const SizedBox(height: 3),
                Text(
                  _locationName.isNotEmpty
                      ? _locationName
                      : TranslationHelper.get('not_set'),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2E3A59),
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _editLocation,
            child: Text(
              TranslationHelper.get('modify_button'),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFFFF9800),
              ),
            ),
          ),
        ],
      ),
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
                    TranslationHelper.get('save_changes_button'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Self-contained pin-on-map + name editor for the store's own address -
/// unlike SelectMapPage (built for a *user's delivery* address, tightly
/// coupled to writing straight into `users/{uid}`), a store's city is
/// already fixed (`stores.city`, set at onboarding) and never gets updated
/// from here - it only ever adjusts where exactly the pin sits and its
/// label, and hands the result back to the caller rather than saving
/// anything itself, so it's part of the same single "Enregistrer les
/// modifications" commit as the rest of the form. It DOES still validate
/// against the same city polygons SelectMapPage uses (CitiesService), purely to
/// block confirming a point outside the store's own serviced city - a
/// store moving to a different city is a decision for an admin, not
/// something this form can silently apply.
class _LocationEditSheet extends StatefulWidget {
  final String language;
  final double? initialLat;
  final double? initialLng;
  final String initialLocationName;
  final String currentCityId;

  const _LocationEditSheet({
    required this.language,
    required this.initialLat,
    required this.initialLng,
    required this.initialLocationName,
    required this.currentCityId,
  });

  @override
  State<_LocationEditSheet> createState() => _LocationEditSheetState();
}

class _LocationEditSheetState extends State<_LocationEditSheet> {
  static const _fallbackCenter = LatLng(18.0735, -15.9582);

  late final TextEditingController _nameController =
      TextEditingController(text: widget.initialLocationName);
  late LatLng _center = (widget.initialLat != null && widget.initialLng != null)
      ? LatLng(widget.initialLat!, widget.initialLng!)
      : _fallbackCenter;

  bool _areasLoaded = false;
  String? _errorMessage;
  bool _isChecking = false;

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _loadAreas();
  }

  /// Same city polygons SelectMapPage checks against (cached on the phone).
  Future<void> _loadAreas() async {
    try {
      await CitiesService.instance.ensureLoaded();
    } catch (_) {
      // No cities -> _confirm finds no city and blocks confirming rather
      // than silently accepting an unchecked point.
    } finally {
      if (mounted) setState(() => _areasLoaded = true);
    }
  }

  void _confirm() {
    if (!_areasLoaded) return;
    setState(() => _isChecking = true);

    final resolved =
        CitiesService.instance.resolve(_center.latitude, _center.longitude);
    if (resolved == null) {
      setState(() {
        _isChecking = false;
        _errorMessage = TranslationHelper.get('city_not_available');
      });
      return;
    }
    if (widget.currentCityId.isNotEmpty &&
        resolved.id != widget.currentCityId) {
      setState(() {
        _isChecking = false;
        _errorMessage =
            TranslationHelper.get('location_city_changed_call_admin');
      });
      return;
    }

    Navigator.of(context).pop({
      'lat': _center.latitude,
      'lng': _center.longitude,
      'location_name': _nameController.text.trim(),
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        height: 260,
                        child: GoogleMap(
                          initialCameraPosition:
                              CameraPosition(target: _center, zoom: 15),
                          onCameraMove: (pos) {
                            _center = pos.target;
                            // Stale once the pin has moved - re-checked fresh
                            // on the next confirm tap.
                            if (_errorMessage != null) {
                              setState(() => _errorMessage = null);
                            }
                          },
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                        ),
                      ),
                    ),
                    const IgnorePointer(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 32),
                          child: Icon(Icons.location_on,
                              size: 40, color: Color(0xFFFF9800)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: TranslationHelper.get('location_name_label'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFE53935),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: (!_areasLoaded || _isChecking) ? null : _confirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9800),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      TranslationHelper.get('confirm_button'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

