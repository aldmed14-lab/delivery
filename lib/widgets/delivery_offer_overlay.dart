import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/utils/alert_sound.dart';
import 'package:flutter_application_1/utils/delivery_offer_service.dart';
import 'package:flutter_application_1/utils/directions_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Wraps the whole app (via `MaterialApp.builder`, not any one page) so the
/// "Nouvelle course" offer card can appear above whatever route is
/// currently on screen - a page-level widget can't do this, since pushing
/// a new route paints fully over whatever the previous page returned.
class DeliveryOfferOverlay extends StatelessWidget {
  final Widget child;
  const DeliveryOfferOverlay({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        AnimatedBuilder(
          animation: DeliveryOfferService.instance,
          builder: (context, _) {
            final offer = DeliveryOfferService.instance.pendingOffer;
            if (offer == null) return const SizedBox.shrink();
            return _OfferCard(offer: offer);
          },
        ),
      ],
    );
  }
}

class _OfferCard extends StatefulWidget {
  final Map<String, dynamic> offer;
  const _OfferCard({required this.offer});

  @override
  State<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<_OfferCard> {
  Timer? _ticker;
  int _secondsLeft = 0;

  bool get _isArabic => TranslationHelper.currentLanguage == 'ar';

  @override
  void initState() {
    super.initState();
    AlertSound.playOrderAlert();
    _resetTimer();
  }

  @override
  void didUpdateWidget(covariant _OfferCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offer['offer_id'] != widget.offer['offer_id']) {
      _resetTimer();
    }
  }

  void _resetTimer() {
    _ticker?.cancel();
    _secondsLeft = _remainingSeconds();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _remainingSeconds();
      if (!mounted) return;
      if (left <= 0) {
        _ticker?.cancel();
        DeliveryOfferService.instance.respond(accept: false);
        return;
      }
      setState(() => _secondsLeft = left);
    });
  }

  int _remainingSeconds() {
    final expiresAt = widget.offer['expires_at'];
    if (expiresAt is! Timestamp) return 0;
    final diff = expiresAt.toDate().difference(DateTime.now()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _respond(bool accept) async {
    _ticker?.cancel();
    await DeliveryOfferService.instance.respond(accept: accept);
  }

  /// "Driver -> store" + "store -> dropoff", straight-line - a real routed
  /// distance per offer isn't worth a Directions round trip on a card that
  /// might be refused or expire in seconds; the detail page's own map (once
  /// the delivery is actually accepted) is where the real route lives.
  String? _distanceLabel() {
    final driverLat = DeliveryOfferService.instance.driverLat;
    final driverLng = DeliveryOfferService.instance.driverLng;
    final store = (widget.offer['store'] as Map?)?.cast<String, dynamic>();
    final address = (widget.offer['address'] as Map?)?.cast<String, dynamic>();
    final storeLat = (store?['lat'] as num?)?.toDouble();
    final storeLng = (store?['lng'] as num?)?.toDouble();
    final dropoffLat = (address?['lat'] as num?)?.toDouble();
    final dropoffLng = (address?['lng'] as num?)?.toDouble();

    if (driverLat == null ||
        driverLng == null ||
        storeLat == null ||
        storeLng == null ||
        dropoffLat == null ||
        dropoffLng == null) {
      return null;
    }

    final total =
        DirectionsService.distanceKm(driverLat, driverLng, storeLat, storeLng) +
            DirectionsService.distanceKm(
                storeLat, storeLng, dropoffLat, dropoffLng);
    return '${total.toStringAsFixed(1)} km';
  }

  @override
  Widget build(BuildContext context) {
    final store =
        (widget.offer['store'] as Map?)?.cast<String, dynamic>() ?? {};
    final storeName = store['name'] as String? ?? '';
    final earning = (widget.offer['earning'] as num?) ?? 0;
    final currency = TranslationHelper.get('currency_unit');

    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Stack(
        children: [
          // A tap on the dimmed backdrop does nothing - the driver has to
          // actively accept or refuse (or let it expire), not dismiss it
          // by tapping away.
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.35)),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 20,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            TranslationHelper.get('new_offer_title'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF2E3A59),
                            ),
                          ),
                        ),
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: const Color(0xFFFF9800), width: 2),
                          ),
                          child: Text(
                            '$_secondsLeft',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFFF9800),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                storeName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF2E3A59),
                                ),
                              ),
                              if (_distanceLabel() != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  _distanceLabel()!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF9AA1AC),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Text(
                          '${earning.toStringAsFixed(0)} $currency',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFFF9800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _respond(false),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: const BorderSide(color: Color(0xFFE1E4E9)),
                            ),
                            child: Text(
                              TranslationHelper.get('refuse_button'),
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
                            onPressed: () => _respond(true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1B8A3E),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              TranslationHelper.get('accept_button'),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
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
        ],
      ),
    );
  }
}
