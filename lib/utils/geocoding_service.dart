import 'dart:convert';

import 'package:http/http.dart' as http;

/// Wraps Google's Geocoding REST API to turn a lat/lng into a city name.
///
/// Uses the same API key already configured for Maps SDK for Android in
/// AndroidManifest.xml. NOTE: that key is normally restricted to "Android
/// apps" (package name + SHA-1) in the Google Cloud Console, which is a
/// restriction the Maps SDK can satisfy but a plain HTTP call from this
/// class cannot - if reverse geocoding starts failing with REQUEST_DENIED,
/// the fix is on the Google Cloud Console side (enable the Geocoding API for
/// this key, and relax its restriction, or use a second, differently
/// restricted key for this call), not in this code.
class GeocodingService {
  GeocodingService._();

  static const String _apiKey = 'AIzaSyDHR2SWoOAcC1e2-of9wOvSTk-yBIqOF7o';

  /// Returns the English city name for [lat]/[lng], or null if none could
  /// be determined (no network, no result, or an unexpected response shape).
  static Future<String?> getCityName(double lat, double lng) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'latlng': '$lat,$lng',
      'language': 'en',
      'key': _apiKey,
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['status'] != 'OK') return null;

    final results = (decoded['results'] as List?) ?? [];

    // Prefer a result that actually has a "locality" component (the city),
    // then fall back to broader administrative levels for rural/edge cases.
    const preferredTypes = [
      'locality',
      'administrative_area_level_2',
      'administrative_area_level_1',
    ];

    for (final type in preferredTypes) {
      for (final result in results) {
        final components = (result['address_components'] as List?) ?? [];
        for (final component in components) {
          final types = (component['types'] as List?) ?? [];
          if (types.contains(type)) {
            return component['long_name'] as String?;
          }
        }
      }
    }

    return null;
  }
}
