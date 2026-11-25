import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'package:flutter_application_1/utils/geohash.dart';

/// App-wide pending-offer watcher for a delivery driver. Started once from
/// HomeShell (after confirming users/{uid}.role == "delivery"), and again
/// by DeliveryHomePage's own online/offline toggle so the listener's
/// lifetime always tracks `is_online`, not just its value at app launch.
///
/// While listening, it watches delivery/{uid} for a `pending_offer` map
/// appearing - [DeliveryOfferOverlay] (wired into MaterialApp.builder, so
/// it renders above whatever page is currently on screen) reacts to that
/// by showing the "Nouvelle course" card. There's no dispatcher backend
/// behind `pending_offer` yet (nothing in this codebase currently writes
/// it) - this is the client-side half, ready for whenever that exists.
///
/// It also pushes this device's own GPS fix on a timer the whole time it's
/// listening, to whichever store actually matches how "live" it needs to
/// be: `delivery/{uid}` in Firestore every 1 minute while idle (a cheap
/// resting position, e.g. for future dispatch-matching queries), or
/// `locations/{uid}` in the Realtime Database every 5s once
/// `status` is "busy" (an order actually in hand) - the same node
/// [LiveOrderPage] already reads from for the customer's live tracking map.
/// See [_scheduleLocationUpdate] and [_pushCurrentLocation].
class DeliveryOfferService extends ChangeNotifier {
  DeliveryOfferService._();
  static final DeliveryOfferService instance = DeliveryOfferService._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  String? _uid;

  Map<String, dynamic>? _pendingOffer;
  Map<String, dynamic>? get pendingOffer => _pendingOffer;

  // The driver's own last-known position, from the same delivery/{uid} doc
  // this service already listens to - used by the offer card to estimate
  // "driver -> store -> dropoff" distance without a second read.
  double? driverLat;
  double? driverLng;

  // Drives how often this device's own GPS fix gets pushed: every 1 minute
  // to Firestore while idle, every 5s to the Realtime Database while an
  // order is actually in hand (status == "busy") - see
  // _pushCurrentLocation for which store each interval actually targets.
  static const _idleInterval = Duration(minutes: 1);
  static const _activeInterval = Duration(seconds: 5);
  Timer? _locationTimer;
  bool _hasActiveOrder = false;

  bool get isListening => _sub != null;

  /// The one entry point that checks `is_online` itself before starting -
  /// call this from app startup once role == "delivery" is known. Safe to
  /// call repeatedly (a no-op once already listening for this uid).
  Future<void> startIfOnline(String uid) async {
    if (_sub != null && _uid == uid) return;
    try {
      final snap = await _firestore.collection('delivery').doc(uid).get();
      if (snap.data()?['is_online'] == true) {
        start(uid);
      }
    } catch (_) {
      // A transient failure here just means offers won't show up until the
      // next natural trigger (e.g. the driver toggling online themselves).
    }
  }

  /// Unconditional - called directly by DeliveryHomePage right after it
  /// writes `is_online: true` itself, so the listener starts immediately
  /// rather than waiting on this doc's own snapshot to come back around.
  void start(String uid) {
    if (_sub != null && _uid == uid) return;
    stop();
    _uid = uid;
    _sub =
        _firestore.collection('delivery').doc(uid).snapshots().listen((snap) {
      final data = snap.data();
      if (data?['is_online'] != true) {
        // Toggled offline (from this device or another) - stop reacting to
        // offers until it's turned back on, but keep the subscription
        // itself alive so going back online is picked up immediately.
        if (_pendingOffer != null) {
          _pendingOffer = null;
          notifyListeners();
        }
        return;
      }
      driverLat = (data?['lat'] as num?)?.toDouble();
      driverLng = (data?['lng'] as num?)?.toDouble();

      final hadActiveOrder = _hasActiveOrder;
      _hasActiveOrder = data?['status'] == 'busy';
      if (_hasActiveOrder != hadActiveOrder) {
        // Cadence just changed (an offer was accepted, or a delivery just
        // ended) - reschedule now instead of waiting out whatever's left
        // of the old interval.
        _scheduleLocationUpdate();
      }

      final offer = data?['pending_offer'];
      final next = offer is Map ? Map<String, dynamic>.from(offer) : null;
      if (next != _pendingOffer) {
        _pendingOffer = next;
        notifyListeners();
      }
    });
    // Push a fix right away rather than waiting out the first full 30s/5s
    // interval - _tickLocationUpdate() itself reschedules the next one
    // afterward, so this isn't a duplicate of that timer.
    _locationTimer?.cancel();
    _tickLocationUpdate();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _uid = null;
    _locationTimer?.cancel();
    _locationTimer = null;
    _hasActiveOrder = false;
    if (_pendingOffer != null) {
      _pendingOffer = null;
      notifyListeners();
    }
  }

  void _scheduleLocationUpdate() {
    _locationTimer?.cancel();
    final interval = _hasActiveOrder ? _activeInterval : _idleInterval;
    _locationTimer = Timer(interval, _tickLocationUpdate);
  }

  Future<void> _tickLocationUpdate() async {
    await _pushCurrentLocation();
    // Still the same driver's session? start()/stop() could have run while
    // the GPS fix/write above was in flight.
    if (_uid != null) _scheduleLocationUpdate();
  }

  /// Same permission/service-enabled dance as CityResolver's own device fix
  /// - skips this specific tick on any failure (no permission, GPS off, no
  /// signal in time); the next tick (5s or 1min later) tries again rather
  /// than this ever surfacing as a blocking error to the driver. The reason
  /// is still logged (not just swallowed) so "location never updates" is
  /// actually diagnosable instead of a silent no-op.
  ///
  /// Which store gets written is decided fresh on every tick (not cached
  /// from when the timer was scheduled) - `_hasActiveOrder` flipping mid-
  /// flight (order just got delivered while a GPS fix was in progress)
  /// means this tick still lands in the right place instead of a stale one.
  Future<void> _pushCurrentLocation() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint(
            'DeliveryOfferService: location services are disabled on this device');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint(
            'DeliveryOfferService: location permission not granted ($permission)');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));

      if (_uid != uid) return; // session changed while awaiting the fix

      if (_hasActiveOrder) {
        // Same node LiveOrderPage's _driverLocationStream reads from for
        // the customer's own live tracking map - not the Firestore
        // delivery doc, which only tracks the idle/resting position.
        await FirebaseDatabase.instance.ref('locations/$uid').set({
          'lat': position.latitude,
          'lng': position.longitude,
          'updated_at': ServerValue.timestamp,
        });
        debugPrint(
            'DeliveryOfferService: pushed active location ${position.latitude}, ${position.longitude} to RTDB');
      } else {
        // geohash rides along with every lat/lng update - the courier search
        // (functions/courierSearch.js) narrows candidates by geohash prefix,
        // so a driver whose geohash was never written only matches once the
        // search widens to the whole city.
        await _firestore.collection('delivery').doc(uid).update({
          'lat': position.latitude,
          'lng': position.longitude,
          'geohash': Geohash.encode(position.latitude, position.longitude),
        });
        debugPrint(
            'DeliveryOfferService: pushed idle location ${position.latitude}, ${position.longitude} to Firestore');
      }
    } catch (e) {
      debugPrint('DeliveryOfferService: location push failed - $e');
    }
  }

  /// Goes through the `respondToDeliveryOffer` Cloud Function rather than
  /// writing `orders`/`delivery` directly - it re-reads `pending_offer` from
  /// this driver's own Firestore doc (server truth) rather than trusting
  /// this class's own cached `_pendingOffer`, so there's nothing to accept
  /// unless this specific driver was actually offered this specific order.
  Future<bool> respond({required bool accept}) async {
    if (_uid == null || _pendingOffer == null) return false;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('respondToDeliveryOffer')
          .call({'accept': accept});
      return true;
    } catch (_) {
      return false;
    }
  }
}
