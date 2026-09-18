import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_application_1/pages/shared/chat_page.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/directions_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// The driver's own step-by-step progression through a delivery - assigned
/// (set the moment an offer is accepted, see DeliveryOfferService) through
/// to delivered, at which point the order ends and this driver's lifetime
/// completed_orders/status are updated. This is the only place
/// that can advance it - DeliveryOrdersPage's list is read-only.
const _deliveryStatusOrder = [
  'assigned',
  'arrived_to_store',
  'picked_up',
  'on_the_way',
  'arrived',
  'delivered',
];

String? _nextDeliveryStatus(String current) {
  final i = _deliveryStatusOrder.indexOf(current);
  if (i < 0 || i >= _deliveryStatusOrder.length - 1) return null;
  return _deliveryStatusOrder[i + 1];
}

bool _hasPickedUp(String status) {
  final i = _deliveryStatusOrder.indexOf(status);
  return i >= _deliveryStatusOrder.indexOf('picked_up');
}

/// One order's full delivery view - route map, pickup/dropoff, articles,
/// cost breakdown, and the single action that advances delivery_status one
/// step at a time. "Annuler la livraison" only shows before pickup - once
/// the order is physically in hand, cancelling isn't offered (see
/// _hasPickedUp); the driver gets "Appeler le support" instead.
class DeliveryOrderDetailPage extends StatefulWidget {
  final String language;
  final String orderId;
  const DeliveryOrderDetailPage(this.language, this.orderId, {super.key});

  @override
  State<DeliveryOrderDetailPage> createState() => _DeliveryOrderDetailPageState();
}

class _DeliveryOrderDetailPageState extends State<DeliveryOrderDetailPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _orderStream =
      _firestore.collection('orders').doc(widget.orderId).snapshots();

  // The driver's own live position, for routing "here -> store" or
  // "here -> dropoff" depending on pickup progress - not just a fixed
  // store/dropoff-to-store line.
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _deliveryStream =
      _firestore.collection('delivery').doc(_uid).snapshots();

  String? _customerName;
  String? _customerPhone;
  String? _storeLocationName;
  String? _storePhone;
  String? _resolvedForOrderId;
  bool _isAdvancing = false;

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  /// Customer name / store location_name aren't on the order doc itself -
  /// resolved once per order (not on every snapshot) and cached locally.
  Future<void> _resolveNamesIfNeeded(Map<String, dynamic> data) async {
    if (_resolvedForOrderId == widget.orderId) return;
    _resolvedForOrderId = widget.orderId;
    final userId = data['user_id'] as String?;
    final storeId = data['store_id'] as String?;
    try {
      final results = await Future.wait([
        userId != null
            ? _firestore.collection('users').doc(userId).get()
            : Future.value(null),
        storeId != null
            ? _firestore.collection('stores').doc(storeId).get()
            : Future.value(null),
      ]);
      final userSnap = results[0];
      final storeSnap = results[1];
      if (!mounted) return;
      setState(() {
        _customerName = userSnap?.data()?['name'] as String?;
        _customerPhone = userSnap?.data()?['phone'] as String?;
        _storeLocationName = storeSnap?.data()?['location_name'] as String?;
        _storePhone = storeSnap?.data()?['phone'] as String?;
      });
    } catch (_) {
      // Non-critical - the page still works with coordinates as a fallback.
    }
  }

  /// Goes through the `advanceDeliveryStatus` Cloud Function - it re-checks
  /// order.delivery_id == this driver's own uid server-side (never trust
  /// the client), enforces the transition is actually this order's own
  /// valid next step, and - only for the final "delivered" step - credits
  /// this driver's payout_balance for the delivery in the same transaction.
  Future<void> _advance(String next) async {
    if (_isAdvancing) return;
    setState(() => _isAdvancing = true);
    try {
      await FirebaseFunctions.instance.httpsCallable('advanceDeliveryStatus').call({
        'order_id': widget.orderId,
        'new_status': next,
      });
      if (next == 'delivered' && mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isAdvancing = false);
    }
  }

  /// Cash orders need one more confirmation before "delivered" actually
  /// fires - the driver has to attest they actually collected the cash,
  /// since that's what flips the order's users_transactions record to
  /// "completed" server-side (advanceDeliveryStatus). Wallet-paid orders
  /// (already settled at checkout) skip straight to _advance.
  Future<void> _confirmThenAdvance(String next, {required bool isCashPayment}) async {
    if (!isCashPayment) return _advance(next);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(TranslationHelper.get('delivery_cash_confirm_title')),
          content: Text(TranslationHelper.get('delivery_cash_confirm_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(TranslationHelper.get('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                TranslationHelper.get('delivery_cash_confirm_yes'),
                style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) await _advance(next);
  }

  Future<void> _cancelDelivery() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(TranslationHelper.get('delivery_cancel_title')),
          content: Text(TranslationHelper.get('delivery_cancel_message')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(TranslationHelper.get('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                TranslationHelper.get('delivery_cancel_confirm'),
                style: const TextStyle(color: Color(0xFFE74C3C)),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      await FirebaseFunctions.instance
          .httpsCallable('cancelDeliveryAssignment')
          .call({'order_id': widget.orderId});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    }
  }

  void _callPhone(String? phone) {
    if (phone == null || phone.isEmpty) return;
    launchUrl(Uri(scheme: 'tel', path: phone));
  }

  /// Lazily creates the conversation (startOrderConversation) the first
  /// time either side opens chat for this order, then opens it - same
  /// behavior as LiveOrderPage's own _openChat.
  bool _openingChat = false;

  Future<void> _openChat(Map<String, dynamic> data) async {
    if (_openingChat) return;
    setState(() => _openingChat = true);
    try {
      var conversationId = data['conversation_id'] as String?;
      if (conversationId == null || conversationId.isEmpty) {
        final result = await FirebaseFunctions.instance
            .httpsCallable('startOrderConversation')
            .call({'order_id': widget.orderId});
        conversationId = result.data['conversation_id'] as String?;
      }
      if (conversationId == null || conversationId.isEmpty) {
        if (mounted) showAlert(TranslationHelper.get('conversation_not_started'), isError: true);
        return;
      }
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatPage(widget.language, conversationId!, _customerName ?? ''),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _orderStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _buildErrorState(snapshot.error!);
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!.data();
            if (data == null) {
              return _buildErrorState(StateError('order-not-found'));
            }
            _resolveNamesIfNeeded(data);
            return Column(
              children: [
                if (alertCard != null) alertCard!,
                Expanded(child: _buildContent(data)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildErrorState(Object error) {
    return Column(
      children: [
        _buildBackButton(),
        Expanded(
          child: Center(
            child: Text(
              TranslationHelper.get(isConnectivityError(error) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackButton() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: _isArabic ? Alignment.topRight : Alignment.topLeft,
          child: InkWell(
            borderRadius: BorderRadius.circular(19),
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: Icon(
                _isArabic ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: const Color(0xFF2E3A59),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(Map<String, dynamic> data) {
    final storeAddress = (data['store_address'] as Map?)?.cast<String, dynamic>();
    final userAddress = (data['user_address'] as Map?)?.cast<String, dynamic>();
    final storeLat = (storeAddress?['lat'] as num?)?.toDouble();
    final storeLng = (storeAddress?['lng'] as num?)?.toDouble();
    final userLat = (userAddress?['lat'] as num?)?.toDouble();
    final userLng = (userAddress?['lng'] as num?)?.toDouble();
    final status = data['delivery_status'] as String? ?? 'assigned';
    final pickedUp = _hasPickedUp(status);

    return Column(
      children: [
        Stack(
          children: [
            SizedBox(
              height: 220,
              child: (storeLat != null && storeLng != null && userLat != null && userLng != null)
                  ? StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: _deliveryStream,
                      builder: (context, deliverySnap) {
                        final deliveryData = deliverySnap.data?.data();
                        final driverLat = (deliveryData?['lat'] as num?)?.toDouble();
                        final driverLng = (deliveryData?['lng'] as num?)?.toDouble();
                        return _RouteMap(
                          storeLat: storeLat,
                          storeLng: storeLng,
                          userLat: userLat,
                          userLng: userLng,
                          driverLat: driverLat,
                          driverLng: driverLng,
                          // Not yet picked up - route to the store; once
                          // picked up, route to the dropoff instead.
                          routeToStore: !pickedUp,
                        );
                      },
                    )
                  : Container(color: const Color(0xFFE9ECF2)),
            ),
            _buildBackButton(),
          ],
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: _buildDetails(data),
          ),
        ),
      ],
    );
  }

  Widget _buildDetails(Map<String, dynamic> data) {
    final orderNumber = data['order_number'] as String? ?? widget.orderId;
    final status = data['delivery_status'] as String? ?? 'assigned';
    final storeName = _isArabic
        ? (data['store_name_ar'] as String? ?? '')
        : (data['store_name_fr'] as String? ?? '');
    final userAddress = (data['user_address'] as Map?)?.cast<String, dynamic>();
    final lines = (data['lines'] as Map?) ?? {};
    final subtotal = (data['subtotal'] as num?) ?? 0;
    final deliveryFee = (data['delivery_fee'] as num?) ?? 0;
    final total = (data['total'] as num?) ?? 0;
    final currency = TranslationHelper.get('currency_unit');
    final next = _nextDeliveryStatus(status);
    final pickedUp = _hasPickedUp(status);
    final orderStatus = data['order_status'] as String? ?? 'placed';
    final isCashPayment = data['payment_type'] == 'cash_payment';
    // Can't pick up food the store hasn't marked ready yet - mirrors the
    // same gate advanceDeliveryStatus enforces server-side.
    final waitingForReady = next == 'picked_up' && orderStatus != 'ready';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                TranslationHelper.get('order_number_label', {'number': orderNumber}),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                TranslationHelper.get('delivery_status_$status'),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFFF9800),
                ),
              ),
            ),
          ],
        ),
        if (isCashPayment) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.payments_rounded, size: 15, color: Color(0xFF2E7D32)),
                const SizedBox(width: 6),
                Text(
                  TranslationHelper.get('order_payment_cash_label'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2E7D32),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        _buildSectionLabel('delivery_pickup_section'),
        const SizedBox(height: 8),
        _buildWaypointCard(
          icon: Icons.storefront_rounded,
          title: storeName,
          subtitle: _storeLocationName ?? '',
          actions: [
            _buildIconButton(
              icon: Icons.phone_rounded,
              onTap: _storePhone == null || _storePhone!.isEmpty
                  ? null
                  : () => _callPhone(_storePhone),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildSectionLabel('delivery_dropoff_section'),
        const SizedBox(height: 8),
        _buildWaypointCard(
          icon: Icons.person_pin_circle_rounded,
          title: _customerName ?? '',
          subtitle: userAddress != null
              ? TranslationHelper.get('delivery_dropoff_label', {
                  'lat': (userAddress['lat'] as num?)?.toStringAsFixed(4) ?? '',
                  'lng': (userAddress['lng'] as num?)?.toStringAsFixed(4) ?? '',
                })
              : '',
          actions: [
            _buildIconButton(
              icon: Icons.phone_rounded,
              onTap: _customerPhone == null || _customerPhone!.isEmpty
                  ? null
                  : () => _callPhone(_customerPhone),
            ),
            const SizedBox(width: 8),
            _buildIconButton(
              icon: Icons.chat_bubble_outline_rounded,
              onTap: () => _openChat(data),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _buildSectionLabel('delivery_articles_section'),
        const SizedBox(height: 8),
        for (final entry in lines.entries) _buildLine(entry.value),
        const Divider(height: 24, color: Color(0xFFF0F1F4)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              TranslationHelper.get('order_cost_breakdown', {
                'subtotal': subtotal.toStringAsFixed(0),
                'delivery': deliveryFee.toStringAsFixed(0),
              }),
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
            ),
            Text(
              '${total.toStringAsFixed(0)} $currency',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        if (next != null) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_isAdvancing || waitingForReady)
                  ? null
                  : () => next == 'delivered'
                      ? _confirmThenAdvance(next, isCashPayment: isCashPayment)
                      : _advance(next),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFFFD9A6),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _isAdvancing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                    )
                  : Text(
                      TranslationHelper.get('delivery_action_$next'),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
            ),
          ),
          if (waitingForReady) ...[
            const SizedBox(height: 6),
            Text(
              TranslationHelper.get('delivery_action_not_ready_hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
            ),
          ],
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: pickedUp
                ? () => showAlert(TranslationHelper.get('support_coming_soon'))
                : _cancelDelivery,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(
              TranslationHelper.get(
                  pickedUp ? 'delivery_call_support_button' : 'delivery_cancel_button'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFFE74C3C),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLabel(String key) => Text(
        TranslationHelper.get(key),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      );

  Widget _buildWaypointCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> actions,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: const Color(0xFFFF9800)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isNotEmpty ? title : TranslationHelper.get('unknown_store'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }

  Widget _buildIconButton({required IconData icon, VoidCallback? onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3E0),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          size: 17,
          color: onTap == null ? const Color(0xFFC9CDD4) : const Color(0xFFFF9800),
        ),
      ),
    );
  }

  Widget _buildLine(dynamic rawLine) {
    final line = (rawLine as Map).cast<String, dynamic>();
    final nameAr = line['name_ar'] as String? ?? '';
    final nameFr = line['name_fr'] as String? ?? '';
    final name = _isArabic && nameAr.isNotEmpty ? nameAr : nameFr;
    final quantity = (line['quantity'] as num?)?.toInt() ?? 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '${quantity}x $name',
        style: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFF2E3A59),
        ),
      ),
    );
  }
}

/// Store, dropoff, and the driver's own live position always show as
/// markers (using the app's own icon assets - store.png/home.png/motor.png),
/// and the camera always fits all three. Only the actual routed line
/// targets just one of them at a time: the store before pickup, the
/// dropoff after - driven by [routeToStore]. Falls back to a plain dashed
/// straight line to that same target if the driver's own position isn't
/// known yet or the Directions request fails, rather than showing nothing.
class _RouteMap extends StatefulWidget {
  final double storeLat;
  final double storeLng;
  final double userLat;
  final double userLng;
  final double? driverLat;
  final double? driverLng;
  final bool routeToStore;

  const _RouteMap({
    required this.storeLat,
    required this.storeLng,
    required this.userLat,
    required this.userLng,
    required this.driverLat,
    required this.driverLng,
    required this.routeToStore,
  });

  @override
  State<_RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<_RouteMap> {
  // Re-requesting on every GPS tick (every 5s while a delivery is active -
  // see DeliveryOfferService) would mean each new request supersedes the
  // last before it can land, via the request-id check below, and the map
  // would never show anything but the fallback. Only actually worth a new
  // Directions call when the target changes, or the driver has moved far
  // enough that the old route is stale.
  static const _refetchThresholdMeters = 60;

  GoogleMapController? _controller;
  List<LatLng>? _routePoints;
  bool _routeFailed = false;
  LatLng? _lastFetchOrigin;
  LatLng? _lastFetchDestination;
  int _requestId = 0;

  // The camera is only ever fit automatically once - when the page first
  // has enough data to frame (or when the routed target actually changes,
  // e.g. pickup happening switches the route from "to store" to "to
  // dropoff") - not on every GPS tick after that. Re-fitting on every
  // location update would keep rescaling/panning the map out from under
  // whoever's looking at it (same reasoning as LiveOrderPage's own
  // _maybeFitCamera).
  bool _hasFittedBounds = false;

  // Shared across every _RouteMap instance for the app's lifetime - the
  // three PNGs never change, so there's no reason to re-decode them each
  // time this page opens.
  static Future<Map<String, BitmapDescriptor>>? _iconsFuture;
  Map<String, BitmapDescriptor>? _icons;
  bool _iconsRequested = false;

  @override
  void initState() {
    super.initState();
    _maybeFetchRoute();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_iconsRequested) return;
    _iconsRequested = true;
    final configuration = createLocalImageConfiguration(context);
    _iconsFuture ??= () async {
      const size = 42.0;
      final results = await Future.wait([
        BitmapDescriptor.asset(configuration, 'assets/store.png', width: size, height: size),
        BitmapDescriptor.asset(configuration, 'assets/home.png', width: size, height: size),
        BitmapDescriptor.asset(configuration, 'assets/motor.png', width: size, height: size),
      ]);
      return {'store': results[0], 'user': results[1], 'driver': results[2]};
    }();
    _iconsFuture!.then((icons) {
      if (mounted) setState(() => _icons = icons);
    });
  }

  @override
  void didUpdateWidget(covariant _RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeFetchRoute(force: oldWidget.routeToStore != widget.routeToStore);
  }

  LatLng get _destination => widget.routeToStore
      ? LatLng(widget.storeLat, widget.storeLng)
      : LatLng(widget.userLat, widget.userLng);

  // The map always shows all three points (driver/store/dropoff) - only
  // the routed line targets whichever of store/dropoff is next.
  List<LatLng> get _allPoints => [
        LatLng(widget.storeLat, widget.storeLng),
        LatLng(widget.userLat, widget.userLng),
        if (widget.driverLat != null && widget.driverLng != null)
          LatLng(widget.driverLat!, widget.driverLng!),
      ];

  Future<void> _maybeFetchRoute({bool force = false}) async {
    final driverLat = widget.driverLat;
    final driverLng = widget.driverLng;
    if (driverLat == null || driverLng == null) {
      // Store+dropoff only for now (both static) - deliberately NOT marked
      // as the definitive initial fit yet, so once the driver's actual
      // position arrives moments later it still gets one real fit that
      // includes them, instead of being stuck outside a frame that was
      // "already done" before their position was even known.
      if (!_hasFittedBounds) _fitBounds(_allPoints);
      return;
    }

    final origin = LatLng(driverLat, driverLng);
    final destination = _destination;

    if (!force && _lastFetchOrigin != null && _lastFetchDestination == destination) {
      final movedMeters = DirectionsService.distanceKm(
            _lastFetchOrigin!.latitude,
            _lastFetchOrigin!.longitude,
            origin.latitude,
            origin.longitude,
          ) *
          1000;
      // Not worth a fresh Directions call yet, and - regardless of that -
      // never a reason to re-fit the camera either: that only ever happens
      // on the initial fit or an actual target change (see `shouldFit`
      // below), not a routine GPS tick.
      if (movedMeters < _refetchThresholdMeters) return;
    }

    final shouldFit = force || !_hasFittedBounds;

    final requestId = ++_requestId;
    _lastFetchOrigin = origin;
    _lastFetchDestination = destination;
    if (force) {
      setState(() {
        _routePoints = null;
        _routeFailed = false;
      });
    }
    if (shouldFit) {
      // Frame all three points immediately, before the Directions round
      // trip even starts - it might fail (or just take a moment), and the
      // camera shouldn't sit on a stale/partial view in the meantime. A
      // successful route below re-fits to the tighter, road-following
      // bounds instead.
      _fitBounds(_allPoints);
      _hasFittedBounds = true;
    }

    final route = await DirectionsService.getRoute(origin, destination);
    if (!mounted || requestId != _requestId) return;
    setState(() {
      _routePoints = route;
      _routeFailed = route == null;
    });
    if (route != null && shouldFit) _fitBounds([..._allPoints, ...route]);
  }

  // Cached so onMapCreated can (re-)apply the latest fit if the native map
  // view isn't ready yet when _maybeFetchRoute first computes it - whichever
  // of the two fires second is what actually gets the camera framed
  // correctly, instead of only ever reacting to a successful route fetch.
  List<LatLng>? _lastFitPoints;

  void _fitBounds(List<LatLng> points) {
    _lastFitPoints = points;
    final controller = _controller;
    if (controller == null || points.isEmpty) return;
    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    final bounds = LatLngBounds(
      southwest: LatLng(lats.reduce((a, b) => a < b ? a : b), lngs.reduce((a, b) => a < b ? a : b)),
      northeast: LatLng(lats.reduce((a, b) => a > b ? a : b), lngs.reduce((a, b) => a > b ? a : b)),
    );
    Future.delayed(const Duration(milliseconds: 200), () {
      controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
    });
  }

  @override
  Widget build(BuildContext context) {
    final storePos = LatLng(widget.storeLat, widget.storeLng);
    final userPos = LatLng(widget.userLat, widget.userLng);
    final driverPos = (widget.driverLat != null && widget.driverLng != null)
        ? LatLng(widget.driverLat!, widget.driverLng!)
        : null;

    // Always all three - store, dropoff, and the driver's own live
    // position - using the app's own icon assets, with a plain colored pin
    // as a fallback for whichever ones haven't finished loading yet.
    final markers = {
      Marker(
        markerId: const MarkerId('store'),
        position: storePos,
        icon: _icons?['store'] ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
      ),
      Marker(
        markerId: const MarkerId('user'),
        position: userPos,
        icon: _icons?['user'] ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ),
      if (driverPos != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: driverPos,
          icon: _icons?['driver'] ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
    };

    final polylines = <Polyline>{};
    if (_routePoints != null) {
      polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: _routePoints!,
        color: const Color(0xFFFF9800),
        width: 4,
      ));
    } else if (driverPos != null && _routeFailed) {
      polylines.add(Polyline(
        polylineId: const PolylineId('route_fallback'),
        points: [driverPos, _destination],
        color: const Color(0xFFFF9800),
        width: 3,
        patterns: [PatternItem.dash(16), PatternItem.gap(10)],
      ));
    }

    return GoogleMap(
      initialCameraPosition:
          CameraPosition(target: driverPos ?? (widget.routeToStore ? storePos : userPos), zoom: 14),
      onMapCreated: (controller) {
        _controller = controller;
        // Re-applies whatever _maybeFetchRoute already computed (it may
        // well have run before this native view existed to receive it),
        // or just frames the store+dropoff if the driver's position isn't
        // known yet.
        _fitBounds(_lastFitPoints ?? _allPoints);
      },
      markers: markers,
      polylines: polylines,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
    );
  }
}
