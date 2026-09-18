import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:flutter_application_1/pages/client/live_order_page.dart';
import 'package:flutter_application_1/pages/client/location_picker_sheet.dart';
import 'package:flutter_application_1/pages/client/select_location_page.dart';
import 'package:flutter_application_1/utils/store_cart_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// Sentinels for [_PushOrderPageState._selectedPaymentType] - anything else
/// is a `payment_types` doc id (an external provider), sent to the
/// `pushOrder` callable as-is.
const _cashPaymentType = 'cash_payment';
const _walletPaymentType = 'wallet_balance';

/// Checkout / order confirmation - review the cart one last time, pick the
/// delivery address and payment method, optionally apply a promo code, then
/// place the order. Reached from [CartPage]'s "Aller à la caisse" bar.
class PushOrderPage extends StatefulWidget {
  final String language;
  final String uid;
  final String storeId;
  const PushOrderPage(this.language, this.uid, this.storeId, {super.key});

  @override
  State<PushOrderPage> createState() => _PushOrderPageState();
}

class _PushOrderPageState extends State<PushOrderPage> with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _noteController = TextEditingController();
  final _promoController = TextEditingController();

  bool _isLoading = true;
  bool _hasError = false;

  Map<String, dynamic>? _cartData;
  Map<String, dynamic>? _store;
  Map<String, dynamic>? _user;
  Map<String, dynamic>? _cityDoc;

  // `payment_types` docs active for the delivery city (`lib/map.txt`) -
  // external providers shown as extra cards alongside cash/wallet.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _paymentTypeOptions = [];

  // Delivery address for this order - starts as the account's saved
  // address, but "Modifier" can point it somewhere else (a different saved
  // address, the device's current location, or a brand new one) without
  // necessarily needing to touch the account's own default first.
  double? _deliveryLat;
  double? _deliveryLng;
  String? _deliveryCity;
  String? _deliveryLocationName;

  // Either _cashPaymentType, _walletPaymentType, or a payment_types doc id.
  String _selectedPaymentType = _cashPaymentType;

  Map<String, dynamic>? _appliedPromo;
  String? _promoError;
  bool _isApplyingPromo = false;
  bool _isChangingAddress = false;
  bool _isPlacingOrder = false;

  // One key per checkout attempt on this page, minted locally (no network
  // call - Firestore's `.doc().id` just generates a random id client-side)
  // and reused on every retry of THIS attempt (a network drop right after
  // a successful charge, a double-tap before the button disables, ...), so
  // `pushOrder` can tell a retry apart from a genuinely new order and
  // replay the first result instead of charging/creating twice.
  final String _idempotencyKey =
      FirebaseFirestore.instance.collection('idempotency_keys').doc().id;

  /// The summary card's numbers (and the push-order button) go stale the
  /// moment either of these starts - a new address can change
  /// delivery/service fees (different city) and the distance-based fee,
  /// and applying a promo changes the discount - so both show a skeleton
  /// and block submission until they resolve.
  bool get _isRecalculating => _isApplyingPromo || _isChangingAddress;

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _promoController.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var cartSnap =
          await StoreCartService.cartRef(widget.uid, widget.storeId).get();
      var cartData = cartSnap.data();
      if (cartData == null ||
          (cartData['lines'] as Map?)?.isEmpty != false ||
          cartData['waiting_payment'] == true) {
        if (mounted) setState(() => _hasError = true);
        return;
      }

      // Same re-validation cart_page.dart/store_details_page.dart already
      // do on open - an item (or a group option's price) could have
      // changed, or an item could have been deleted/deactivated, in the
      // time between adding it to the cart and reaching checkout. Re-fetch
      // afterwards since syncWithCatalog writes straight to Firestore
      // rather than returning the new lines itself.
      final syncResult =
          await StoreCartService.syncWithCatalog(widget.uid, widget.storeId);
      if (syncResult.removed > 0 || syncResult.updated > 0) {
        cartSnap =
            await StoreCartService.cartRef(widget.uid, widget.storeId).get();
        cartData = cartSnap.data();
        if (cartData == null || (cartData['lines'] as Map?)?.isEmpty != false) {
          if (mounted) setState(() => _hasError = true);
          return;
        }
      }

      final storeSnap =
          await _firestore.collection('stores').doc(widget.storeId).get();
      final store = storeSnap.data();
      if (store == null) {
        if (mounted) setState(() => _hasError = true);
        return;
      }

      final userSnap =
          await _firestore.collection('users').doc(widget.uid).get();
      final user = userSnap.data();
      final address = user?['address'] as Map<String, dynamic>?;
      final userCity = address?['city'] as String?;

      // Same rule store_details_page.dart/cart_page.dart already gate on
      // before checkout Dis even reachable - re-checked here too since the
      // user's city (or the store's) can still have changed in the moments
      // since.
      if (userCity == null || userCity != store['city']) {
        if (mounted) setState(() => _hasError = true);
        return;
      }

      final citySnap = await _firestore
          .collection('cities')
          .where('name', isEqualTo: userCity)
          .limit(1)
          .get();

      final paymentTypesSnap = await _firestore
          .collection('payment_types')
          .where('cities', arrayContains: userCity)
          .where('active', isEqualTo: true)
          .get();

      if (!mounted) return;
      setState(() {
        _cartData = cartData;
        _store = store;
        _user = user;
        _cityDoc = citySnap.docs.isNotEmpty ? citySnap.docs.first.data() : null;
        _paymentTypeOptions = paymentTypesSnap.docs;
        _deliveryLat = (address?['lat'] as num?)?.toDouble();
        _deliveryLng = (address?['lng'] as num?)?.toDouble();
        _deliveryCity = userCity;
        _deliveryLocationName = address?['location_name'] as String?;
        _selectedPaymentType =
            _cashAvailable ? _cashPaymentType : _walletPaymentType;
        _isLoading = false;
      });
      if (syncResult.removed > 0) {
        showAlert(
          TranslationHelper.get(
            syncResult.removed == 1
                ? 'cart_items_removed_one'
                : 'cart_items_removed_other',
            {'count': syncResult.removed},
          ),
          isError: true,
        );
      } else if (syncResult.updated > 0) {
        showAlert(
          TranslationHelper.get(
            syncResult.updated == 1
                ? 'cart_prices_updated_one'
                : 'cart_prices_updated_other',
            {'count': syncResult.updated},
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  List<CartLine> get _lines => StoreCartService.linesFrom(_cartData)
    ..sort((a, b) => a.lineKey.compareTo(b.lineKey));

  double get _subtotal => _lines.fold<double>(0, (acc, l) => acc + l.lineTotal);

  /// Flat `delivery_fee` plus `km_fee` × the straight-line distance to the
  /// store, plus `rain_fee` when `rain` is currently on (`cities`,
  /// `lib/map.txt`) - same formula the `pushOrder` function itself uses to
  /// compute the authoritative fee, so this preview doesn't undersell what
  /// the order will actually be charged. Distance-only reads store/delivery
  /// coordinates - `0` while either isn't known yet.
  double get _deliveryFee {
    final base = (_cityDoc?['delivery_fee'] as num?)?.toDouble() ?? 0;
    final kmFee = (_cityDoc?['km_fee'] as num?)?.toDouble() ?? 0;
    final rainFee = _cityDoc?['rain'] == true
        ? (_cityDoc?['rain_fee'] as num?)?.toDouble() ?? 0
        : 0;

    final storeLat = (_store?['lat'] as num?)?.toDouble();
    final storeLng = (_store?['lng'] as num?)?.toDouble();
    final distanceKm = (kmFee > 0 &&
            storeLat != null &&
            storeLng != null &&
            _deliveryLat != null &&
            _deliveryLng != null)
        ? _haversineKm(storeLat, storeLng, _deliveryLat!, _deliveryLng!)
        : 0.0;

    return base + kmFee * distanceKm + rainFee;
  }

  /// Matches the `pushOrder` function's own `haversineKm` exactly (see
  /// `lib/note.txt`), so the client's fee preview and the server's
  /// authoritative charge agree on distance.
  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double _degToRad(double deg) => deg * (math.pi / 180);

  double get _serviceFee => (_cityDoc?['service_fee'] as num?)?.toDouble() ?? 0;

  /// Cash requires the delivery city and the user account to currently
  /// allow it, AND the user to not owe a balance - a debt already blocks
  /// wallet payment (negative balance can't cover a positive total), and
  /// is now blocked from cash too (see `pushOrder`'s own check), so an
  /// indebted user must clear it through an external payment_types
  /// provider rather than cash a courier has to collect and might not.
  bool get _cashAvailable =>
      (_cityDoc?['cash_payment'] as bool? ?? true) &&
      (_user?['cash_payment'] as bool? ?? true) &&
      _deduction <= 0;

  double get _walletBalance =>
      (_user?['wallet_balance'] as num?)?.toDouble() ?? 0;

  double get _discount {
    final promo = _appliedPromo;
    if (promo == null) return 0;
    final type = promo['type'] as String?;
    final value = (promo['value'] as num?)?.toDouble() ?? 0;
    final maxDiscount = (promo['max_discount'] as num?)?.toDouble();
    double raw;
    if (type == 'free_delivery') {
      raw = _deliveryFee;
    } else {
      raw = _subtotal * (value / 100);
    }
    if (maxDiscount != null && maxDiscount > 0 && raw > maxDiscount) {
      raw = maxDiscount;
    }
    return raw;
  }

  /// Owed debt (a negative `wallet_balance`) that `pushOrder` ADDS on top
  /// of the order cost, same as its own `deduction` - mirrored here so the
  /// preview total isn't a lowball of what actually gets charged. Wallet
  /// payment already reads as unavailable whenever this is > 0, since
  /// `_walletBalance` (still negative) can never cover a positive `_total`.
  double get _deduction => _walletBalance < 0 ? -_walletBalance : 0;

  double get _total {
    final t = _subtotal + _deliveryFee + _serviceFee - _discount + _deduction;
    return t < 0 ? 0 : t;
  }

  Future<void> _pickAddress() async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LocationPickerSheet(
        uid: widget.uid,
        language: widget.language,
        activeCity: _deliveryCity,
        activeLocationName: _deliveryLocationName,
      ),
    );
    if (!mounted || result == null) return;

    if (result == 'add') {
      final picked = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SelectMapPage(widget.language, canCancel: true),
        ),
      );
      if (!mounted || picked is! Map || picked['city'] == null) return;
      await _applyPickedAddress(
        city: picked['city'] as String,
        lat: (picked['lat'] as num).toDouble(),
        lng: (picked['lng'] as num).toDouble(),
        locationName: null,
      );
      return;
    }

    if (result is Map) {
      final city = result['city'] as String?;
      final lat = (result['lat'] as num?)?.toDouble();
      final lng = (result['lng'] as num?)?.toDouble();
      if (city == null || lat == null || lng == null) return;
      await _applyPickedAddress(
        city: city,
        lat: lat,
        lng: lng,
        locationName: result['name'] as String?,
      );
    }
  }

  /// A newly picked address delivering outside the store's own city can't
  /// actually be delivered to (same rule as
  /// `OrderReorderService.citiesMatch`) - rejected here rather than applied
  /// and left for the (already-passed) checkout-open city gate to somehow
  /// catch later.
  Future<void> _applyPickedAddress({
    required String city,
    required double lat,
    required double lng,
    required String? locationName,
  }) async {
    if (city != _store?['city']) {
      showAlert(TranslationHelper.get('reorder_different_city'), isError: true);
      return;
    }

    setState(() => _isChangingAddress = true);
    try {
      final citySnap = await _firestore
          .collection('cities')
          .where('name', isEqualTo: city)
          .limit(1)
          .get();
      final paymentTypesSnap = await _firestore
          .collection('payment_types')
          .where('cities', arrayContains: city)
          .where('active', isEqualTo: true)
          .get();

      if (!mounted) return;
      setState(() {
        _deliveryCity = city;
        _deliveryLat = lat;
        _deliveryLng = lng;
        _deliveryLocationName = locationName;
        _cityDoc = citySnap.docs.isNotEmpty ? citySnap.docs.first.data() : null;
        _paymentTypeOptions = paymentTypesSnap.docs;
        if (_selectedPaymentType == _cashPaymentType && !_cashAvailable) {
          _selectedPaymentType = _walletPaymentType;
        }
      });
    } finally {
      if (mounted) setState(() => _isChangingAddress = false);
    }
  }

  Future<void> _applyPromo() async {
    final code = _promoController.text.trim().toUpperCase();
    if (code.isEmpty || _isApplyingPromo) return;
    setState(() {
      _isApplyingPromo = true;
      _promoError = null;
    });
    try {
      // Re-validate the cart itself first - the discount is computed off
      // `_subtotal`, so applying a promo against a subtotal that's about
      // to change the moment the cart re-syncs would validate (e.g.
      // min_order_value) against a number that's already stale.
      final syncResult =
          await StoreCartService.syncWithCatalog(widget.uid, widget.storeId);
      if (syncResult.removed > 0 || syncResult.updated > 0) {
        final cartSnap =
            await StoreCartService.cartRef(widget.uid, widget.storeId).get();
        final cartData = cartSnap.data();
        if (!mounted) return;
        if (cartData == null || (cartData['lines'] as Map?)?.isEmpty != false) {
          setState(() => _hasError = true);
          return;
        }
        setState(() => _cartData = cartData);
        showAlert(
          TranslationHelper.get(
            syncResult.removed > 0
                ? (syncResult.removed == 1
                    ? 'cart_items_removed_one'
                    : 'cart_items_removed_other')
                : (syncResult.updated == 1
                    ? 'cart_prices_updated_one'
                    : 'cart_prices_updated_other'),
            {
              'count': syncResult.removed > 0
                  ? syncResult.removed
                  : syncResult.updated
            },
          ),
          isError: syncResult.removed > 0,
        );
      }

      final error = await _validatePromo(code);
      if (!mounted) return;
      if (error != null) {
        setState(() {
          _promoError = error;
          _appliedPromo = null;
        });
      } else {
        setState(() => _promoError = null);
        showAlert(TranslationHelper.get('promo_applied_message'));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _promoError = TranslationHelper.get('promo_invalid_message');
          _appliedPromo = null;
        });
      }
    } finally {
      if (mounted) setState(() => _isApplyingPromo = false);
    }
  }

  /// Checks every rule a promo code can carry (`lib/map.txt`) - active,
  /// date window, overall/per-user usage limits, minimum order value, and
  /// whether it's scoped to this city/store at all. Sets [_appliedPromo]
  /// and returns null on success, or a user-facing message on failure.
  /// Re-run again (not just trusted from here) server-side inside
  /// `pushOrder` - same "don't trust a moment-old client check" reasoning
  /// as [OrderReorderService].
  Future<String?> _validatePromo(String code) async {
    final snap = await _firestore.collection('promotions').doc(code).get();
    final promo = snap.data();
    if (promo == null || promo['active'] != true) {
      return TranslationHelper.get('promo_invalid_message');
    }

    final now = DateTime.now();
    final startDate = (promo['start_date'] as Timestamp?)?.toDate();
    final endDate = (promo['end_date'] as Timestamp?)?.toDate();
    if (startDate != null && now.isBefore(startDate)) {
      return TranslationHelper.get('promo_invalid_message');
    }
    if (endDate != null && now.isAfter(endDate)) {
      return TranslationHelper.get('promo_invalid_message');
    }

    final usageLimit = (promo['usage_limit'] as num?)?.toInt() ?? 0;
    final usageCount = (promo['usage_count'] as num?)?.toInt() ?? 0;
    if (usageLimit > 0 && usageCount >= usageLimit) {
      return TranslationHelper.get('promo_invalid_message');
    }

    final applicableTo = promo['applicable_to'] as Map<String, dynamic>?;
    final all = applicableTo?['all'] == true;
    final cities =
        (applicableTo?['cities'] as List?)?.cast<String>() ?? const [];
    final stores =
        (applicableTo?['stores'] as List?)?.cast<String>() ?? const [];
    final inScope = all ||
        (_deliveryCity != null && cities.contains(_deliveryCity)) ||
        stores.contains(widget.storeId);
    if (!inScope) {
      return TranslationHelper.get('promo_invalid_message');
    }

    final minOrderValue = (promo['min_order_value'] as num?)?.toDouble() ?? 0;
    if (minOrderValue > 0 && _subtotal < minOrderValue) {
      return TranslationHelper.get('promo_min_order_message', {
        'amount': minOrderValue.toStringAsFixed(0),
        'currency': TranslationHelper.get('currency_unit'),
      });
    }

    final userLimit = (promo['user_limit'] as num?)?.toInt() ?? 0;
    if (userLimit > 0) {
      final userPromoSnap = await _firestore
          .collection('user_promotions')
          .doc('${widget.uid}_$code')
          .get();
      final usedCount =
          (userPromoSnap.data()?['used_count'] as num?)?.toInt() ?? 0;
      if (usedCount >= userLimit) {
        return TranslationHelper.get('promo_invalid_message');
      }
    }

    if (mounted) setState(() => _appliedPromo = {...promo, 'code': code});
    return null;
  }

  Future<void> _placeOrder() async {
    if (_isPlacingOrder || _isRecalculating || _lines.isEmpty) return;
    if (_deliveryLat == null || _deliveryLng == null || _deliveryCity == null) {
      showAlert(TranslationHelper.get('select_address_required'),
          isError: true);
      return;
    }
    if (_selectedPaymentType == _cashPaymentType && !_cashAvailable) {
      showAlert(TranslationHelper.get('cash_payment_unavailable'),
          isError: true);
      return;
    }
    if (_selectedPaymentType == _walletPaymentType && _walletBalance < _total) {
      showAlert(TranslationHelper.get('insufficient_wallet_balance'),
          isError: true);
      return;
    }

    final confirmed = await _confirmPlaceOrder();
    if (!mounted || confirmed != true) return;

    setState(() => _isPlacingOrder = true);
    try {
      // All money/inventory logic - re-pricing every line against live
      // data, computing fees, validating the promo, charging - happens
      // server-side in `pushOrder` (one callable shared by every payment
      // type). The client only ever sends its choices, never a computed
      // price - `_subtotal`/`_total` here are just the preview shown while
      // reviewing, not what actually gets charged.
      final result =
          await FirebaseFunctions.instance.httpsCallable('pushOrder').call({
        'store_id': widget.storeId,
        'payment_type': _selectedPaymentType,
        'promo_code': _appliedPromo?['code'],
        'notes': _noteController.text.trim(),
        'idempotency_key': _idempotencyKey,
        'delivery_address': {
          'lat': _deliveryLat,
          'lng': _deliveryLng,
          'city': _deliveryCity,
          'location_name': _deliveryLocationName,
        },
      });

      if (!mounted) return;
      final data = result.data as Map?;
      final orderId = data?['order_id'] as String?;
      final paymentUrl = data?['payment_url'] as String?;
      final paymentCode = data?['payment_code'] as String?;
      final paymentImage = data?['payment_image'] as String?;

      if (orderId != null) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => LiveOrderPage(widget.language, orderId),
          ),
          (route) => route.isFirst,
        );
      } else if (paymentUrl != null) {
        // An external provider (a payment_types entry) - the order is
        // created by that provider's own webhook once payment actually
        // completes, not synchronously here.
        await openExternalUrl(paymentUrl);
      } else if (paymentCode != null) {
        // Same async-provider shape as paymentUrl, but a code to show
        // instead of a link to open - the cart is already `waiting_payment`
        // by now (the server flips it the moment it mints this code), and
        // stays visible with this same code on OrdersListPage/CartPage
        // until the provider's own webhook confirms it and creates the
        // order.
        await _showPaymentCodeDialog(paymentCode, paymentImage);
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      } else {
        showAlert(TranslationHelper.get('error'), isError: true);
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        showAlert(_localizedError(e), isError: true);
      }
    } catch (_) {
      if (mounted) showAlert(TranslationHelper.get('error'), isError: true);
    } finally {
      if (mounted) setState(() => _isPlacingOrder = false);
    }
  }

  /// `pushOrder`'s errors are otherwise always in English - server logs
  /// need that, but a user shouldn't see it regardless of app language.
  /// Every checkout-flow HttpsError now carries a machine-readable `code`
  /// (see functions/handlers/_orderData.js orderError) in `details`, which
  /// this maps to `error_{code}` here, with any dynamic bits (a min-order
  /// amount, an item name, ...) filled in from `details.params`. Falls back
  /// to the raw English message only for an error this build doesn't know
  /// the code for yet (an older client hitting a newer server error).
  String _localizedError(FirebaseFunctionsException e) {
    final details = e.details;
    if (details is Map) {
      final code = details['code'];
      if (code is String) {
        final rawParams = details['params'];
        final params = rawParams is Map
            ? rawParams.map((k, v) => MapEntry(k.toString(), v))
            : null;
        if (code == 'min_order_not_met' && params != null) {
          params['currency'] = TranslationHelper.get('currency_unit');
        }
        return TranslationHelper.get('error_$code', params);
      }
    }
    return e.message ?? TranslationHelper.get('error');
  }

  Future<void> _showPaymentCodeDialog(String paymentCode, String? paymentImage) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFF3E0),
                    shape: BoxShape.circle,
                  ),
                  child: paymentImage != null && paymentImage.isNotEmpty
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: paymentImage,
                            fit: BoxFit.cover,
                            placeholder: (c, u) => const SizedBox.shrink(),
                            errorWidget: (c, u, e) => const Icon(
                                Icons.qr_code_2_rounded,
                                color: Color(0xFFFF9800),
                                size: 30),
                          ),
                        )
                      : const Icon(Icons.qr_code_2_rounded,
                          color: Color(0xFFFF9800), size: 30),
                ),
                const SizedBox(height: 18),
                Text(
                  TranslationHelper.get('payment_code_dialog_title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  TranslationHelper.get('payment_code_dialog_message'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    paymentCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFF9800),
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9800),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      TranslationHelper.get('ok'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmPlaceOrder() {
    final currency = TranslationHelper.get('currency_unit');
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFF3E0),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.receipt_long_rounded,
                      color: Color(0xFFFF9800), size: 30),
                ),
                const SizedBox(height: 18),
                Text(
                  TranslationHelper.get('place_order_button'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_total.toStringAsFixed(0)} $currency',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF9800),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          side: const BorderSide(color: Color(0xFFE1E4E9)),
                        ),
                        child: Text(
                          TranslationHelper.get('cancel'),
                          style: const TextStyle(
                            color: Color(0xFF2E3A59),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF9800),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          TranslationHelper.get('place_order_button'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _hasError
                  ? _buildErrorState()
                  : Stack(
                      children: [
                        // Blocks every tap on the page (address, promo,
                        // payment method, back button, ...) the moment the
                        // order is sent - not just the place-order button -
                        // so nothing else can change underneath a request
                        // that's already in flight, until pushOrder
                        // actually resolves (success or error).
                        AbsorbPointer(
                          absorbing: _isPlacingOrder,
                          child: Column(
                            children: [
                              _buildAppBar(),
                              if (alertCard != null) alertCard!,
                              Expanded(child: _buildContent()),
                              _buildPlaceOrderBar(),
                            ],
                          ),
                        ),
                        if (_isPlacingOrder)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.15),
                              child: const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFFFF9800),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Column(
      children: [
        _buildAppBar(),
        Expanded(
          child: Center(
            child: Text(
              TranslationHelper.get('error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAppBar() {
    final storeNameAr = _cartData?['store_name_ar'] as String? ?? '';
    final storeNameFr = _cartData?['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : storeNameFr;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _isArabic
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: const Color(0xFFFF9800),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                TranslationHelper.get('confirm_order_title'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              if (storeName.isNotEmpty)
                Text(
                  storeName,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildSectionLabel('note_for_store_label'),
        const SizedBox(height: 8),
        _buildNoteField(),
        const SizedBox(height: 20),
        _buildSectionLabel('delivery_address_label'),
        const SizedBox(height: 8),
        _buildAddressCard(),
        const SizedBox(height: 20),
        _buildSectionLabel('payment_method_label'),
        const SizedBox(height: 8),
        _buildPaymentMethods(),
        const SizedBox(height: 20),
        _buildSectionLabel('promo_code_label'),
        const SizedBox(height: 8),
        _buildPromoField(),
        const SizedBox(height: 20),
        _buildSectionLabel('order_summary_label'),
        const SizedBox(height: 8),
        _buildSummaryCard(),
      ],
    );
  }

  Widget _buildSectionLabel(String key) {
    return Align(
      alignment: _isArabic ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        TranslationHelper.get(key).toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildNoteField() {
    return TextField(
      controller: _noteController,
      maxLines: 3,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: TranslationHelper.get('note_for_store_hint'),
        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.all(14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildAddressCard() {
    final hasPoint = _deliveryLat != null && _deliveryLng != null;
    final label = (_deliveryLocationName?.isNotEmpty ?? false)
        ? '${_deliveryCity ?? ''}, $_deliveryLocationName'
        : (_deliveryCity ?? '');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: SizedBox(
              height: 110,
              width: double.infinity,
              child: hasPoint
                  ? IgnorePointer(
                      child: GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: LatLng(_deliveryLat!, _deliveryLng!),
                          zoom: 15,
                        ),
                        markers: {
                          Marker(
                            markerId: const MarkerId('delivery'),
                            position: LatLng(_deliveryLat!, _deliveryLng!),
                          ),
                        },
                        zoomControlsEnabled: false,
                        myLocationButtonEnabled: false,
                        scrollGesturesEnabled: false,
                        zoomGesturesEnabled: false,
                        rotateGesturesEnabled: false,
                        tiltGesturesEnabled: false,
                      ),
                    )
                  : Container(color: const Color(0xFFEDEFF2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.location_on,
                    color: Color(0xFFFF9800), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
                InkWell(
                  onTap: _pickAddress,
                  child: Text(
                    TranslationHelper.get('modify_button'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFF9800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentMethods() {
    final walletEnabled = _walletBalance >= _total;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildPaymentRow(
            icon: Icons.payments_outlined,
            label: TranslationHelper.get('payment_type_cash'),
            value: _cashPaymentType,
            enabled: _cashAvailable,
          ),
          const Divider(height: 1, color: Color(0xFFEDEFF2)),
          _buildPaymentRow(
            icon: Icons.account_balance_wallet_outlined,
            label: TranslationHelper.get('payment_type_wallet_balance'),
            trailing:
                '${_walletBalance.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
            value: _walletPaymentType,
            enabled: walletEnabled,
          ),
          for (final doc in _paymentTypeOptions) ...[
            const Divider(height: 1, color: Color(0xFFEDEFF2)),
            _buildPaymentRow(
              imageUrl: doc.data()['image'] as String?,
              label: (_isArabic ? doc.data()['name_ar'] : doc.data()['name'])
                      as String? ??
                  doc.data()['name'] as String? ??
                  '',
              value: doc.id,
              enabled: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPaymentRow({
    IconData? icon,
    String? imageUrl,
    required String label,
    required String value,
    required bool enabled,
    String? trailing,
  }) {
    final selected = _selectedPaymentType == value;
    return InkWell(
      onTap:
          enabled ? () => setState(() => _selectedPaymentType = value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  width: 20,
                  height: 20,
                  fit: BoxFit.cover,
                  errorWidget: (c, u, e) => Icon(Icons.credit_card,
                      size: 18,
                      color: enabled
                          ? const Color(0xFF9AA1AC)
                          : const Color(0xFFC9CDD4)),
                ),
              )
            else
              Icon(icon ?? Icons.credit_card,
                  size: 18,
                  color: enabled
                      ? const Color(0xFF9AA1AC)
                      : const Color(0xFFC9CDD4)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: enabled
                      ? const Color(0xFF2E3A59)
                      : const Color(0xFFC9CDD4),
                ),
              ),
            ),
            if (trailing != null) ...[
              Text(
                trailing,
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
              ),
              const SizedBox(width: 10),
            ],
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: !enabled
                  ? const Color(0xFFE1E4E9)
                  : (selected
                      ? const Color(0xFFFF9800)
                      : const Color(0xFFC9CDD4)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPromoField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _promoController,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: TranslationHelper.get('promo_code_hint'),
                  hintStyle:
                      const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _isApplyingPromo ? null : _applyPromo,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9800),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: _isApplyingPromo
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Text(
                        TranslationHelper.get('apply_button'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
              ),
            ),
          ],
        ),
        if (_promoError != null) ...[
          const SizedBox(height: 6),
          Text(
            _promoError!,
            style: const TextStyle(fontSize: 12, color: Color(0xFFE74C3C)),
          ),
        ] else if (_appliedPromo != null) ...[
          const SizedBox(height: 6),
          Text(
            '${_appliedPromo!['code']} ✓',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1B8A3E)),
          ),
        ],
      ],
    );
  }

  Widget _buildSummaryCard() {
    final currency = TranslationHelper.get('currency_unit');
    final loading = _isRecalculating;

    Widget bar({double width = 60, double height = 12}) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFEDEFF2),
            borderRadius: BorderRadius.circular(6),
          ),
        );

    Widget row(String labelKey, double value, {bool negative = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              TranslationHelper.get(labelKey),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
            ),
            loading
                ? bar()
                : Text(
                    '${negative ? '-' : ''}${value.toStringAsFixed(0)} $currency',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: negative
                          ? const Color(0xFF1B8A3E)
                          : const Color(0xFF2E3A59),
                    ),
                  ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          row('subtotal_label', _subtotal),
          row('delivery_fee_label', _deliveryFee),
          row('service_fee_label', _serviceFee),
          if (!loading && _discount > 0)
            row('discount_label', _discount, negative: true),
          if (!loading && _deduction > 0) row('deduction_label', _deduction),
          const Divider(height: 20, color: Color(0xFFEDEFF2)),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  TranslationHelper.get('total_label'),
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59)),
                ),
                loading
                    ? bar(width: 80, height: 16)
                    : Text(
                        '${_total.toStringAsFixed(0)} $currency',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFFF9800)),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceOrderBar() {
    final currency = TranslationHelper.get('currency_unit');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed:
                (_isPlacingOrder || _isRecalculating) ? null : _placeOrder,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF9800),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFFFC98A),
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: _isPlacingOrder
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        TranslationHelper.get('place_order_button'),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '${_total.toStringAsFixed(0)} $currency',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
