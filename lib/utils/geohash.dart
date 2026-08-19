/// Minimal standard geohash encoder (base32, the same scheme used by
/// geohash.org). No package dependency needed for something this small.
class Geohash {
  Geohash._();

  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  static String encode(double latitude, double longitude, {int precision = 9}) {
    double latMin = -90.0, latMax = 90.0;
    double lngMin = -180.0, lngMax = 180.0;

    final buffer = StringBuffer();
    bool isEvenBit = true;
    int bit = 0;
    int charBits = 0;

    while (buffer.length < precision) {
      if (isEvenBit) {
        final mid = (lngMin + lngMax) / 2;
        if (longitude >= mid) {
          charBits = (charBits << 1) | 1;
          lngMin = mid;
        } else {
          charBits = charBits << 1;
          lngMax = mid;
        }
      } else {
        final mid = (latMin + latMax) / 2;
        if (latitude >= mid) {
          charBits = (charBits << 1) | 1;
          latMin = mid;
        } else {
          charBits = charBits << 1;
          latMax = mid;
        }
      }
      isEvenBit = !isEvenBit;

      if (++bit == 5) {
        buffer.write(_base32[charBits]);
        bit = 0;
        charBits = 0;
      }
    }

    return buffer.toString();
  }
}
