import 'package:cloud_firestore/cloud_firestore.dart';

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
  /// exact same picks always collapse into one line.
  static String lineKeyFor(String itemId, List<Map<String, dynamic>> groups) {
    final groupsPart = groups
        .map((g) =>
            '${g['group_id']}:${((g['selected'] as List?) ?? []).map((s) => s['option_id']).join(',')}')
        .join('|');
    return '${itemId}_$groupsPart'.replaceAll(RegExp(r'[.\$\[\]#/\s]'), '-');
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

  static List<CartLine> linesFrom(Map<String, dynamic>? cartData) {
    final linesMap = (cartData?['lines'] as Map?) ?? {};
    return linesMap.entries
        .map((e) =>
            CartLine.fromMap(e.key, (e.value as Map).cast<String, dynamic>()))
        .toList();
  }
}
