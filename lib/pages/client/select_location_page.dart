import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../utils/connection.dart';
import '../../utils/connection_ui.dart';
import '../../utils/geohash.dart';
import '../../utils/point_in_polygon.dart';
import '../../utils/translation_helper.dart';

class _Area {
  final String name;
  final List<LatLng> boundary;

  _Area({required this.name, required this.boundary});
}

/// Lets the user pick their delivery location: the map opens centered on
/// their real position (if available), they pan the map to move a fixed
/// center pin. As soon as the map settles (camera idle - no button needed),
/// the pinned point is checked automatically:
///   1. which (if any) polygon in the top-level `areas` collection contains
///      the point - purely local geometry, no network call per move;
///   2. whether that area's name matches an active document in `cities`
///      (name == area.name && active == true) - also checked against a
///      locally cached set, loaded once up front.
/// The button only ever saves an already-validated location; it never
/// re-checks anything itself. To add a new servicable area later: draw and
/// name a polygon matching an existing (or new) `cities.name`, add it to
/// the `areas` collection - nothing else in this file needs to change.
class SelectMapPage extends StatefulWidget {
  final String language;

  /// When false (the default) - first-time setup, where the caller has no
  /// usable location yet - the back arrow and system back gesture/button are
  /// both disabled. The only way out is picking a valid, serviced location.
  /// Pass true when the user already has a saved location and is just
  /// choosing to change it, so backing out without changing anything is
  /// fine.
  final bool canCancel;

  const SelectMapPage(this.language, {this.canCancel = false, super.key});

  @override
  State<SelectMapPage> createState() => _SelectMapPageState();
}

enum _CheckStatus { checking, valid, invalid }

class _SelectMapPageState extends State<SelectMapPage> {
  // Nouakchott, Mauritania - used only as a fallback when the device's real
  // location can't be determined (permission denied, GPS off, etc.).
  static const LatLng _fallbackCenter = LatLng(18.0735, -15.9582);

  GoogleMapController? _mapController;
  LatLng _center = _fallbackCenter;
  bool _isPreparing = true; // determining position + loading areas/cities
  bool _isSaving = false;

  List<_Area> _areas = [];
  Set<String> _activeCityNames = {};
  bool _loadFailed = false;

  _CheckStatus _checkStatus = _CheckStatus.checking;
  String? _resolvedCity;
  String _checkMessage = '';

  // Loaded once from assets/map_style.json and cached - starts null and the
  // map renders with the default Google style until it's ready.
  String? _mapStyle;

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _initialize();
    _loadMapStyle();
  }

  Future<void> _loadMapStyle() async {
    try {
      final style = await rootBundle.loadString('assets/map_style.json');
      if (mounted) setState(() => _mapStyle = style);
    } catch (_) {
      // Falls back to the default Google style - not worth failing the
      // page over cosmetic map styling.
    }
  }

  Future<void> _initialize() async {
    await Future.wait([_determineInitialPosition(), _loadAreasAndCities()]);
    if (mounted) {
      setState(() => _isPreparing = false);
      _checkCurrentLocation();
    }
  }

  Future<void> _determineInitialPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted) return;
      _center = LatLng(position.latitude, position.longitude);
      _mapController?.moveCamera(CameraUpdate.newLatLng(_center));
    } catch (_) {
      // Keep the fallback center - not worth blocking the picker over this.
    }
  }

  /// Loads every drawn area's polygon and every active city's name once, up
  /// front, so the actual on-map check (see [_checkCurrentLocation]) is pure
  /// in-memory lookups - no network call, no cost, on every camera-idle
  /// event.
  Future<void> _loadAreasAndCities() async {
    try {
      final results = await Future.wait([
        FirebaseFirestore.instance.collection('areas').get(),
        FirebaseFirestore.instance
            .collection('cities')
            .where('active', isEqualTo: true)
            .get(),
      ]);
      final areasSnapshot = results[0];
      final citiesSnapshot = results[1];

      final areas = <_Area>[];
      for (final doc in areasSnapshot.docs) {
        final data = doc.data();
        final name = data['name'] as String?;
        final boundaryRaw = data['boundary'] as List?;
        if (name == null || boundaryRaw == null || boundaryRaw.length < 3) {
          continue;
        }
        final boundary = boundaryRaw
            .map((p) => LatLng(
                  ((p as Map)['lat'] as num).toDouble(),
                  (p['lng'] as num).toDouble(),
                ))
            .toList();
        areas.add(_Area(name: name, boundary: boundary));
      }

      final activeCityNames = citiesSnapshot.docs
          .map((doc) => doc.data()['name'] as String?)
          .whereType<String>()
          .toSet();

      if (mounted) {
        _areas = areas;
        _activeCityNames = activeCityNames;
      }
    } catch (_) {
      _loadFailed = true;
    }
  }

  /// Runs automatically whenever the map stops moving (see `onCameraIdle`
  /// below) and once right after setup finishes. Purely informational and
  /// purely local - it never saves anything, just tells the user whether
  /// the pinned point is somewhere the confirm button will actually accept.
  void _checkCurrentLocation() {
    if (_loadFailed) {
      setState(() {
        _checkStatus = _CheckStatus.invalid;
        _checkMessage = TranslationHelper.get('no_internet');
      });
      return;
    }

    for (final area in _areas) {
      if (PointInPolygon.contains(_center, area.boundary)) {
        if (_activeCityNames.contains(area.name)) {
          setState(() {
            _checkStatus = _CheckStatus.valid;
            _resolvedCity = area.name;
          });
        } else {
          // The zone is drawn, but there's no matching active `cities` doc
          // yet - treat it the same as "not serviced" rather than silently
          // accepting it.
          setState(() {
            _checkStatus = _CheckStatus.invalid;
            _resolvedCity = null;
            _checkMessage = TranslationHelper.get('city_not_available');
          });
        }
        return;
      }
    }

    setState(() {
      _checkStatus = _CheckStatus.invalid;
      _resolvedCity = null;
      _checkMessage = TranslationHelper.get('city_not_available');
    });
  }

  Future<void> _saveLocation() async {
    if (_isSaving ||
        _checkStatus != _CheckStatus.valid ||
        _resolvedCity == null) {
      return;
    }
    setState(() => _isSaving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
          {
            'address': {
              'lat': _center.latitude,
              'lng': _center.longitude,
              'city': _resolvedCity,
              'geohash': Geohash.encode(_center.latitude, _center.longitude),
            },
          },
          SetOptions(merge: true),
        );
      }

      if (mounted) {
        Navigator.of(context).pop({
          'lat': _center.latitude,
          'lng': _center.longitude,
          'city': _resolvedCity,
        });
      }
    } catch (e) {
      if (mounted) {
        ConnectionDialog.show(
          context,
          language: widget.language,
          message: TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Custom teardrop pin (matches the design reference) instead of a stock
  /// Material icon - orange gradient while checking/valid, grey once
  /// confirmed invalid, so its color alone previews the outcome.
  Widget _buildPin() {
    final active = _checkStatus != _CheckStatus.invalid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: -45 * math.pi / 180,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: active
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
                    )
                  : null,
              color: active ? null : const Color(0xFF9AA1AC),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(23),
                topRight: Radius.circular(23),
                bottomRight: Radius.circular(23),
              ),
              boxShadow: [
                BoxShadow(
                  color: (active ? const Color(0xFFFF9800) : Colors.black)
                      .withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: Transform.rotate(
                angle: 45 * math.pi / 180,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -6),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackButton() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: widget.canCancel ? () => Navigator.of(context).maybePop() : null,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 12,
            ),
          ],
        ),
        child: Icon(
          _isArabic ? Icons.arrow_forward : Icons.arrow_back,
          color: widget.canCancel
              ? const Color(0xFF2E3A59)
              : const Color(0xFFC9CDD4),
          size: 18,
        ),
      ),
    );
  }

  /// Rounded-top white card: icon-in-circle whose color/icon reflects
  /// [_checkStatus], a two-line status text, and a full-width CTA that's
  /// gradient-orange only once a valid location is confirmed.
  Widget _buildBottomSheet() {
    late final Color iconBg;
    late final Color iconColor;
    late final Widget iconGlyph;
    late final String title;
    late final String subtitle;
    late final Color subtitleColor;

    switch (_checkStatus) {
      case _CheckStatus.checking:
        iconBg = const Color(0xFFFFF3E0);
        iconColor = const Color(0xFFFF9800);
        iconGlyph = SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: iconColor),
        );
        title = TranslationHelper.get('checking_location');
        subtitle = '';
        subtitleColor = const Color(0xFF9AA1AC);
        break;
      case _CheckStatus.valid:
        iconBg = const Color(0xFFE6F7EA);
        iconColor = const Color(0xFF1B8A3E);
        iconGlyph = Icon(Icons.check, color: iconColor, size: 22);
        title = _resolvedCity ?? '';
        subtitle = TranslationHelper.get('zone_serviced');
        subtitleColor = iconColor;
        break;
      case _CheckStatus.invalid:
        iconBg = const Color(0xFFFDF1F0);
        iconColor = const Color(0xFFE74C3C);
        iconGlyph = Text(
          '!',
          style: TextStyle(
              color: iconColor, fontWeight: FontWeight.w800, fontSize: 16),
        );
        title = TranslationHelper.get('zone_not_serviced');
        subtitle = _checkMessage;
        subtitleColor = iconColor;
        break;
    }

    final canSave = _checkStatus == _CheckStatus.valid && !_isSaving;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 24,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(child: iconGlyph),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2E3A59),
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: canSave ? _saveLocation : null,
            child: Container(
              width: double.infinity,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: canSave
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
                      )
                    : null,
                color: canSave ? null : const Color(0xFFE5E8ED),
                borderRadius: BorderRadius.circular(15),
                boxShadow: canSave
                    ? [
                        BoxShadow(
                          color:
                              const Color(0xFFFF9800).withValues(alpha: 0.35),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      TranslationHelper.get('confirm_location'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: canSave ? Colors.white : const Color(0xFF9AA1AC),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.canCancel,
      child: Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          body: _isPreparing
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: _center,
                        zoom: 15,
                      ),
                      onMapCreated: (controller) => _mapController = controller,
                      style: _mapStyle,
                      onCameraMove: (position) => _center = position.target,
                      onCameraIdle: _checkCurrentLocation,
                      myLocationEnabled: true,
                      myLocationButtonEnabled: true,
                      zoomControlsEnabled: false,
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildBackButton(),
                      ),
                    ),
                    // Fixed center pin - the map moves underneath it, its tip
                    // (not its visual center) marks the chosen point.
                    Align(
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 40),
                        child: _buildPin(),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SafeArea(
                        top: false,
                        child: _buildBottomSheet(),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
