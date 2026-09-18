import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// Wraps Google's Directions REST API for an actual road-following route
/// between two points, plus a plain great-circle distance helper for quick
/// estimates that don't need (or can't wait on) a real route.
///
/// Uses the same API key already configured for Maps SDK for Android /
/// GeocodingService - see that class's own note about the Android-app
/// restriction that can apply to it for plain HTTP calls like this one.
class DirectionsService {
  DirectionsService._();

  static const String _apiKey = 'AIzaSyDHR2SWoOAcC1e2-of9wOvSTk-yBIqOF7o';

  /// The road route's own point-by-point path, decoded from Directions'
  /// encoded polyline - null if the request failed or returned no route
  /// (no network, no key access to the Directions API, no route found),
  /// so callers can fall back to a straight line instead of showing nothing.
  static Future<List<LatLng>?> getRoute(LatLng origin, LatLng destination) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      'key': _apiKey,
    });

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        debugPrint('DirectionsService: HTTP ${response.statusCode} - ${response.body}');
        return null;
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      if (decoded['status'] != 'OK') {
        // Surfaced rather than silently swallowed - REQUEST_DENIED here
        // almost always means the Directions API itself isn't enabled for
        // this key/project (a separate toggle from Maps SDK/Geocoding),
        // not a code bug; this print is how to tell the difference.
        debugPrint('DirectionsService: status=${decoded['status']} '
            'error_message=${decoded['error_message']}');
        return null;
      }
      final routes = decoded['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;
      final points = (routes.first as Map<String, dynamic>)['overview_polyline']
          ?['points'] as String?;
      if (points == null) return null;
      return _decodePolyline(points);
    } catch (e) {
      debugPrint('DirectionsService: request failed - $e');
      return null;
    }
  }

  /// Google's standard polyline encoding (used by overview_polyline) -
  /// https://developers.google.com/maps/documentation/utilities/polylinealgorithm
  static List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0;
    var lat = 0;
    var lng = 0;

    while (index < encoded.length) {
      var shift = 0;
      var result = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  /// Straight-line (Haversine) distance in kilometers - used for the offer
  /// card's quick estimate, where a real Directions round trip per offer
  /// isn't worth the latency/cost.
  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusKm = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  static double _deg2rad(double deg) => deg * (pi / 180);
}
