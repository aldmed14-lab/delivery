import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';

/// One line in a store's cart - shaped to match `orders.lines` in
/// `lib/map.txt` so submitting a cart later is a straight copy, not a
/// reshape. `groups` mirrors picks from the item's `groups` subcollection
/// (each with its own `min`/`max`) - that's the only source of selectable
/// choices now that items no longer carry their own inline `options[]`.
class CartLine {
  final String lineKey;
  final String itemId;
  final String nameAr;
  final String nameFr;
  final String image;
  final int quantity;

  /// Base item price plus every selected group option's delta - the price
  /// of *one* unit of this exact configuration.
  final double unitPrice;

  final List<Map<String, dynamic>> groups;

  CartLine({
    required this.lineKey,
    required this.itemId,
    required this.nameAr,
    required this.nameFr,
    required this.image,
    required this.quantity,
    required this.unitPrice,
    required this.groups,
  });

  double get lineTotal => unitPrice * quantity;

  Map<String, dynamic> toMap() => {
        'item_id': itemId,
        'name_ar': nameAr,
        'name_fr': nameFr,
        'image': image,
        'quantity': quantity,
        'price': unitPrice,
        'groups': groups,
      };

  static CartLine fromMap(String key, Map<String, dynamic> data) {
    return CartLine(
      lineKey: key,
      itemId: data['item_id'] as String? ?? '',
      nameAr: data['name_ar'] as String? ?? '',
      nameFr: data['name_fr'] as String? ?? '',
      image: data['image'] as String? ?? '',
      quantity: (data['quantity'] as num?)?.toInt() ?? 0,
      unitPrice: (data['price'] as num?)?.toDouble() ?? 0,
      groups: (data['groups'] as List? ?? [])
          .map((g) => (g as Map).cast<String, dynamic>())
          .toList(),
    );
  }
}

/// Result of [StoreCartService.syncWithCatalog] - how many lines were
/// dropped entirely vs. just had their price/config refreshed in place.
class CartSyncResult {
  final int removed;
  final int updated;
  const CartSyncResult({required this.removed, required this.updated});
}

/// Reads/writes `users/{uid}/carts/{storeId}` per `lib/map.txt` - one doc
/// per store the user has items from, keyed by a deterministic
/// [lineKeyFor] so re-adding the exact same configuration bumps quantity
/// instead of creating a duplicate line.
class StoreCartService {
  StoreCartService._();

  static DocumentReference<Map<String, dynamic>> cartRef(
          String uid, String storeId) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('carts')
          .doc(storeId);

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watch(
          String uid, String storeId) =>
      cartRef(uid, storeId).snapshots();

  /// Deterministic key for a given item + selection combination, so the
  /// exact same picks always collapse into one line. Options within a
  /// group, and the groups themselves, are sorted before joining - picking
  /// the same two options in a different order (or groups resolved in a
  /// different order) must still land on the same key, not a duplicate
  /// line for what's really an identical selection.
  static String lineKeyFor(String itemId, List<Map<String, dynamic>> groups) {
    final groupsPart = groups
        .map((g) {
          final optionIds = ((g['selected'] as List?) ?? [])
              .map((s) => s['option_id'].toString())
              .toList()
            ..sort();
          return '${g['group_id']}:${optionIds.join(',')}';
        })
        .toList()
      ..sort();
    final signature = '${itemId}_${groupsPart.join('|')}';
    // option_id is a full UUID (Uuid().v4()) now, so concatenating them
    // straight into the key (the old approach) could run to hundreds of
    // characters across a few groups - awkward and fragile as an actual
    // Firestore map key, which this is also used as directly in dot-path
    // updates (`lines.$lineKey.quantity`). Hashing the same deterministic
    // signature down to a short, fixed-length, Firestore-safe key keeps
    // the one property that actually matters (same selection -> same key,
    // so re-adding it merges into the existing line) without the length
    // blowing up as items get more/bigger option groups.
    return sha256.convert(utf8.encode(signature)).toString().substring(0, 24);
  }

  /// Adds [line] to the cart, merging quantity into any existing line with
  /// the same key rather than overwriting it.
  static Future<void> addLine(
    String uid,
    String storeId, {
    required String storeNameAr,
    required String storeNameFr,
    required String storeImage,
    required CartLine line,
  }) async {
    final ref = cartRef(uid, storeId);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) {
        tx.set(ref, {
          'store_id': storeId,
          'store_name_ar': storeNameAr,
          'store_name_fr': storeNameFr,
          'store_image': storeImage,
          'transaction_id': null,
          'waiting_payment': false,
          'lines': {line.lineKey: line.toMap()},
        });
        return;
      }

      final data = snap.data() ?? {};
      final lines = Map<String, dynamic>.from((data['lines'] as Map?) ?? {});
      final existing = (lines[line.lineKey] as Map?)?.cast<String, dynamic>();
      if (existing != null) {
        final existingQty = (existing['quantity'] as num?)?.toInt() ?? 0;
        lines[line.lineKey] = {
          ...line.toMap(),
          'quantity': existingQty + line.quantity,
        };
      } else {
        lines[line.lineKey] = line.toMap();
      }
      tx.update(ref, {'lines': lines});
    });
  }

  static Future<void> setLineQuantity(
      String uid, String storeId, String lineKey, int quantity) async {
    final ref = cartRef(uid, storeId);
    if (quantity <= 0) {
      await ref.update({'lines.$lineKey': FieldValue.delete()});
    } else {
      await ref.update({'lines.$lineKey.quantity': quantity});
    }
  }

  static Future<void> removeLine(
      String uid, String storeId, String lineKey) async {
    await cartRef(uid, storeId).update({'lines.$lineKey': FieldValue.delete()});
  }

  /// Empties an existing cart's `lines` map in place (the doc itself, and
  /// fields like `waiting_payment`/`transaction_id`, are left untouched).
  static Future<void> clearLines(String uid, String storeId) async {
    await cartRef(uid, storeId).update({'lines': {}});
  }

  /// Atomically replaces the entire `lines` map with [lines] in one write.
  /// Used by reorder to swap a cart's contents in a single step - clearing
  /// the cart and then re-adding each line separately (one write per line)
  /// could leave the cart only partially repopulated if the app loses
  /// connection partway through the sequence.
  static Future<void> replaceLines(
    String uid,
    String storeId, {
    required String storeNameAr,
    required String storeNameFr,
    required String storeImage,
    required List<CartLine> lines,
  }) async {
    final ref = cartRef(uid, storeId);
    final linesMap = {for (final line in lines) line.lineKey: line.toMap()};
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) {
        tx.set(ref, {
          'store_id': storeId,
          'store_name_ar': storeNameAr,
          'store_name_fr': storeNameFr,
          'store_image': storeImage,
          'transaction_id': null,
          'waiting_payment': false,
          'lines': linesMap,
        });
      } else {
        tx.update(ref, {'lines': linesMap});
      }
    });
  }

  /// Rebuilds one stored line against the item/groups as they exist *now* -
  /// shared by [syncWithCatalog] and [OrderReorderService], so a cart line
  /// and a reordered line are re-validated by exactly the same rule.
  /// Returns null (meaning: the line can't be replayed as-is) when the item
  /// no longer exists/isn't currently available, or the stored group
  /// selection can no longer be validly replayed - a group it picked from
  /// was removed or had an option removed, a group that's now required
  /// wasn't part of the original selection at all, or the pick no longer
  /// satisfies the group's current min/max. Names/prices in the rebuilt
  /// line always come from the live docs, never the (possibly stale)
  /// stored data - this is what actually catches an item or a group
  /// option's price changing after it was added, not just the item being
  /// deleted outright.
  static Future<CartLine?> resolveLiveLine(
    String storeId,
    String itemId,
    Map<String, dynamic> lineData,
  ) async {
    final firestore = FirebaseFirestore.instance;
    final itemSnap = await firestore
        .collection('stores')
        .doc(storeId)
        .collection('items')
        .doc(itemId)
        .get();
    final itemData = itemSnap.data();
    if (itemData == null || itemData['exist'] != true) return null;

    final groupsSnap = await firestore
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
      lineKey: lineKeyFor(itemId, freshGroups),
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

    // A group that's required *now* but wasn't part of the original
    // selection at all can't be auto-filled - the item needs to be
    // reconfigured manually.
    for (final entry in liveGroupsById.entries) {
      final min = (entry.value['min'] as num?)?.toInt() ?? 0;
      if (min <= 0) continue;
      if (!result.any((g) => g['group_id'] == entry.key)) return null;
    }

    return result;
  }

  /// Re-validates every line against the item/groups as they exist *now*
  /// (see [resolveLiveLine]) - removes a line that's no longer available at
  /// all, and rewrites one whose item/group-option prices (or names) have
  /// changed since it was added, so a stale frozen price can never ride
  /// silently through to checkout. Called whenever the cart, or the store
  /// it belongs to, is opened. Skips a cart that's mid-payment
  /// (`waiting_payment`) - that already has a transaction against it, so
  /// its lines aren't safe to touch.
  static Future<CartSyncResult> syncWithCatalog(
      String uid, String storeId) async {
    final ref = cartRef(uid, storeId);
    final snap = await ref.get();
    final data = snap.data();
    if (data == null || data['waiting_payment'] == true) {
      return const CartSyncResult(removed: 0, updated: 0);
    }

    final linesMap = Map<String, dynamic>.from((data['lines'] as Map?) ?? {});
    if (linesMap.isEmpty) return const CartSyncResult(removed: 0, updated: 0);

    final writes = <String, Object?>{};
    var removed = 0;
    var updated = 0;

    await Future.wait(linesMap.entries.map((e) async {
      final oldKey = e.key;
      final lineData = (e.value as Map).cast<String, dynamic>();
      final itemId = lineData['item_id'] as String? ?? '';
      final line = itemId.isEmpty
          ? null
          : await resolveLiveLine(storeId, itemId, lineData);

      if (line == null) {
        writes['lines.$oldKey'] = FieldValue.delete();
        removed++;
        return;
      }

      // Only the price is what actually matters here - a group/option
      // getting renamed without its price changing isn't worth a write.
      final storedPrice = (lineData['price'] as num?)?.toDouble();
      if (line.lineKey == oldKey && line.unitPrice == storedPrice) return;

      // A rebuilt line's key can differ from the stored one if the group
      // selection it maps from changed shape - deleting the old key and
      // writing the new one (rather than just updating in place) avoids
      // orphaning the old entry in that case.
      if (line.lineKey != oldKey) writes['lines.$oldKey'] = FieldValue.delete();
      writes['lines.${line.lineKey}'] = line.toMap();
      updated++;
    }));

    if (writes.isNotEmpty) await ref.update(writes);
    return CartSyncResult(removed: removed, updated: updated);
  }

  static List<CartLine> linesFrom(Map<String, dynamic>? cartData) {
    final linesMap = (cartData?['lines'] as Map?) ?? {};
    return linesMap.entries
        .map((e) =>
            CartLine.fromMap(e.key, (e.value as Map).cast<String, dynamic>()))
        .toList();
  }
}
