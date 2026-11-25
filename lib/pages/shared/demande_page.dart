import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:flutter_application_1/pages/client/select_location_page.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/geohash.dart';
import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// Which kind of application this form is for - stored as
/// `demandes.demande_type` (`lib/map.txt`) via [name].
enum DemandeType { store, delivery }

/// Application form to become a delivery driver or a store partner - reached
/// from HelpPage's "Devenir livreur" / "Devenir partenaire" answers. Writes
/// one `demandes` doc (`lib/map.txt`) with status "pending"; nothing
/// approves it yet (no admin side exists), this only collects it. Pops
/// `true` once submitted so the caller can confirm to the user.
class DemandePage extends StatefulWidget {
  final String language;
  final DemandeType type;
  const DemandePage(this.language, this.type, {super.key});

  @override
  State<DemandePage> createState() => _DemandePageState();
}

class _DemandePageState extends State<DemandePage> with AlertCardMixin {
  // Hard cap on every uploaded photo, per the application spec. image_picker
  // can only compress at pick time (there's no compression package in this
  // project), so photos are asked for at a small size/quality up front and
  // then checked against this - a photo still over it is rejected with a
  // message, not silently resized.
  static const _maxImageBytes = 150 * 1024;
  static const _networkTimeout = Duration(seconds: 12);
  static const _uploadTimeout = Duration(seconds: 60);
  static const _vehicleTypes = ['motorcycle', 'car', 'bicycle'];

  final _firestore = FirebaseFirestore.instance;
  final _storage = FirebaseStorage.instance;
  final _picker = ImagePicker();
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _cardIdCtrl = TextEditingController();
  final _nameFrCtrl = TextEditingController();
  final _nameArCtrl = TextEditingController();
  final _locationNameCtrl = TextEditingController();

  File? _cardFront;
  File? _cardBack;
  File? _vehicleImage;
  File? _storeImage;

  String? _vehicleType;

  // Delivery picks its city from the list; a store's city comes from the
  // map location it picks (SelectMapPage only accepts an active city).
  // Both are city ids (cities/{id}) - names are only for display.
  List<CityInfo> _cities = [];
  String? _cityId;
  double? _storeLat;
  double? _storeLng;
  String? _storeCityId;

  String _cityNameOf(String? id) =>
      CitiesService.instance.cityName(id, widget.language);

  bool _isLoading = true;
  Object? _loadError;
  bool _hasPending = false;
  bool _isSubmitting = false;

  bool get _isArabic => widget.language == 'ar';
  bool get _isDelivery => widget.type == DemandeType.delivery;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cardIdCtrl.dispose();
    _nameFrCtrl.dispose();
    _nameArCtrl.dispose();
    _locationNameCtrl.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object?>([
        _firestore.collection('users').doc(_uid).get(),
        // One pending application per type at a time - reapplying is only
        // possible once the earlier one has been decided.
        _firestore
            .collection('demandes')
            .where('user_id', isEqualTo: _uid)
            .where('demande_type', isEqualTo: widget.type.name)
            .where('status', isEqualTo: 'pending')
            .limit(1)
            .get(),
        if (_isDelivery) CitiesService.instance.ensureLoaded(),
      ]).timeout(_networkTimeout);
      if (!mounted) return;

      final user =
          (results[0] as DocumentSnapshot<Map<String, dynamic>>).data();
      final pending = results[1] as QuerySnapshot<Map<String, dynamic>>;

      if (_nameCtrl.text.isEmpty)
        _nameCtrl.text = user?['name'] as String? ?? '';
      if (_phoneCtrl.text.isEmpty)
        _phoneCtrl.text = user?['phone'] as String? ?? '';

      if (_isDelivery) {
        _cities = [...CitiesService.instance.cities]..sort((a, b) =>
            a.name(widget.language).compareTo(b.name(widget.language)));
      }

      setState(() {
        _hasPending = pending.docs.isNotEmpty;
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

  // ---------------------------------------------------------------------
  // photos
  // ---------------------------------------------------------------------

  Future<void> _pickImage(void Function(File file) assign) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(TranslationHelper.get('demande_pick_camera')),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(TranslationHelper.get('demande_pick_gallery')),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 45,
      );
      if (picked == null) return;
      final file = File(picked.path);
      if (await file.length() > _maxImageBytes) {
        if (mounted) {
          showAlert(TranslationHelper.get('demande_image_too_large'),
              isError: true);
        }
        return;
      }
      if (!mounted) return;
      setState(() => assign(file));
    } catch (_) {
      if (mounted) showAlert(TranslationHelper.get('error'), isError: true);
    }
  }

  Future<String> _upload(File file, String name) async {
    final ref = _storage.ref('demandes/$_uid/$name.jpg');
    await ref
        .putFile(file, SettableMetadata(contentType: 'image/jpeg'))
        .timeout(_uploadTimeout);
    return ref.getDownloadURL().timeout(_networkTimeout);
  }

  // ---------------------------------------------------------------------
  // store location
  // ---------------------------------------------------------------------

  Future<void> _pickStoreLocation() async {
    final picked = await Navigator.push(
      context,
      MaterialPageRoute(
        // SelectMapPage never saves anything itself - this is the store's
        // location, it never touches the applicant's own addresses.
        builder: (_) => SelectMapPage(widget.language),
      ),
    );
    if (!mounted || picked is! Map || picked['city_id'] == null) return;
    setState(() {
      _storeLat = (picked['lat'] as num).toDouble();
      _storeLng = (picked['lng'] as num).toDouble();
      _storeCityId = picked['city_id'] as String;
    });
  }

  // ---------------------------------------------------------------------
  // submit
  // ---------------------------------------------------------------------

  bool _isValid() {
    if (_nameCtrl.text.trim().isEmpty ||
        _phoneCtrl.text.trim().isEmpty ||
        _cardIdCtrl.text.trim().isEmpty ||
        _cardFront == null ||
        _cardBack == null) {
      return false;
    }
    if (_isDelivery) {
      return _cityId != null && _vehicleType != null && _vehicleImage != null;
    }
    return _storeImage != null &&
        (_nameFrCtrl.text.trim().isNotEmpty ||
            _nameArCtrl.text.trim().isNotEmpty) &&
        _locationNameCtrl.text.trim().isNotEmpty &&
        _storeLat != null &&
        _storeLng != null &&
        _storeCityId != null;
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    if (!_isValid()) {
      showAlert(TranslationHelper.get('demande_fill_required'), isError: true);
      return;
    }
    // Checked up front, not left to the write failing: an offline Firestore
    // write doesn't fail, it just hangs until the connection returns.
    if (!await InternetConnectionService().checkNow()) {
      if (mounted)
        showAlert(TranslationHelper.get('no_internet'), isError: true);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      // urls[2] is the vehicle photo for a driver, the shop photo for a store.
      final urls = await Future.wait([
        _upload(_cardFront!, '${stamp}_card_front'),
        _upload(_cardBack!, '${stamp}_card_back'),
        if (_isDelivery)
          _upload(_vehicleImage!, '${stamp}_vehicle')
        else
          _upload(_storeImage!, '${stamp}_store'),
      ]);

      try {
        await _firestore.collection('demandes').add({
          'user_id': _uid,
          // city_id is what counts; the name is only for display.
          'city_id': _isDelivery ? _cityId : _storeCityId,
          'city_name': _cityNameOf(_isDelivery ? _cityId : _storeCityId),
          'name': _nameCtrl.text.trim(),
          'phone': _phoneCtrl.text.trim(),
          'demande_type': widget.type.name,
          'card_id': _cardIdCtrl.text.trim(),
          'card_front_image': urls[0],
          'card_back_image': urls[1],
          if (_isDelivery)
            'delivery': {
              'vehicle_image': urls[2],
              'vehicle_type': _vehicleType,
            }
          else
            'store': {
              'image': urls[2],
              'name_ar': _nameArCtrl.text.trim(),
              'name_fr': _nameFrCtrl.text.trim(),
              'lat': _storeLat,
              'lng': _storeLng,
              'geohash': Geohash.encode(_storeLat!, _storeLng!),
              'location_name': _locationNameCtrl.text.trim(),
            },
          'status': 'pending',
          'admin_by': null,
          'created_at': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        // The photos above already landed in Storage before this write
        // failed - nothing will ever reference them now (no demandes doc got
        // created), so without this they'd leak forever. Best-effort: a
        // failed delete just leaves a harmless orphan instead of blocking
        // the user on the original failure.
        for (final url in urls) {
          _storage.refFromURL(url).delete().catchError((_) {});
        }
        rethrow;
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

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
              TranslationHelper.get(_isDelivery
                  ? 'demande_title_delivery'
                  : 'demande_title_store'),
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
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_loadError != null) {
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
                onPressed: _bootstrap,
                child: Text(TranslationHelper.get('retry')),
              ),
            ],
          ),
        ),
      );
    }

    if (_hasPending) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            TranslationHelper.get('demande_already_pending'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF2E3A59),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _section('demande_section_personal'),
              _field(_nameCtrl, 'demande_name_label'),
              _field(_phoneCtrl, 'demande_phone_label',
                  keyboardType: TextInputType.phone),
              _field(_cardIdCtrl, 'demande_card_id_label'),
              if (_isDelivery) _cityDropdown(),
              const SizedBox(height: 8),
              _section('demande_section_documents'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _imageTile('demande_card_front_label', _cardFront,
                        () => _pickImage((f) => _cardFront = f)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _imageTile('demande_card_back_label', _cardBack,
                        () => _pickImage((f) => _cardBack = f)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_isDelivery) ..._deliverySection() else ..._storeSection(),
            ],
          ),
        ),
        _buildSubmitBar(),
      ],
    );
  }

  List<Widget> _deliverySection() {
    return [
      _section('demande_section_vehicle'),
      DropdownButtonFormField<String>(
        initialValue: _vehicleType,
        decoration: _decoration('demande_vehicle_type_label'),
        items: [
          for (final v in _vehicleTypes)
            DropdownMenuItem(
              value: v,
              child: Text(TranslationHelper.get('vehicle_type_$v')),
            ),
        ],
        onChanged: (v) => setState(() => _vehicleType = v),
      ),
      const SizedBox(height: 12),
      _imageTile('demande_vehicle_image_label', _vehicleImage,
          () => _pickImage((f) => _vehicleImage = f)),
    ];
  }

  List<Widget> _storeSection() {
    return [
      _section('demande_section_store'),
      _imageTile('demande_store_image_label', _storeImage,
          () => _pickImage((f) => _storeImage = f)),
      const SizedBox(height: 12),
      _field(_nameFrCtrl, 'demande_store_name_fr_label'),
      _field(_nameArCtrl, 'demande_store_name_ar_label'),
      _field(_locationNameCtrl, 'demande_location_name_label'),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _pickStoreLocation,
          icon: Icon(
            _storeCityId == null
                ? Icons.location_on_outlined
                : Icons.check_circle_rounded,
            size: 18,
          ),
          label: Text(
            _storeCityId == null
                ? TranslationHelper.get('demande_pick_location_button')
                : TranslationHelper.get(
                    'demande_location_picked', {'city': _cityNameOf(_storeCityId)}),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: _storeCityId == null
                ? const Color(0xFFFF9800)
                : const Color(0xFF1B8A3E),
            side: BorderSide(
              color: _storeCityId == null
                  ? const Color(0xFFFF9800)
                  : const Color(0xFF1B8A3E),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    ];
  }

  Widget _cityDropdown() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: _cityId,
        decoration: _decoration('demande_city_label'),
        items: [
          for (final c in _cities)
            DropdownMenuItem(value: c.id, child: Text(c.name(widget.language))),
        ],
        onChanged: (v) => setState(() => _cityId = v),
      ),
    );
  }

  InputDecoration _decoration(String labelKey) {
    return InputDecoration(
      labelText: TranslationHelper.get(labelKey),
      labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _section(String key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        TranslationHelper.get(key).toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String labelKey,
      {TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 14),
        decoration: _decoration(labelKey),
      ),
    );
  }

  Widget _imageTile(String labelKey, File? file, VoidCallback onTap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          TranslationHelper.get(labelKey),
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2E3A59),
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: 120,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: file == null
                    ? const Color(0xFFE1E4E9)
                    : const Color(0xFF1B8A3E),
              ),
            ),
            child: file == null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add_a_photo_outlined,
                          color: Color(0xFFFF9800), size: 26),
                      const SizedBox(height: 6),
                      Text(
                        TranslationHelper.get('demande_add_image'),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2E3A59),
                        ),
                      ),
                      Text(
                        TranslationHelper.get('demande_image_hint'),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF9AA1AC)),
                      ),
                    ],
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Image.file(file, fit: BoxFit.cover),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -4)),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _isSubmitting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF9800),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFFFC98A),
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Text(
                  TranslationHelper.get('demande_submit_button'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
        ),
      ),
    );
  }
}
