import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../utils/cities_service.dart';
import '../../utils/city_resolver.dart';
import '../../utils/translation_helper.dart';

/// Pick a point on the map (lib/note.txt LOCATION SYSTEM "map picker"): the
/// user pans the map under a fixed center pin. When the map settles, the
/// point is checked against the cached city polygons ([CitiesService]):
///   - inside an active city  -> green, city name, [Confirm]
///   - inside a paused city   -> grey, the city's stop reason
///   - outside every city     -> grey, "we don't deliver here yet"
/// Only polygons are checked locally; a city's status is read once per city
/// and remembered while the page is open.
///
/// This page never saves anything: it pops `{lat, lng, city_id}` for the
/// caller to save (or null when backed out).
class SelectMapPage extends StatefulWidget {
  final String language;

  /// When false - first-time setup with no usable location yet - the back
  /// arrow and system back are disabled; the only way out is a valid pick.
  final bool canCancel;

  /// Where the map opens. Null = the device's GPS position if available,
  /// else one fixed default point.
  final LatLng? initialPoint;

  const SelectMapPage(
    this.language, {
    this.canCancel = true,
    this.initialPoint,
    super.key,
  });

  @override
  State<SelectMapPage> createState() => _SelectMapPageState();
}

enum _CheckStatus { checking, valid, invalid }

class _SelectMapPageState extends State<SelectMapPage> {
  // Nouakchott - only when there's no initial point and no GPS.
  static const LatLng _fallbackCenter = LatLng(18.0735, -15.9582);

  LatLng _center = _fallbackCenter;
  bool _isPreparing = true;
  bool _loadFailed = false;

  _CheckStatus _checkStatus = _CheckStatus.checking;
  String? _resolvedCity; // display name
  String? _resolvedCityId;
  String _checkMessage = '';

  /// cityId -> status, read once per city while this page is open.
  final Map<String, CityStatus> _statusCache = {};
  int _checkRequestId = 0;

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
      // Default Google style - not worth failing the page over.
    }
  }

  Future<void> _initialize() async {
    await Future.wait([_determineInitialPosition(), _loadCities()]);
    if (mounted) {
      setState(() => _isPreparing = false);
      _checkCurrentLocation();
    }
  }

  Future<void> _determineInitialPosition() async {
    final initial = widget.initialPoint;
    if (initial != null) {
      _center = initial;
      return;
    }
    final position = await CityResolver.devicePosition();
    if (position != null && mounted) {
      _center = LatLng(position.latitude, position.longitude);
    }
  }

  Future<void> _loadCities() async {
    try {
      await CitiesService.instance.ensureLoaded();
    } catch (_) {
      _loadFailed = true;
    }
  }

  /// Runs whenever the map stops moving, and once after setup. Never saves
  /// anything - it only tells the user whether [Confirm] will accept the
  /// pinned point.
  Future<void> _checkCurrentLocation() async {
    if (_loadFailed) {
      setState(() {
        _checkStatus = _CheckStatus.invalid;
        _checkMessage = TranslationHelper.get('no_internet');
      });
      return;
    }

    final requestId = ++_checkRequestId;
    final city =
        CitiesService.instance.resolve(_center.latitude, _center.longitude);
    if (city == null) {
      setState(() {
        _checkStatus = _CheckStatus.invalid;
        _resolvedCity = null;
        _resolvedCityId = null;
        _checkMessage = TranslationHelper.get('city_not_available');
      });
      return;
    }

    var status = _statusCache[city.id];
    if (status == null) {
      setState(() => _checkStatus = _CheckStatus.checking);
      try {
        status = await CitiesService.instance.fetchStatus(city.id);
        _statusCache[city.id] = status;
      } catch (_) {
        if (!mounted || requestId != _checkRequestId) return;
        setState(() {
          _checkStatus = _CheckStatus.invalid;
          _checkMessage = TranslationHelper.get('no_internet');
        });
        return;
      }
    }
    // The map moved again while the status was loading.
    if (!mounted || requestId != _checkRequestId) return;

    final stopMessage = status.message(widget.language);
    setState(() {
      _resolvedCity = city.name(widget.language);
      if (stopMessage == null) {
        _checkStatus = _CheckStatus.valid;
        _resolvedCityId = city.id;
      } else {
        _checkStatus = _CheckStatus.invalid;
        _resolvedCityId = null;
        // One line in the sheet: the reopen time goes on the same line.
        _checkMessage = stopMessage.replaceAll('\n', ' ');
      }
    });
  }

  // Kept as a field for the bottom sheet's spinner state.
  final bool _isSaving = false;

  void _saveLocation() {
    if (_checkStatus != _CheckStatus.valid || _resolvedCityId == null) return;
    Navigator.of(context).pop({
      'lat': _center.latitude,
      'lng': _center.longitude,
      'city_id': _resolvedCityId,
    });
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
