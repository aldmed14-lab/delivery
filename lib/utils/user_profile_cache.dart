import 'package:flutter/foundation.dart';

/// Tiny in-memory cache for the signed-in user's name/phone/role. The home
/// page populates it once on app start (it already fetches `users/{uid}`
/// anyway); the profile page just reads it directly instead of doing its
/// own fetch. A [ChangeNotifier] so the profile page still updates live if
/// a value changes later (e.g. after editing the name on the account page).
///
/// The location is NOT here - see LocationService (lib/utils/location_service.dart).
class UserProfileCache extends ChangeNotifier {
  UserProfileCache._();
  static final UserProfileCache instance = UserProfileCache._();

  String? name;
  String? phone;

  /// "owner" | "delivery" | null - drives whether Profile shows an
  /// "Espace magasin"/"Espace livreur" shortcut for accounts that are also
  /// a store owner or a delivery driver, on top of being a regular client.
  String? role;

  void update({String? name, String? phone, String? role}) {
    this.name = name;
    this.phone = phone;
    this.role = role;
    notifyListeners();
  }
}
