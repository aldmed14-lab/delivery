import 'package:cloud_firestore/cloud_firestore.dart';

/// A city's promotional head banner:
/// banner {
///     city_name {
///         image
///         active
///     }
/// }
class CityBanner {
  final String imageUrl;
  final bool active;

  const CityBanner({required this.imageUrl, required this.active});
}

class BannerService {
  BannerService._();

  /// Returns the banner for [cityName], or null if there isn't one, it has
  /// no image, or it's marked inactive - callers just hide the slot in that
  /// case rather than branching on multiple falsy states themselves.
  static Future<CityBanner?> fetchForCity(String cityName) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('banner')
          .doc(cityName)
          .get();
      if (!doc.exists) return null;

      final data = doc.data();
      final image = data?['image'] as String?;
      final active = data?['active'] as bool? ?? false;
      if (image == null || image.isEmpty || !active) return null;

      return CityBanner(imageUrl: image, active: active);
    } catch (_) {
      return null;
    }
  }
}
