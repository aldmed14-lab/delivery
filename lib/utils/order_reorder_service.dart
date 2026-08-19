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

  const ReorderResult(this.outcome, {this.addedCount = 0, this.skippedCount = 0});
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
    return (snap.data()?['address'] as Map<String, dynamic>?)?['city'] as String?;
  }

  /// A past order can be from a store in a city the user has since moved
  /// away from - delivery isn't possible outside the user's current
  /// serviced city, so reorder only makes sense when the store's city
  /// still matches it.
  static Future<bool> isStoreInUserCity(String uid, String storeId) async {
    final storeSnap = await _firestore.collection('stores').doc(storeId).get();
    final storeCity = storeSnap.data()?['city'] as String?;
    if (storeCity == null || storeCity.isEmpty) return false;
    final userCity = await _userCity(uid);
    return userCity != null && userCity == storeCity;
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
    if (storeId.isEmpty) return const ReorderResult(ReorderOutcome.allUnavailable);

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
    if (existingCart.exists && existingCart.data()?['waiting_payment'] == true) {
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
          : await _resolveReorderLine(storeId, itemId, lineData);
      if (line != null) {
        resolvedLines.add(line);
      } else {
        skippedCount++;
      }
    }

    if (resolvedLines.isEmpty) {
      return ReorderResult(ReorderOutcome.allUnavailable, skippedCount: skippedCount);
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

  /// Rebuilds one order line against the item/groups as they exist now.
  /// Returns null (meaning: skip this line) when the item no longer
  /// exists, or the order's frozen group selection can no longer be
  /// replayed as-is - a group the order picked from was removed or had an
  /// option removed, a group that's now required wasn't part of the order
  /// at all, or the pick no longer satisfies the group's current min/max.
  /// Names/prices in the rebuilt line always come from the live docs, not
  /// the (possibly stale) order data.
  static Future<CartLine?> _resolveReorderLine(
    String storeId,
    String itemId,
    Map<String, dynamic> lineData,
  ) async {
    final itemSnap = await _firestore
        .collection('stores')
        .doc(storeId)
        .collection('items')
        .doc(itemId)
        .get();
    final itemData = itemSnap.data();
    if (itemData == null || itemData['exist'] != true) return null;

    final groupsSnap = await _firestore
        .collection('stores')
        .doc(storeId)
        .collection('groups')
        .where('item_id', isEqualTo: itemId)
        .get();
    final liveGroupsById = {
      for (final g in groupsSnap.docs) g.id: g.data(),
    };

    final storedGroups = (lineData['groups'] as List? ?? [])
        .map((g) => (g as Map).cast<String, dynamic>())
        .toList();
    final freshGroups = _rebuildGroups(storedGroups, liveGroupsById);
    if (freshGroups == null) return null;

    final addonsPrice = freshGroups.fold<double>(0, (acc, g) {
      final selected = (g['selected'] as List).cast<Map<String, dynamic>>();
      return acc +
          selected.fold<double>(
              0, (a, s) => a + ((s['price'] as num?)?.toDouble() ?? 0));
    });
    final unitPrice = (itemData['price'] as num?)?.toDouble() ?? 0;

    return CartLine(
      lineKey: StoreCartService.lineKeyFor(itemId, freshGroups),
      itemId: itemId,
      nameAr: itemData['name_ar'] as String? ?? '',
      nameFr: itemData['name_fr'] as String? ?? '',
      image: itemData['image'] as String? ?? '',
      quantity: (lineData['quantity'] as num?)?.toInt() ?? 1,
      unitPrice: unitPrice + addonsPrice,
      groups: freshGroups,
    );
  }

  /// Returns the rebuilt selection (fresh names/prices from [liveGroupsById])
  /// or null if [storedGroups] can no longer be validly replayed against it.
  static List<Map<String, dynamic>>? _rebuildGroups(
    List<Map<String, dynamic>> storedGroups,
    Map<String, Map<String, dynamic>> liveGroupsById,
  ) {
    final result = <Map<String, dynamic>>[];
    for (final stored in storedGroups) {
      final groupId = stored['group_id'] as String?;
      final live = liveGroupsById[groupId];
      if (live == null) return null;

      final liveOptions = ((live['options'] as List?) ?? [])
          .map((o) => (o as Map).cast<String, dynamic>())
          .toList();
      final storedSelectedIds = ((stored['selected'] as List?) ?? [])
          .map((s) => (s as Map)['option_id'] as String?)
          .toList();

      final freshSelected = <Map<String, dynamic>>[];
      for (final optionId in storedSelectedIds) {
        final liveOption = liveOptions.cast<Map<String, dynamic>?>().firstWhere(
              (o) => o?['option_id'] == optionId,
              orElse: () => null,
            );
        if (liveOption == null) return null;
        freshSelected.add({
          'option_id': liveOption['option_id'],
          'name_ar': liveOption['name_ar'],
          'name_fr': liveOption['name_fr'],
          'price': liveOption['price'],
        });
      }

      final min = (live['min'] as num?)?.toInt() ?? 0;
      final max = (live['max'] as num?)?.toInt() ?? 0;
      if (min > 0 && freshSelected.length < min) return null;
      if (max > 0 && freshSelected.length > max) return null;

      result.add({
        'group_id': groupId,
        'name_ar': live['name_ar'],
        'name_fr': live['name_fr'],
        'selected': freshSelected,
      });
    }

    // A group that's required *now* but wasn't part of the order's
    // original selection at all can't be auto-filled - the item needs to
    // be reconfigured manually.
    for (final entry in liveGroupsById.entries) {
      final min = (entry.value['min'] as num?)?.toInt() ?? 0;
      if (min <= 0) continue;
      if (!result.any((g) => g['group_id'] == entry.key)) return null;
    }

    return result;
  }
}
