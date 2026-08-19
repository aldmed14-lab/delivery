import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Standard ray-casting point-in-polygon test. Treats latitude as the "y"
/// axis and longitude as "x" - accurate enough at neighborhood/city scale,
/// no need for full geodesic math here.
class PointInPolygon {
  PointInPolygon._();

  /// True if [point] lies inside the polygon described by [vertices] (an
  /// ordered list of corners - it doesn't need to be explicitly closed, the
  /// last point connects back to the first automatically).
  static bool contains(LatLng point, List<LatLng> vertices) {
    if (vertices.length < 3) return false;

    bool inside = false;
    for (int i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
      final xi = vertices[i].longitude, yi = vertices[i].latitude;
      final xj = vertices[j].longitude, yj = vertices[j].latitude;

      final crossesRay = (yi > point.latitude) != (yj > point.latitude);
      if (!crossesRay) continue;

      final xAtLat = (xj - xi) * (point.latitude - yi) / (yj - yi) + xi;
      if (point.longitude < xAtLat) inside = !inside;
    }
    return inside;
  }
}
