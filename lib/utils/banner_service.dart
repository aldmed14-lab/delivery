import 'package:cloud_firestore/cloud_firestore.dart';

/// A city's promotional head banner:
/// banner {
///     city_id {
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

  /// Returns the banner for the city [cityId], or null if there isn't one,
  /// it has no image, or it's marked inactive - callers just hide the slot.
  static Future<CityBanner?> fetchForCity(String cityId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('banner')
          .doc(cityId)
          .get();
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
