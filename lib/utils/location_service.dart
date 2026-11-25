import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:flutter_application_1/utils/geohash.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// users/{uid}/addresses/{id} - a saved, pin-confirmed delivery address.
class SavedAddress {
  final String id;
  final String label;
  final double lat;
  final double lng;
  final String cityId;

  const SavedAddress({
    required this.id,
    required this.label,
    required this.lat,
    required this.lng,
    required this.cityId,
  });

  static SavedAddress? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    if (d == null || d['lat'] == null || d['lng'] == null) return null;
    return SavedAddress(
      id: doc.id,
      label: d['label'] as String? ?? '',
      lat: (d['lat'] as num).toDouble(),
      lng: (d['lng'] as num).toDouble(),
      cityId: d['city_id'] as String? ?? '',
    );
  }

  /// False once a polygon edit (or a deleted city) left this point outside
  /// every city - "no longer in our delivery area", can't be used.
  bool get isServed => CitiesService.instance.resolve(lat, lng) != null;
}

/// The location the app is browsing with right now: a saved address
/// ([addressId] set), or the device's GPS position used for browsing only
/// and never saved to Firestore ([addressId] null).
class ActiveLocation {
  final String? addressId;
  final String? label;
  final double lat;
  final double lng;
  final String cityId;

  const ActiveLocation({
    required this.addressId,
    required this.label,
    required this.lat,
    required this.lng,
    required this.cityId,
  });

  bool get isSaved => addressId != null;

  factory ActiveLocation.fromAddress(SavedAddress a) => ActiveLocation(
        addressId: a.id,
        label: a.label,
        lat: a.lat,
        lng: a.lng,
        cityId: a.cityId,
      );

  Map<String, dynamic> toJson() => {
        'address_id': addressId,
        'label': label,
        'lat': lat,
        'lng': lng,
        'city_id': cityId,
      };

  static ActiveLocation? fromJson(Map<String, dynamic> j) {
    if (j['lat'] == null || j['lng'] == null || j['city_id'] == null) {
      return null;
    }
    return ActiveLocation(
      addressId: j['address_id'] as String?,
      label: j['label'] as String?,
      lat: (j['lat'] as num).toDouble(),
      lng: (j['lng'] as num).toDouble(),
      cityId: j['city_id'] as String,
    );
  }
}

class AddressLimitReached implements Exception {}

class AddressOutsideCities implements Exception {}

/// Owns the active location (lib/note.txt LOCATION SYSTEM): kept in local
/// storage so home can show the last city instantly, and the user's saved
/// addresses. Every page reads the location from here; it's a
/// [ChangeNotifier] so they all follow a change made anywhere.
class LocationService extends ChangeNotifier {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const maxAddresses = 10;

  /// users.default_address_id value meaning "use the device GPS on start".
  static const currentLocationId = 'current_location';
  static const _prefsUid = 'location_uid';
  static const _prefsActive = 'location_active';

  final _db = FirebaseFirestore.instance;
  ActiveLocation? _active;

  ActiveLocation? get active => _active;
  String? get cityId => _active?.cityId;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  CollectionReference<Map<String, dynamic>> _addresses(String uid) =>
      _db.collection('users').doc(uid).collection('addresses');

  // ── local storage ────────────────────────────────────────────────────────

  /// The last active location saved on this phone, but only if it belongs
  /// to the signed-in account - a different account on the same phone
  /// starts clean instead of on the previous user's location.
  Future<ActiveLocation?> loadLocal() async {
    final uid = _uid;
    final prefs = await SharedPreferences.getInstance();
    if (uid == null || prefs.getString(_prefsUid) != uid) {
      await clearLocal();
      return null;
    }
    final raw = prefs.getString(_prefsActive);
    if (raw == null) return null;
    try {
      _active = ActiveLocation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      _active = null;
    }
    notifyListeners();
    return _active;
  }

  /// Wipes the location from this phone - call on logout / account switch.
  /// The cached cities stay (not personal).
  Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsUid);
    await prefs.remove(_prefsActive);
    if (_active != null) {
      _active = null;
      notifyListeners();
    }
  }

  Future<void> _setActive(ActiveLocation? location) async {
    _active = location;
    final prefs = await SharedPreferences.getInstance();
    final uid = _uid;
    if (location == null || uid == null) {
      await prefs.remove(_prefsActive);
    } else {
      await prefs.setString(_prefsUid, uid);
      await prefs.setString(_prefsActive, jsonEncode(location.toJson()));
    }
    notifyListeners();
  }

  // ── reading ──────────────────────────────────────────────────────────────

  /// True when the user last chose "current location": home then starts
  /// from the device GPS instead of a saved address.
  static bool defaultIsCurrentLocation(Map<String, dynamic>? userData) =>
      userData?['default_address_id'] == currentLocationId;

  /// The account's default saved address, or null (none set, deleted, no
  /// longer inside any city, or the default is "current location").
  Future<SavedAddress?> fetchDefault(Map<String, dynamic>? userData) async {
    final uid = _uid;
    final id = userData?['default_address_id'] as String?;
    if (uid == null || id == null || id.isEmpty || id == currentLocationId) {
      return null;
    }
    final address = SavedAddress.fromDoc(await _addresses(uid).doc(id).get());
    if (address == null || !address.isServed) return null;
    return address;
  }

  /// Saved addresses, most recently used first.
  Stream<List<SavedAddress>> watchAddresses() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _addresses(uid)
        .orderBy('last_used_at', descending: true)
        .snapshots()
        .map((s) => s.docs.map(SavedAddress.fromDoc).whereType<SavedAddress>().toList());
  }

  // ── changing the active location ─────────────────────────────────────────

  /// Browse on a GPS position without saving it anywhere but this phone.
  Future<void> useUnsaved({
    required double lat,
    required double lng,
    required String cityId,
  }) =>
      _setActive(ActiveLocation(
        addressId: null,
        label: null,
        lat: lat,
        lng: lng,
        cityId: cityId,
      ));

  /// The user chose "current location": browse on the GPS position (not
  /// saved) and make GPS the default, so every home start re-reads it.
  Future<void> useCurrentAsDefault({
    required double lat,
    required double lng,
    required String cityId,
  }) async {
    final uid = _uid;
    if (uid != null) {
      await _db.collection('users').doc(uid).set(
          {'default_address_id': currentLocationId}, SetOptions(merge: true));
    }
    await useUnsaved(lat: lat, lng: lng, cityId: cityId);
  }

  /// Make a saved address the active + default one.
  Future<void> select(SavedAddress address) async {
    final uid = _uid;
    if (uid != null) {
      final batch = _db.batch();
      batch.update(_addresses(uid).doc(address.id),
          {'last_used_at': FieldValue.serverTimestamp()});
      batch.set(_db.collection('users').doc(uid),
          {'default_address_id': address.id}, SetOptions(merge: true));
      await batch.commit();
    }
    await _setActive(ActiveLocation.fromAddress(address));
  }

  /// Use a location only for this app session (the stored default stays):
  /// home applies the account's default address this way on start.
  Future<void> applyDefault(SavedAddress address) =>
      _setActive(ActiveLocation.fromAddress(address));

  /// Save a new pin-confirmed address and make it active + default.
  /// Throws [AddressLimitReached] at [maxAddresses], [AddressOutsideCities]
  /// when the point isn't inside any city.
  Future<SavedAddress> addAddress({
    required String label,
    required double lat,
    required double lng,
  }) async {
    final uid = _uid;
    if (uid == null) throw StateError('not signed in');
    final city = CitiesService.instance.resolve(lat, lng);
    if (city == null) throw AddressOutsideCities();

    final count = (await _addresses(uid).count().get()).count ?? 0;
    if (count >= maxAddresses) throw AddressLimitReached();

    final ref = _addresses(uid).doc();
    final batch = _db.batch();
    batch.set(ref, {
      'label': label,
      'lat': lat,
      'lng': lng,
      'geohash': Geohash.encode(lat, lng),
      'city_id': city.id,
      'last_used_at': FieldValue.serverTimestamp(),
      'created_at': FieldValue.serverTimestamp(),
    });
    batch.set(_db.collection('users').doc(uid), {'default_address_id': ref.id},
        SetOptions(merge: true));
    await batch.commit();

    final address = SavedAddress(
        id: ref.id, label: label, lat: lat, lng: lng, cityId: city.id);
    await _setActive(ActiveLocation.fromAddress(address));
    return address;
  }

  /// Delete a saved address. If it was the active one, the app has no
  /// location until the user picks another (home shows the picker).
  Future<void> deleteAddress(String addressId) async {
    final uid = _uid;
    if (uid == null) return;
    final userRef = _db.collection('users').doc(uid);
    final userSnap = await userRef.get();
    final batch = _db.batch();
    batch.delete(_addresses(uid).doc(addressId));
    if (userSnap.data()?['default_address_id'] == addressId) {
      batch.update(userRef, {'default_address_id': FieldValue.delete()});
    }
    await batch.commit();
    if (_active?.addressId == addressId) await _setActive(null);
  }

  /// After the cities changed (cities_version bumped): fix each saved
  /// address's city_id against the new polygons. Addresses now outside every
  /// city are left as they are - [SavedAddress.isServed] reports them as
  /// "no longer in our delivery area". Returns false if the active location
  /// itself is no longer served.
  Future<bool> recheckAddresses() async {
    final uid = _uid;
    if (uid != null) {
      final snap = await _addresses(uid).get();
      final batch = _db.batch();
      var writes = 0;
      for (final doc in snap.docs) {
        final a = SavedAddress.fromDoc(doc);
        if (a == null) continue;
        final city = CitiesService.instance.resolve(a.lat, a.lng);
        if (city != null && city.id != a.cityId) {
          batch.update(doc.reference, {'city_id': city.id});
          writes++;
        }
      }
      if (writes > 0) await batch.commit();
    }

    final active = _active;
    if (active == null) return true;
    final city = CitiesService.instance.resolve(active.lat, active.lng);
    if (city == null) {
      await _setActive(null);
      return false;
    }
    if (city.id != active.cityId) {
      await _setActive(ActiveLocation(
        addressId: active.addressId,
        label: active.label,
        lat: active.lat,
        lng: active.lng,
        cityId: city.id,
      ));
    }
    return true;
  }
}
