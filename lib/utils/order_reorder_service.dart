import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';

enum ReorderOutcome {
  success,
  partial,
  allUnavailable,
  storeClosed,
  differentCity,
  waitingPayment,
}

class ReorderResult {
  final ReorderOutcome outcome;
  final int addedCount;
  final int skippedCount;

  const ReorderResult(this.outcome,
      {this.addedCount = 0, this.skippedCount = 0});
}

/// Replays a past order's `lines` back into `users/{uid}/carts/{storeId}`,
/// shared by the order history list and detail pages so both "Recommander"
/// buttons behave identically.
class OrderReorderService {
  OrderReorderService._();

  static final _firestore = FirebaseFirestore.instance;

  /// Reorder only makes sense while the store is actually taking orders -
  /// `status` ("open" | "trafic" | "close" per `lib/map.txt`), not the
  /// unrelated `active` flag (whether the store has staff access at all).
  static Future<bool> isStoreOpen(String storeId) async {
    final snap = await _firestore.collection('stores').doc(storeId).get();
    return snap.data()?['status'] == 'open';
  }

  static Future<String?> _userCity(String uid) async {
    final snap = await _firestore.collection('users').doc(uid).get();
    return (snap.data()?['address'] as Map<String, dynamic>?)?['city']
        as String?;
  }

  /// A past order can be from a store in a city the user has since moved
  /// away from - delivery isn't possible outside the user's current
  /// serviced city, so reorder only makes sense when the store's city
  /// still matches it.
  static Future<bool> isStoreInUserCity(String uid, String storeId) async {
    final storeSnap = await _firestore.collection('stores').doc(storeId).get();
    final storeCity = storeSnap.data()?['city'] as String?;
    final userCity = await _userCity(uid);
    return citiesMatch(storeCity, userCity);
  }

  /// The actual comparison [isStoreInUserCity] does, pulled out as a pure
  /// read-free check - store_details_page.dart and cart_page.dart apply
  /// this exact same "not deliverable outside the user's city" rule, but
  /// already have both cities loaded from their own listeners, so routing
  /// them through [isStoreInUserCity] itself would cost them a second,
  /// redundant read of the store doc they already have in hand.
  static bool citiesMatch(String? storeCity, String? userCity) {
    return storeCity != null &&
        storeCity.isNotEmpty &&
        userCity != null &&
        userCity == storeCity;
  }

  /// Whether "Recommander" should even be shown - open and in the user's
  /// current city.
  static Future<bool> canReorder(String uid, String storeId) async {
    if (!await isStoreOpen(storeId)) return false;
    return isStoreInUserCity(uid, storeId);
  }

  static Future<ReorderResult> reorder({
    required String uid,
    required Map<String, dynamic> orderData,
  }) async {
    final storeId = orderData['store_id'] as String? ?? '';
    if (storeId.isEmpty) {
      return const ReorderResult(ReorderOutcome.allUnavailable);
    }

    // Re-checked here rather than trusted from whatever the caller's UI
    // already knew - the store could have closed, or the user could have
    // switched cities, in the moments between rendering and the tap
    // actually landing.
    if (!await isStoreOpen(storeId)) {
      return const ReorderResult(ReorderOutcome.storeClosed);
    }
    if (!await isStoreInUserCity(uid, storeId)) {
      return const ReorderResult(ReorderOutcome.differentCity);
    }

    final storeNameAr = orderData['store_name_ar'] as String? ?? '';
    final storeNameFr = orderData['store_name_fr'] as String? ?? '';
    final storeImage = orderData['store_image'] as String? ?? '';

    final existingCart = await StoreCartService.cartRef(uid, storeId).get();
    if (existingCart.exists &&
        existingCart.data()?['waiting_payment'] == true) {
      return const ReorderResult(ReorderOutcome.waitingPayment);
    }

    // Resolve every line against the item/groups as they exist *now*
    // before writing anything - an item may have been deleted, or its
    // groups changed, since the order was placed, and the old cart
    // shouldn't be wiped out for a reorder that turns out to add nothing.
    final linesMap = (orderData['lines'] as Map?) ?? {};
    final resolvedLines = <CartLine>[];
    var skippedCount = 0;
    for (final entry in linesMap.values) {
      final lineData = (entry as Map).cast<String, dynamic>();
      final itemId = lineData['item_id'] as String? ?? '';
      final line = itemId.isEmpty
          ? null
          : await StoreCartService.resolveLiveLine(storeId, itemId, lineData);
      if (line != null) {
        resolvedLines.add(line);
      } else {
        skippedCount++;
      }
    }

    if (resolvedLines.isEmpty) {
      return ReorderResult(ReorderOutcome.allUnavailable,
          skippedCount: skippedCount);
    }

    // Reorder replaces the cart's contents rather than adding on top of
    // whatever was already there - without this, re-adding an order whose
    // store already has unrelated items in the cart would just pile the
    // reordered lines onto the existing ones. Written as one atomic
    // replace rather than a clear followed by a per-line add loop, so a
    // dropped connection mid-reorder can't leave the cart cleared but
    // only partially repopulated.
    await StoreCartService.replaceLines(
      uid,
      storeId,
      storeNameAr: storeNameAr,
      storeNameFr: storeNameFr,
      storeImage: storeImage,
      lines: resolvedLines,
    );

    return ReorderResult(
      skippedCount == 0 ? ReorderOutcome.success : ReorderOutcome.partial,
      addedCount: resolvedLines.length,
      skippedCount: skippedCount,
    );
  }
}
