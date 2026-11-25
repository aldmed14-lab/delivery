import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:geolocator/geolocator.dart';

enum CityResolveStatus {
  /// The device position fell inside a city's polygon.
  resolved,

  /// A device position was obtained, but it isn't inside any city.
  outOfZone,

  /// No device position could be obtained at all (GPS off, permission
  /// denied, the request failed/timed out), or the cities couldn't load.
  unavailable,
}

class CityResolveResult {
  final CityResolveStatus status;
  final String? cityId;
  final double? lat;
  final double? lng;

  const CityResolveResult._(this.status, {this.cityId, this.lat, this.lng});

  factory CityResolveResult.resolved(String cityId, double lat, double lng) =>
      CityResolveResult._(CityResolveStatus.resolved,
          cityId: cityId, lat: lat, lng: lng);

  factory CityResolveResult.outOfZone(double lat, double lng) =>
      CityResolveResult._(CityResolveStatus.outOfZone, lat: lat, lng: lng);

  factory CityResolveResult.unavailable() =>
      const CityResolveResult._(CityResolveStatus.unavailable);
}

/// "Which city is the device in right now" - device GPS, then the cached
/// city polygons ([CitiesService]). Only says which city the point is in;
/// whether that city is taking orders right now is its status doc, checked
/// by the caller.
class CityResolver {
  CityResolver._();

  /// Null when location can be used; otherwise the translation key of the
  /// reason (GPS off / permission refused). Asks for permission if it was
  /// never answered.
  static Future<String?> locationProblem() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return 'location_service_off';
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return 'location_permission_required';
      }
      return null;
    } catch (_) {
      return 'location_permission_required';
    }
  }

  /// The device position, or null (GPS off, permission denied, timeout).
  /// [requestPermission] false = only if permission was ALREADY granted -
  /// for silent background checks that must never pop a permission dialog.
  static Future<Position?> devicePosition({bool requestPermission = true}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      // A last-known fix is near-instant but can be stale (minutes/hours
      // old) - only trust a fresh one, else get a real fix.
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null &&
          DateTime.now().difference(lastKnown.timestamp) <
              const Duration(minutes: 2)) {
        return lastKnown;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  static Future<CityResolveResult> resolveFromDevice(
      {bool requestPermission = true}) async {
    final position =
        await devicePosition(requestPermission: requestPermission);
    if (position == null) return CityResolveResult.unavailable();
    try {
      await CitiesService.instance.ensureLoaded();
    } catch (_) {
      return CityResolveResult.unavailable();
    }
    final city = CitiesService.instance
        .resolve(position.latitude, position.longitude);
    if (city == null) {
      return CityResolveResult.outOfZone(
          position.latitude, position.longitude);
    }
    return CityResolveResult.resolved(
        city.id, position.latitude, position.longitude);
  }
}
