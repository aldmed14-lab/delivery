import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_application_1/pages/shared/chat_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';

/// One step in the delivery timeline shown on this page. Unlike
/// [OrdersListPage]'s own `_OrderStage` (which also covers "placed", for
/// the compact list card), this page never renders before an order has at
/// least been accepted, so it starts one step later. `delivery_status`
/// "pending"/"assigned"/"arrived_to_store"/"picked_up" (`lib/map.txt`) all
/// read the same as "ready" here - none of them get their own step (the
/// `default:` case in `_stageIndexOf` below catches "picked_up" too, not
/// just the switch's explicitly listed cases).
enum _DeliveryStage {
  accepted,
  preparing,
  ready,
  onTheWay,
  arrived,
  delivered,
}

/// -1 when the order hasn't been accepted yet (nothing in the timeline is
/// reached).
int _stageIndexOf(Map<String, dynamic> data) {
  final orderStatus = data['order_status'] as String? ?? 'placed';
  switch (orderStatus) {
    case 'placed':
      return -1;
    case 'accepted':
      return _DeliveryStage.accepted.index;
    case 'preparing':
      return _DeliveryStage.preparing.index;
    default:
      final deliveryStatus = data['delivery_status'] as String? ?? 'pending';
      switch (deliveryStatus) {
        case 'on_the_way':
          return _DeliveryStage.onTheWay.index;
        case 'arrived':
          return _DeliveryStage.arrived.index;
        case 'delivered':
          return _DeliveryStage.delivered.index;
        default: // "pending" | "assigned" | "arrived_to_store" | "picked_up"
          return _DeliveryStage.ready.index;
      }
  }
}

String _stageLabelKey(_DeliveryStage stage) {
  switch (stage) {
    case _DeliveryStage.accepted:
      return 'order_status_accepted_label';
    case _DeliveryStage.preparing:
      return 'order_status_preparing_label';
    case _DeliveryStage.ready:
      return 'order_status_ready_label';
    case _DeliveryStage.onTheWay:
      return 'order_status_on_the_way_label';
    case _DeliveryStage.arrived:
      return 'order_status_arrived_label';
    case _DeliveryStage.delivered:
      return 'order_status_delivered';
  }
}

/// The matching field on `orders` (`lib/map.txt`) for the moment each stage
/// was reached - null for stages the schema has no dedicated timestamp for
/// ("preparing" has none of its own; "arrived" - at the customer's
/// location - has none either, only the final `delivered_at`).
String? _stageTimestampField(_DeliveryStage stage) {
  switch (stage) {
    case _DeliveryStage.accepted:
      return 'accepted_at';
    case _DeliveryStage.preparing:
      return null;
    case _DeliveryStage.ready:
      return 'ready_at';
    case _DeliveryStage.onTheWay:
      return 'picked_up_at';
    case _DeliveryStage.arrived:
      return null;
    case _DeliveryStage.delivered:
      return 'delivered_at';
  }
}

/// The probable-completion label shown while an order is in progress
/// (`_buildEtaCard`/the "on the way" timeline row). Computed client-side,
/// not read from any stored field - `orders.estimated_delivery_time`
/// (`lib/map.txt`) is never actually written by anything, so reading it
/// directly always showed nothing.
class _EtaInfo {
  final String label;
  final bool isLate;
  // Minutes past the window's end - 0 while not late. Exposed (not just
  // folded into `label`) so callers can gate their own thresholds on it,
  // e.g. the "Call Admin" button only past 30 minutes late, not the moment
  // this label itself switches to "may be late".
  final int lateMinutes;
  const _EtaInfo(this.label, this.isLate, {this.lateMinutes = 0});
}

/// A 10-minute window - `accepted_at` (when prep started) + the store's own
/// `estimated_prep_time` (denormalized onto the order at acceptance, see
/// advanceOrderStatus.js) + a 15-25 min buffer for the courier search and
/// the actual delivery drive. Null if the order hasn't been accepted yet
/// (nothing to estimate from) or is already done. Once `now` passes the
/// window's end, this switches to a "may be running late" message instead
/// of a window that's already in the past.
_EtaInfo? _computeEta(Map<String, dynamic> data, DateTime now) {
  final acceptedAt = data['accepted_at'] as Timestamp?;
  if (acceptedAt == null) return null;

  final prepMinutes = (data['estimated_prep_time'] as num?) ?? 0;
  final base = acceptedAt.toDate().add(Duration(minutes: prepMinutes.round()));
  final windowStart = base.add(const Duration(minutes: 15));
  final windowEnd = base.add(const Duration(minutes: 25));

  if (now.isAfter(windowEnd)) {
    final lateMinutes = now.difference(windowEnd).inMinutes;
    final clampedMinutes = lateMinutes < 1 ? 1 : lateMinutes;
    return _EtaInfo(
      TranslationHelper.get('order_may_be_late', {'minutes': clampedMinutes}),
      true,
      lateMinutes: clampedMinutes,
    );
  }
  return _EtaInfo('${_formatHm(windowStart)} - ${_formatHm(windowEnd)}', false);
}

String _formatHm(DateTime t) {
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Live tracking for one in-progress order - a map (store, destination and,
/// once assigned, the driver's live position) under a persistent bottom
/// sheet with the delivery timeline. Reached from [OrdersListPage] for both
/// active and just-cancelled orders (`orders/{orderId}`, `lib/map.txt`).
class LiveOrderPage extends StatefulWidget {
  final String language;
  final String orderId;
  const LiveOrderPage(this.language, this.orderId, {super.key});

  @override
  State<LiveOrderPage> createState() => _LiveOrderPageState();
}

class _LiveOrderPageState extends State<LiveOrderPage> with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;
  GoogleMapController? _mapController;
  bool _hasFittedInitialBounds = false;
  CachedAd? _ad;

  // Loaded once from assets/motor.png, assets/store.png and assets/home.png
  // and cached rather than reloaded on every build/marker set - loading is
  // async, so these start null and the map falls back to stock pins until
  // they're ready (see _buildMap).
  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _storeIcon;
  BitmapDescriptor? _userIcon;

  bool get _isArabic => widget.language == 'ar';

  // A field, not a getter re-evaluated on every build: StreamBuilder resets
  // to ConnectionState.waiting when it sees a "new" Stream instance, which
  // a getter would recreate on every setState in this page (ad loading in,
  // map camera moves, ...).
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _orderStream =
      _firestore.collection('orders').doc(widget.orderId).snapshots();

  // delivery_id isn't known until the order doc loads, so these can't be
  // simple late final fields - cached lazily per delivery_id instead, so a
  // driver getting (re)assigned mid-order doesn't leak/duplicate
  // subscriptions and an unrelated order-doc update doesn't restart either.
  // The courier's live GPS position lives in the Realtime Database (not
  // Firestore) at `locations/{courier_uid}` (lat/lng/updated_at) - written
  // continuously by the courier app, separate from the Firestore `delivery`
  // collection's account-level profile fields.
  final Map<String, Stream<DatabaseEvent>> _driverLocationStreams = {};
  Stream<DatabaseEvent> _driverLocationStream(String deliveryId) {
    return _driverLocationStreams.putIfAbsent(deliveryId,
        () => FirebaseDatabase.instance.ref('locations/$deliveryId').onValue);
  }

  final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>
      _driverProfileFutures = {};
  Future<DocumentSnapshot<Map<String, dynamic>>> _driverProfileFuture(
      String deliveryId) {
    return _driverProfileFutures.putIfAbsent(
        deliveryId, () => _firestore.collection('users').doc(deliveryId).get());
  }

  // Loaded once from assets/map_style.json and cached - starts null and the
  // map renders with the default Google style until it's ready (see build).
  String? _mapStyle;

  // Rating card state - 0 means "not picked yet" for both. Held locally
  // (not on the order doc) until actually submitted; the order doc only
  // records that a rating happened via `rating_submitted`, once, so
  // reopening this page after submitting doesn't show the card again.
  int _storeRatingInput = 0;
  int _deliveryRatingInput = 0;
  bool _isSubmittingRating = false;
  late final TextEditingController _commentController = TextEditingController();

  // DraggableScrollableSheet's own `initialChildSize` only applies on its
  // very first layout - it does NOT re-expand the sheet just because a
  // rebuild passes a different value, so when delivery_status flips to
  // "delivered" while the sheet is already sitting collapsed (its normal
  // in-progress state), the rating card silently ends up below the fold
  // instead of visible. This controller lets _maybeExpandForRating drive it
  // open explicitly the moment that happens.
  final _sheetController = DraggableScrollableController();
  bool _hasExpandedForRating = false;

  // The ETA label (below) needs real time, not the device's own clock - a
  // driver with their phone's date wrong shouldn't see a nonsense window,
  // and the "may be late" check would otherwise drift with device clock
  // skew. Fetched once (system/server_time_probe, same round-trip
  // owner_store_detail_page.dart already uses) and kept as a fixed offset
  // applied to DateTime.now() from then on, rather than re-fetching on
  // every tick.
  Duration _serverTimeOffset = Duration.zero;
  DateTime get _realNow => DateTime.now().add(_serverTimeOffset);

  // The order doc only changes (and rebuilds this page) when its status
  // actually moves - the ETA window and "may be late" check need to keep
  // re-evaluating against the clock even while nothing else changes, so
  // this ticks a plain rebuild independently of the order stream.
  Timer? _etaTicker;

  @override
  void initState() {
    super.initState();
    _loadAd();
    _loadMarkerIcons();
    _loadMapStyle();
    _syncServerTime();
    _etaTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _syncServerTime() async {
    try {
      final ref = _firestore.collection('system').doc('server_time_probe');
      await ref
          .set({'t': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      final snap = await ref.get(const GetOptions(source: Source.server));
      final serverTime = (snap.data()?['t'] as Timestamp?)?.toDate();
      if (serverTime != null && mounted) {
        setState(
            () => _serverTimeOffset = serverTime.difference(DateTime.now()));
      }
    } catch (_) {
      // Falls back to the device's own clock - not worth failing the page
      // over an offset that's only ever a display refinement.
    }
  }

  Future<void> _loadMapStyle() async {
    try {
      final style = await rootBundle.loadString('assets/map_style.json');
      if (mounted) setState(() => _mapStyle = style);
    } catch (_) {
      // Falls back to the default Google style - not worth failing the
      // page over cosmetic map styling.
    }
  }

  Future<void> _loadMarkerIcons() async {
    final icons = await Future.wait([
      _loadMarkerAsset('assets/motor.png', size: 80),
      _loadMarkerAsset('assets/store.png', size: 80),
      _loadMarkerAsset('assets/home.png', size: 80),
    ]);
    if (!mounted) return;
    setState(() {
      _driverIcon = icons[0];
      _storeIcon = icons[1];
      _userIcon = icons[2];
    });
  }

  /// Crops out any transparent padding around the glyph first, then scales
  /// that cropped content to fit within a [size] x [size] box, keeping its
  /// aspect ratio. store.png/home.png's actual glyph sits centered in a lot
  /// of empty canvas (676x369 with a small icon in the middle) - scaling
  /// the whole canvas down to match motor.png's box (which is glyph
  /// edge-to-edge) made the visible glyph itself tiny even though the
  /// bounding boxes matched; cropping to the opaque pixels first makes the
  /// two actually read as the same size.
  Future<BitmapDescriptor> _loadMarkerAsset(String path,
      {required double size}) async {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final contentRect = await _opaqueBoundsOf(image) ??
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final aspectRatio = contentRect.width / contentRect.height;
    final width = aspectRatio >= 1 ? size : size * aspectRatio;
    final height = aspectRatio >= 1 ? size / aspectRatio : size;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
    canvas.drawImageRect(
      image,
      contentRect,
      Rect.fromLTWH(0, 0, width, height),
      Paint()..filterQuality = FilterQuality.high,
    );
    final cropped =
        await recorder.endRecording().toImage(width.ceil(), height.ceil());
    final pngBytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(pngBytes!.buffer.asUint8List(),
        width: width, height: height);
  }

  /// The bounding box of every pixel with meaningful alpha - null (falls
  /// back to the full image) if the image is fully transparent.
  Future<Rect?> _opaqueBoundsOf(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final bytes = byteData.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    const alphaThreshold = 10;

    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final alpha = bytes[(y * width + x) * 4 + 3];
        if (alpha > alphaThreshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < minX || maxY < minY) return null;
    return Rect.fromLTRB(minX.toDouble(), minY.toDouble(),
        (maxX + 1).toDouble(), (maxY + 1).toDouble());
  }

  @override
  void dispose() {
    // No AdService.flush() here - HomeShell owns the background flush
    // timer for the whole session (see home_shell.dart).
    disposeAlert();
    _commentController.dispose();
    _sheetController.dispose();
    _etaTicker?.cancel();
    super.dispose();
  }

  // No refresh()/startAutoFlush() here - HomeShell already keeps the
  // shared ad cache refreshed and the flush timer running for the whole
  // session (see home_shell.dart); this just reads whatever's cached.
  void _loadAd() {
    final ad = AdService.instance.nextAdFor('live_order');
    if (ad != null) AdService.instance.recordView(ad, 'live_order');
    if (mounted) setState(() => _ad = ad);
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, 'live_order');
    if (ad.actionType == 'url' && ad.actionValue.isNotEmpty) {
      // No-op here: opening arbitrary URLs mid-delivery isn't the focus of
      // this page, and every other ad slot in the app already handles its
      // own "url" action type via openExternalUrl - intentionally left to
      // just record the click for slots where a tap isn't expected to do
      // much beyond that.
    }
  }

  // Accepts Object? rather than a typed Map so it can read both a Firestore
  // Map<String, dynamic> (store_address/user_address) and the Realtime
  // Database's untyped Map<Object?, Object?> (the driver's `locations`
  // node) with the same helper.
  LatLng? _pointFrom(Object? point) {
    if (point is! Map) return null;
    final lat = (point['lat'] as num?)?.toDouble();
    final lng = (point['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _orderStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final doc = snapshot.data;
            if (snapshot.hasError || doc == null || !doc.exists) {
              return _buildErrorState(snapshot.error);
            }
            return _buildContent(doc.data()!);
          },
        ),
      ),
    );
  }

  Widget _buildErrorState(Object? error) {
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: Text(
              error == null
                  ? TranslationHelper.get('order_not_found')
                  : TranslationHelper.get(
                      isConnectivityError(error) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _buildBackButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildBackButton() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.12), blurRadius: 12),
          ],
        ),
        child: Icon(
          _isArabic ? Icons.arrow_forward : Icons.arrow_back,
          color: const Color(0xFF2E3A59),
          size: 18,
        ),
      ),
    );
  }

  Widget _buildContent(Map<String, dynamic> data) {
    final deliveryId = data['delivery_id'] as String? ?? '';
    final storePoint =
        _pointFrom(data['store_address'] as Map<String, dynamic>?);
    final userPoint = _pointFrom(data['user_address'] as Map<String, dynamic>?);
    final initialCenter =
        userPoint ?? storePoint ?? const LatLng(18.0735, -15.9582);

    final showRatingCard = data['delivery_status'] == 'delivered' &&
        data['rating_submitted'] != true;
    _maybeExpandForRating(showRatingCard);

    return Stack(
      children: [
        if (deliveryId.isNotEmpty)
          StreamBuilder<DatabaseEvent>(
            stream: _driverLocationStream(deliveryId),
            builder: (context, driverSnap) {
              if (driverSnap.hasError) {
                // Silently dropping this would leave the driver marker
                // missing with no clue why (e.g. Realtime Database rules
                // not granting the client read access to `locations/*`
                // yet) - surfaced to the console so it's diagnosable
                // without guessing.
                debugPrint(
                    'LiveOrderPage: locations/$deliveryId read failed: ${driverSnap.error}');
              }
              final driverPoint = _pointFrom(driverSnap.data?.snapshot.value);
              return _buildMap(
                  initialCenter, storePoint, userPoint, driverPoint);
            },
          )
        else
          _buildMap(initialCenter, storePoint, userPoint, null),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildBackButton(),
          ),
        ),
        DraggableScrollableSheet(
          controller: _sheetController,
          initialChildSize: _sheetCollapsedSize,
          minChildSize: _sheetCollapsedSize,
          maxChildSize: 0.85,
          snap: true,
          snapSizes: const [_sheetCollapsedSize, 0.85],
          builder: (context, scrollController) =>
              _buildSheet(data, deliveryId, scrollController),
        ),
      ],
    );
  }

  /// Drives the sheet open to its max size the moment the rating card
  /// becomes relevant, since DraggableScrollableSheet's `initialChildSize`
  /// only takes effect on the sheet's first layout - a later rebuild (the
  /// order doc's live snapshot updating to delivery_status: "delivered")
  /// can't just change that value to move an already-built sheet. Guarded
  /// so it only fires once per page visit, not on every subsequent
  /// snapshot while the card is still showing.
  void _maybeExpandForRating(bool showRatingCard) {
    if (!showRatingCard || _hasExpandedForRating) return;
    _hasExpandedForRating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheetController.isAttached) return;
      _sheetController.animateTo(
        0.85,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    });
  }

  // Starts low (mostly out of the way of the map) rather than already
  // covering the store/driver markers - the user swipes it up to read the
  // timeline/driver details.
  static const _sheetCollapsedSize = 0.24;

  Widget _buildMap(LatLng center, LatLng? storePoint, LatLng? userPoint,
      LatLng? driverPoint) {
    // Each falls back to a stock colored pin for the brief moment before
    // _loadMarkerIcons finishes reading its asset.
    final markers = <Marker>{
      if (storePoint != null)
        Marker(
          markerId: const MarkerId('store'),
          position: storePoint,
          icon: _storeIcon ?? // assets/store.png
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow),
        ),
      if (userPoint != null)
        Marker(
          markerId: const MarkerId('destination'),
          position: userPoint,
          icon: _userIcon ?? // assets/home.png
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      if (driverPoint != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: driverPoint,
          icon: _driverIcon ?? // assets/motor.png
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
    };

    // Every currently-known point (store + destination always, driver only
    // once assigned) - the camera is fit to whatever's actually available
    // rather than always assuming all three exist.
    final points = <LatLng>[
      if (storePoint != null) storePoint,
      if (userPoint != null) userPoint,
      if (driverPoint != null) driverPoint,
    ];
    _maybeFitCamera(points);

    return GoogleMap(
      initialCameraPosition: CameraPosition(target: center, zoom: 14),
      onMapCreated: (controller) {
        _mapController = controller;
        // build() may have already tried to fit once with no controller yet
        // (a no-op) - retry now that one actually exists.
        _maybeFitCamera(points);
      },
      style: _mapStyle,
      markers: markers,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
    );
  }

  /// Fits the camera to every currently-known marker (store + destination,
  /// plus the driver once assigned) exactly once, the first time any points
  /// are available - deliberately does NOT refit as the driver's live
  /// location keeps changing, since re-fitting bounds on every GPS tick
  /// kept rescaling/panning the map out from under the user. No-ops
  /// silently if the map controller isn't ready yet - the caller retries
  /// from onMapCreated once it is.
  void _maybeFitCamera(List<LatLng> points) {
    if (points.isEmpty || _hasFittedInitialBounds) return;
    final controller = _mapController;
    if (controller == null) return;

    _hasFittedInitialBounds = true;

    if (points.length == 1) {
      controller.animateCamera(CameraUpdate.newLatLngZoom(points.first, 15));
      return;
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;
    for (final p in points.skip(1)) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    controller.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        80,
      ),
    );
  }

  Widget _buildSheet(Map<String, dynamic> data, String deliveryId,
      ScrollController scrollController) {
    final isCancelled = data['order_status'] == 'cancelled';
    // "delivered" only ever shows up on `delivery_status` (`lib/map.txt`) -
    // `order_status` itself has no such value.
    final isDelivered = data['delivery_status'] == 'delivered';
    final ratingSubmitted = data['rating_submitted'] == true;
    final eta = isDelivered ? null : _computeEta(data, _realNow);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Colors.black26, blurRadius: 24, offset: Offset(0, -8)),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE3E5E9),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          if (alertCard != null) alertCard!,
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              children: isCancelled
                  ? [_buildCancelledCard()]
                  : [
                      if (isDelivered && !ratingSubmitted) ...[
                        _buildRatingCard(data, deliveryId),
                        const SizedBox(height: 14),
                      ],
                      if (eta != null) _buildEtaCard(eta),
                      if (_ad != null) ...[
                        const SizedBox(height: 14),
                        SponsoredAdCard(
                          ad: _ad!,
                          language: widget.language,
                          onTap: () => _handleAdTap(_ad!),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _buildDriverCard(data, deliveryId),
                      const SizedBox(height: 20),
                      _buildSectionLabel('order_status_section_label'),
                      const SizedBox(height: 12),
                      _buildTimeline(data),
                    ],
            ),
          ),
          if (!isDelivered && !isCancelled)
            SafeArea(top: false, child: _buildAdminCallBar(data, eta)),
        ],
      ),
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

  Widget _buildCancelledCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF1F0),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.cancel_rounded, color: Color(0xFFE74C3C)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              TranslationHelper.get('order_cancelled_message'),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFE74C3C),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shown once `delivery_status` reaches "delivered" (`lib/map.txt`) and
  /// only until submitted - `rating_submitted` on the order doc (not part
  /// of the original schema, added here to track it) keeps it from
  /// reappearing every time this page is reopened for the same order.
  Widget _buildRatingCard(Map<String, dynamic> data, String deliveryId) {
    final storeId = data['store_id'] as String? ?? '';
    // Delivery rating is only required when there's actually a driver to
    // rate - the section itself only renders when deliveryId is set (see
    // below), so a missing deliveryId can't leave submit permanently
    // disabled with no rating row visible to satisfy it.
    final canSubmit = _storeRatingInput > 0 &&
        (deliveryId.isEmpty || _deliveryRatingInput > 0) &&
        !_isSubmittingRating;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFD9A8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.celebration_rounded,
                    color: Color(0xFFFF9800), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      TranslationHelper.get('order_delivered_title'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2E3A59),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      TranslationHelper.get('order_delivered_subtitle'),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF9AA1AC)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            TranslationHelper.get('rate_store_label'),
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2E3A59)),
          ),
          const SizedBox(height: 8),
          _buildStarRow(
              _storeRatingInput, (v) => setState(() => _storeRatingInput = v)),
          const SizedBox(height: 12),
          TextField(
            controller: _commentController,
            maxLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: TranslationHelper.get('comment_hint'),
              hintStyle:
                  const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (deliveryId.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              TranslationHelper.get('rate_delivery_label'),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2E3A59)),
            ),
            const SizedBox(height: 8),
            _buildStarRow(_deliveryRatingInput,
                (v) => setState(() => _deliveryRatingInput = v)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  canSubmit ? () => _submitRating(storeId, deliveryId) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFFFC98A),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _isSubmittingRating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text(
                      TranslationHelper.get('submit_rating_button'),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStarRow(int value, ValueChanged<int> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(i + 1),
            child: Icon(
              i < value ? Icons.star_rounded : Icons.star_border_rounded,
              color: const Color(0xFFF5A623),
              size: 30,
            ),
          ),
        ],
      ],
    );
  }

  /// Goes through the `submitOrderRating` Cloud Function rather than writing
  /// `stores.rate`/`rate_numbers` (and `delivery.rate`/`rate_numbers`)
  /// directly - it re-verifies server-side that this order belongs to the
  /// caller, was actually delivered, and hasn't already been rated, before
  /// touching either aggregate. A raw client batch had none of that: any
  /// signed-in user could inflate any store's or driver's public rating,
  /// any number of times, for any order.
  Future<void> _submitRating(String storeId, String deliveryId) async {
    if (_storeRatingInput == 0 ||
        (deliveryId.isNotEmpty && _deliveryRatingInput == 0) ||
        _isSubmittingRating ||
        storeId.isEmpty) {
      return;
    }
    setState(() => _isSubmittingRating = true);
    try {
      await FirebaseFunctions.instance.httpsCallable('submitOrderRating').call({
        'order_id': widget.orderId,
        'store_rating': _storeRatingInput,
        'comment': _commentController.text.trim(),
        if (deliveryId.isNotEmpty) 'delivery_rating': _deliveryRatingInput,
      });
      if (mounted) showAlert(TranslationHelper.get('rating_thanks_message'));
    } catch (_) {
      if (mounted) showAlert(TranslationHelper.get('error'), isError: true);
    } finally {
      if (mounted) setState(() => _isSubmittingRating = false);
    }
  }

  Widget _buildEtaCard(_EtaInfo eta) {
    final accentColor =
        eta.isLate ? const Color(0xFFE74C3C) : const Color(0xFFFF9800);
    final bgColor =
        eta.isLate ? const Color(0xFFFDF1F0) : const Color(0xFFFFF3E0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              eta.isLate
                  ? Icons.error_outline_rounded
                  : Icons.access_time_rounded,
              color: accentColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TranslationHelper.get(eta.isLate
                      ? 'order_late_label'
                      : 'estimated_arrival_label'),
                  style:
                      const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
                ),
                const SizedBox(height: 2),
                Text(
                  eta.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: eta.isLate ? accentColor : const Color(0xFF2E3A59),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Lazily creates the conversation (startOrderConversation) the first
  /// time either side opens chat for this order, then opens it.
  bool _openingChat = false;

  Future<void> _openChat(Map<String, dynamic> data, String driverName) async {
    if (_openingChat) return;
    _openingChat = true;
    try {
      var conversationId = data['conversation_id'] as String?;
      if (conversationId == null || conversationId.isEmpty) {
        final result = await FirebaseFunctions.instance
            .httpsCallable('startOrderConversation')
            .call({'order_id': widget.orderId});
        conversationId = result.data['conversation_id'] as String?;
      }
      if (conversationId == null || conversationId.isEmpty) {
        if (mounted) {
          showAlert(TranslationHelper.get('conversation_not_started'),
              isError: true);
        }
        return;
      }
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ChatPage(widget.language, conversationId!, driverName),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      _openingChat = false;
    }
  }

  Widget _buildDriverCard(Map<String, dynamic> data, String deliveryId) {
    final storeNameAr = data['store_name_ar'] as String? ?? '';
    final storeNameFr = data['store_name_fr'] as String? ?? '';
    final storeName = (_isArabic ? storeNameAr : storeNameFr).isNotEmpty
        ? (_isArabic ? storeNameAr : storeNameFr)
        : (storeNameFr.isNotEmpty
            ? storeNameFr
            : TranslationHelper.get('unknown_store'));
    final orderNumber = data['order_number'] as String? ?? '';

    // The card's own header, not the fixed "Livreur en route" text - shows
    // whichever delivery_status step (`lib/map.txt`) the order is actually
    // at right now, same labels as the timeline below, so the current
    // status is visible at a glance without having to read the timeline.
    final stageIndex = _stageIndexOf(data);
    final headerText = stageIndex >= 0
        ? TranslationHelper.get(
            _stageLabelKey(_DeliveryStage.values[stageIndex]))
        : TranslationHelper.get('driver_en_route_label');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEDEFF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            headerText,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$storeName · ${TranslationHelper.get('order_number_label', {
                  'number': orderNumber
                })}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
          ),
          const SizedBox(height: 12),
          if (deliveryId.isEmpty)
            Text(
              TranslationHelper.get('searching_driver_label'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
            )
          else
            FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              future: _driverProfileFuture(deliveryId),
              builder: (context, snapshot) {
                final driver = snapshot.data?.data();
                final name = driver?['name'] as String? ?? '';
                final phone = driver?['phone'] as String? ?? '';
                return Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFFEFD9),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person, color: Color(0xFFFF9800)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        name.isNotEmpty
                            ? name
                            : TranslationHelper.get('unknown_driver'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF2E3A59),
                        ),
                      ),
                    ),
                    _buildIconButton(
                      icon: Icons.phone_rounded,
                      onTap: phone.isEmpty
                          ? null
                          : () => launchUrl(Uri(scheme: 'tel', path: phone)),
                    ),
                    const SizedBox(width: 8),
                    _buildIconButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      onTap: () => _openChat(data, name),
                    ),
                  ],
                );
              },
            ),
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
          color:
              onTap == null ? const Color(0xFFC9CDD4) : const Color(0xFFFF9800),
        ),
      ),
    );
  }

  Widget _buildTimeline(Map<String, dynamic> data) {
    final currentIndex = _stageIndexOf(data);
    final stages = _DeliveryStage.values;

    return Column(
      children: [
        for (var i = 0; i < stages.length; i++)
          _buildTimelineRow(
            stage: stages[i],
            data: data,
            isDone: i < currentIndex,
            isCurrent: i == currentIndex,
            isLast: i == stages.length - 1,
          ),
      ],
    );
  }

  Widget _buildTimelineRow({
    required _DeliveryStage stage,
    required Map<String, dynamic> data,
    required bool isDone,
    required bool isCurrent,
    required bool isLast,
  }) {
    final active = isDone || isCurrent;
    final tsField = _stageTimestampField(stage);
    final timestamp = tsField == null ? null : data[tsField] as Timestamp?;

    String? subtitle;
    if (isCurrent && stage == _DeliveryStage.onTheWay) {
      final eta = _computeEta(data, _realNow);
      if (eta != null) {
        subtitle = eta.isLate
            ? eta.label
            : '${TranslationHelper.get('estimated_arrival_label')} ${eta.label}';
      }
    } else if (timestamp != null && (isDone || isCurrent)) {
      final time = timestamp.toDate();
      subtitle = '${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')}';
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: active ? const Color(0xFFFF9800) : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active
                        ? const Color(0xFFFF9800)
                        : const Color(0xFFE1E4E9),
                    width: 2,
                  ),
                ),
                child: isDone
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : (isCurrent
                        ? Center(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: isDone
                        ? const Color(0xFFFF9800)
                        : const Color(0xFFE1E4E9),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    TranslationHelper.get(_stageLabelKey(stage)),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: active
                          ? const Color(0xFF2E3A59)
                          : const Color(0xFF9AA1AC),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent
                            ? const Color(0xFFFF9800)
                            : const Color(0xFF9AA1AC),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Only shown once an order is running significantly late (30+ min past
  // the estimated window - see _computeEta) - a generic "need help?" link
  // was here before regardless of how the order was actually doing; this
  // replaces it with something tied to a real signal instead of always
  // being present. Once tapped, requestAdminCall auto-creates a `reports`
  // doc and stamps orders.admin_report_id with it - the same escalation the
  // courier-search system's own hard-cap can trigger automatically - so
  // this switches to a persistent notice on every future open of this page
  // (not just right after tapping), since the order doc's own
  // admin_report_id is what's actually checked, not any local "I already
  // tapped this" state.
  static const _adminCallThresholdMinutes = 30;
  bool _isCallingAdmin = false;

  Widget _buildAdminCallBar(Map<String, dynamic> data, _EtaInfo? eta) {
    final alreadyCalled = data['admin_report_id'] != null;
    final significantlyLate = eta != null &&
        eta.isLate &&
        eta.lateMinutes >= _adminCallThresholdMinutes;
    if (!alreadyCalled && !significantlyLate) {
      return const SizedBox.shrink();
    }

    if (alreadyCalled) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFE6F7EA),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 18, color: Color(0xFF1B8A3E)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  TranslationHelper.get('admin_notified_message'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1B8A3E),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: _isCallingAdmin ? null : _callAdmin,
        child: Container(
          width: double.infinity,
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFFDF1F0),
            borderRadius: BorderRadius.circular(15),
          ),
          child: _isCallingAdmin
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Color(0xFFE74C3C)),
                  ),
                )
              : Text(
                  TranslationHelper.get('call_admin_button'),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFE74C3C),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _callAdmin() async {
    if (_isCallingAdmin) return;
    setState(() => _isCallingAdmin = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('requestAdminCall')
          .call({'order_id': widget.orderId});
      if (mounted) showAlert(TranslationHelper.get('admin_notified_message'));
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isCallingAdmin = false);
    }
  }
}
