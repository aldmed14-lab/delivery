import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'point_in_polygon.dart';

enum CityResolveStatus {
  /// The device position fell inside an active city's zone.
  resolved,

  /// A device position was obtained, but it isn't inside any active city's
  /// zone.
  outOfZone,

  /// No device position could be obtained at all (GPS off, permission
  /// denied, or the position request failed/timed out).
  unavailable,
}

class CityResolveResult {
  final CityResolveStatus status;
  final String? city;
  final double? lat;
  final double? lng;

  CityResolveResult._(this.status, {this.city, this.lat, this.lng});

  factory CityResolveResult.resolved(String city, double lat, double lng) =>
      CityResolveResult._(CityResolveStatus.resolved,
          city: city, lat: lat, lng: lng);

  factory CityResolveResult.outOfZone() =>
      CityResolveResult._(CityResolveStatus.outOfZone);

  factory CityResolveResult.unavailable() =>
      CityResolveResult._(CityResolveStatus.unavailable);
}

/// Silently resolves "which serviced city is the device currently in".
///
/// Uses the exact same source of truth as [SelectMapPage]'s manual map-pin
/// flow - the top-level `areas` collection's drawn polygons, matched by
/// name against active `cities` documents - so a point that the map picker
/// accepts can never be rejected here (and vice versa). `cities.boundary`
/// is not used: in this app's actual data the zone polygons live in
/// `areas`, not on the city document itself.
class CityResolver {
  CityResolver._();

  static Future<Position?> _devicePosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      // A cached last-known fix is near-instant, but it can be stale
      // (sometimes minutes/hours old, occasionally a platform default from
      // a totally different place) - trusting it blindly caused this to
      // report "outside every zone" for users who were actually inside
      // one, since the device had since moved. Only use it if it's fresh
      // enough to actually reflect where the device is right now; anything
      // older falls through to a real fix, same as [SelectMapPage].
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null &&
          DateTime.now().difference(lastKnown.timestamp) <
              const Duration(minutes: 2)) {
        return lastKnown;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  static Future<CityResolveResult> resolveFromDevice() async {
    final position = await _devicePosition();
    if (position == null) return CityResolveResult.unavailable();
    final point = LatLng(position.latitude, position.longitude);

    try {
      final results = await Future.wait([
        FirebaseFirestore.instance.collection('areas').get(),
        FirebaseFirestore.instance
            .collection('cities')
            .where('active', isEqualTo: true)
            .get(),
      ]);
      final areasSnapshot = results[0];
      final activeCityNames = results[1]
          .docs
          .map((doc) => doc.data()['name'] as String?)
          .whereType<String>()
          .toSet();

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
        if (PointInPolygon.contains(point, boundary)) {
          if (!activeCityNames.contains(name)) break;
          return CityResolveResult.resolved(
              name, position.latitude, position.longitude);
        }
      }
    } catch (_) {
      // Firestore read failed - unknown, not "confirmed outside every
      // zone", so don't show the more specific out-of-zone message for it.
      return CityResolveResult.unavailable();
    }
    return CityResolveResult.outOfZone();
  }
}
