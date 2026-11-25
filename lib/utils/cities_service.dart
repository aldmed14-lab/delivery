import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One delivery city (lib/note.txt LOCATION SYSTEM) - everything else in
/// the app refers to a city by [id].
class CityInfo {
  final String id;
  final String nameAr;
  final String nameFr;

  /// The city's delivery area - a point inside it belongs to this city.
  final List<({double lat, double lng})> polygon;
  final ({double minLat, double maxLat, double minLng, double maxLng}) bbox;

  /// Optional longest store -> address distance allowed in this city.
  final double? maxDeliveryKm;

  const CityInfo({
    required this.id,
    required this.nameAr,
    required this.nameFr,
    required this.polygon,
    required this.bbox,
    required this.maxDeliveryKm,
  });

  String name(String language) => language == 'ar' ? nameAr : nameFr;

  bool _inBbox(double lat, double lng) =>
      lat >= bbox.minLat &&
      lat <= bbox.maxLat &&
      lng >= bbox.minLng &&
      lng <= bbox.maxLng;

  /// Ray casting - same algorithm as the server (handlers/_cities.js).
  bool _inPolygon(double lat, double lng) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final yi = polygon[i].lat, xi = polygon[i].lng;
      final yj = polygon[j].lat, xj = polygon[j].lng;
      if ((yi > lat) != (yj > lat) &&
          lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  bool contains(double lat, double lng) =>
      _inBbox(lat, lng) && _inPolygon(lat, lng);

  /// Shoelace area, only for the "smallest wins" overlap tie-break.
  double get _area {
    var sum = 0.0;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      sum += (polygon[j].lng + polygon[i].lng) *
          (polygon[j].lat - polygon[i].lat);
    }
    return (sum / 2).abs();
  }

  static CityInfo? fromMap(String id, Map<String, dynamic> d) {
    final raw = d['polygon'];
    final box = d['bbox'];
    if (raw is! List || raw.length < 3 || box is! Map) return null;
    return CityInfo(
      id: id,
      nameAr: d['name_ar'] as String? ?? '',
      nameFr: d['name_fr'] as String? ?? '',
      polygon: [
        for (final p in raw)
          (
            lat: ((p as Map)['lat'] as num).toDouble(),
            lng: (p['lng'] as num).toDouble(),
          ),
      ],
      bbox: (
        minLat: (box['min_lat'] as num).toDouble(),
        maxLat: (box['max_lat'] as num).toDouble(),
        minLng: (box['min_lng'] as num).toDouble(),
        maxLng: (box['max_lng'] as num).toDouble(),
      ),
      maxDeliveryKm: (d['max_delivery_km'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name_ar': nameAr,
        'name_fr': nameFr,
        'polygon': [
          for (final p in polygon) {'lat': p.lat, 'lng': p.lng}
        ],
        'bbox': {
          'min_lat': bbox.minLat,
          'max_lat': bbox.maxLat,
          'min_lng': bbox.minLng,
          'max_lng': bbox.maxLng,
        },
        'max_delivery_km': maxDeliveryKm,
      };
}

/// cities/{id}/status/current - whether the city is taking orders right now.
class CityStatus {
  final bool active;
  final String stopReasonAr;
  final String stopReasonFr;
  final DateTime? reopenAt;

  const CityStatus({
    required this.active,
    this.stopReasonAr = '',
    this.stopReasonFr = '',
    this.reopenAt,
  });

  /// A missing status doc = no service (same as the server).
  static CityStatus fromSnapshot(DocumentSnapshot<Map<String, dynamic>> s) {
    final d = s.data();
    if (d == null) return const CityStatus(active: false);
    return CityStatus(
      active: d['active'] == true,
      stopReasonAr: d['stop_reason_ar'] as String? ?? '',
      stopReasonFr: d['stop_reason_fr'] as String? ?? '',
      reopenAt: (d['reopen_at'] as Timestamp?)?.toDate(),
    );
  }

  /// What to show instead of the feed when paused; null when active.
  String? message(String language) {
    if (active) return null;
    final reason = (language == 'ar' ? stopReasonAr : stopReasonFr).trim();
    final base =
        reason.isEmpty ? TranslationHelper.get('no_service_right_now') : reason;
    final reopen = reopenAt;
    if (reopen == null || reopen.isBefore(DateTime.now())) return base;
    final hh = reopen.hour.toString().padLeft(2, '0');
    final mm = reopen.minute.toString().padLeft(2, '0');
    return '$base\n${TranslationHelper.get('service_back_at', {
          'time': '$hh:$mm'
        })}';
  }
}

/// All delivery cities, cached on the phone and downloaded again only when
/// `system/config.cities_version` changes (lib/note.txt). Finds which city a
/// point is in, and reads/watches a city's status.
class CitiesService {
  CitiesService._();
  static final CitiesService instance = CitiesService._();

  static const _prefsVersion = 'cities_version';
  static const _prefsCities = 'cities_json';

  final _db = FirebaseFirestore.instance;
  List<CityInfo> _cities = [];
  Future<bool>? _loading;
  bool _loaded = false;

  List<CityInfo> get cities => List.unmodifiable(_cities);
  bool get isLoaded => _loaded;

  /// Loads the cities (local copy first, network only if the version
  /// changed). Returns true when the cities changed since the last load -
  /// callers then re-check saved addresses against the new polygons.
  /// Safe to call many times; concurrent calls share one load.
  Future<bool> ensureLoaded({bool force = false}) {
    if (_loaded && !force) return Future.value(false);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<bool> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final localVersion = prefs.getInt(_prefsVersion);
    final localJson = prefs.getString(_prefsCities);

    int? remoteVersion;
    try {
      final config = await _db.collection('system').doc('config').get();
      remoteVersion = (config.data()?['cities_version'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Offline - fall back to the local copy if there is one.
    }

    if (localJson != null &&
        (remoteVersion == null || remoteVersion == localVersion)) {
      _cities = _decode(localJson);
      _loaded = true;
      return false;
    }
    if (remoteVersion == null) {
      // Offline and nothing cached - nothing to work with yet.
      throw StateError('cities unavailable offline');
    }

    final snap = await _db.collection('cities').get();
    _cities = snap.docs
        .map((d) => CityInfo.fromMap(d.id, d.data()))
        .whereType<CityInfo>()
        .toList();
    await prefs.setString(
        _prefsCities,
        jsonEncode({
          for (final c in _cities) c.id: c.toMap(),
        }));
    await prefs.setInt(_prefsVersion, remoteVersion);
    _loaded = true;
    return localVersion != null;
  }

  List<CityInfo> _decode(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return map.entries
        .map((e) => CityInfo.fromMap(e.key, e.value as Map<String, dynamic>))
        .whereType<CityInfo>()
        .toList();
  }

  CityInfo? byId(String? id) {
    if (id == null) return null;
    for (final c in _cities) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The city a point is in, or null when it's outside every city. bbox
  /// first, then the polygon; if polygons overlap, the smallest one wins
  /// (same rule as the server).
  CityInfo? resolve(double lat, double lng) {
    final matches = _cities.where((c) => c.contains(lat, lng)).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => a._area.compareTo(b._area));
    return matches.first;
  }

  String cityName(String? id, String language) =>
      byId(id)?.name(language) ?? '';

  DocumentReference<Map<String, dynamic>> _statusRef(String cityId) =>
      _db.collection('cities').doc(cityId).collection('status').doc('current');

  Future<CityStatus> fetchStatus(String cityId) async =>
      CityStatus.fromSnapshot(await _statusRef(cityId).get());

  /// Live status - a pause/reopen shows up without a restart.
  Stream<CityStatus> watchStatus(String cityId) =>
      _statusRef(cityId).snapshots().map(CityStatus.fromSnapshot);

  Future<Map<String, dynamic>?> fetchCityDoc(String cityId) async =>
      (await _db.collection('cities').doc(cityId).get()).data();

  /// Straight-line km - same formula as the server's haversineKm.
  static double distanceKm(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// True when [store] is beyond its max_delivery_km (else its city's)
  /// from the point. No limit set = never too far.
  bool isTooFar(Map<String, dynamic> store, double lat, double lng) {
    final storeLat = (store['lat'] as num?)?.toDouble();
    final storeLng = (store['lng'] as num?)?.toDouble();
    if (storeLat == null || storeLng == null) return false;
    final max = (store['max_delivery_km'] as num?)?.toDouble() ??
        byId(store['city_id'] as String?)?.maxDeliveryKm;
    if (max == null || max <= 0) return false;
    return distanceKm(storeLat, storeLng, lat, lng) > max;
  }
}
