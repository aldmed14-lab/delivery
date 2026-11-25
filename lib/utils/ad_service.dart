import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// One ad held in the shared in-memory cache. Schema is `lib/map.txt`
/// (`campaigns` / `ads` / `cities.advertisement_price`) - pricing isn't
/// known client-side: it lives per-city, per-slot on `cities/{id}
/// .advertisement_price.{position} = { view_price, click_price }` and is
/// resolved server-side by `chargeAdUsage` at charge time, along with the
/// campaign's live budget.
class CachedAd {
  final String adId;
  final String campaignId;
  final String pricingModel; // "cpc" | "cpv"

  final String titleFr;
  final String titleAr;
  final String subtitleFr;
  final String subtitleAr;
  final String filesType; // "image" | "video"
  final List<String> files;
  final String actionType; // "store" | "url"
  final String actionValue;

  /// Slots this ad is eligible for, e.g. "home", "search", "store_daitails"
  /// - matches the position keys under `cities/{id}.advertisement_price`.
  final List<String> positions;

  /// From the campaign (frequency capping is campaign-level, not per-ad).
  final int dailyFrequencyCap;

  /// The city document id this ad was cached for (resolved once in
  /// [AdService.refresh] by querying `cities` where `name == cityName`) -
  /// needed at charge time so the server can look up that city's price.
  final String cityId;

  /// Slot this ad was last shown in.
  String? lastPosition;

  String? seenDay;
  int seenDayCount;

  /// Impressions/clicks counted locally since the last successful flush,
  /// keyed by the slot they happened in - charged separately per slot since
  /// each slot can have its own price.
  final Map<String, int> localViews = {};
  final Map<String, int> localClicks = {};

  CachedAd({
    required this.adId,
    required this.campaignId,
    required this.pricingModel,
    required this.titleFr,
    required this.titleAr,
    required this.subtitleFr,
    required this.subtitleAr,
    required this.filesType,
    required this.files,
    required this.actionType,
    required this.actionValue,
    required this.positions,
    required this.dailyFrequencyCap,
    required this.cityId,
    required this.seenDay,
    required this.seenDayCount,
  });

  String title(String language) => language == 'ar' ? titleAr : titleFr;
  String subtitle(String language) =>
      language == 'ar' ? subtitleAr : subtitleFr;
  String? get imageUrl => files.isNotEmpty ? files.first : null;
}

/// Client-side half of the ad system (see `lib/map.txt` for the schema and
/// `pages/ads_system_spec.md` for the flow): one app-level cache shared by
/// every screen, refreshed every ~3 minutes, served locally with zero reads
/// per slot, and flushed every 30s.
///
/// Trust boundary: this class writes ad view/click counters and `ad_seen`
/// state directly to Firestore - that's safe, non-monetary bookkeeping. It
/// never touches `campaign.spent` or resolves pricing itself: both go
/// through the `chargeAdUsage` callable, which re-reads the campaign and the
/// city's `advertisement_price` live and clamps the charge so `spent` never
/// exceeds `budget`. A client can't be trusted to self-report how much it
/// owes, so that part can't move client-side no matter how the rest of the
/// flow is simplified.
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  List<CachedAd> _cache = [];
  String? _cityDocId;
  Map<String, dynamic> _advertisementPrice = {};
  String? _lastCityId;

  Completer<void>? _refreshInFlight;
  Timer? _flushTimer;
  Timer? _autoRefreshTimer;
  DateTime? _lastRefreshAt;

  /// How long a cache stays "fresh enough" to skip re-querying Firestore.
  /// Well under [startAutoRefresh]'s interval, so the periodic background
  /// refresh always actually runs - this only coalesces the *extra* calls
  /// pages make when they open (home, search, a store's page, ...) within
  /// a few seconds of each other for the same city.
  static const _staleness = Duration(seconds: 45);

  /// Read-only view of the current city's advertisement_price map, in case a
  /// screen wants to show an estimated price - the authoritative number is
  /// still resolved server-side at charge time.
  Map<String, dynamic> get advertisementPrice => _advertisementPrice;

  /// Refreshes the shared cache for the city [cityId] (`cities/{id}` - the
  /// active location's city). If a refresh is already running, waits for that one
  /// instead of returning early with a stale/empty cache - two callers
  /// racing to load ads (e.g. a duplicate init call) must both see the same
  /// populated result, not have the second one read nothing.
  ///
  /// Whichever screen calls this first for a city pays for the Firestore
  /// reads; every other screen that calls it again shortly after (any page
  /// showing an ad slot does, on open) just rides the same cache instead of
  /// re-querying - see [_staleness].
  Future<void> refresh(String cityId) async {
    if (_refreshInFlight != null) return _refreshInFlight!.future;

    if (_lastCityId == cityId &&
        _lastRefreshAt != null &&
        DateTime.now().difference(_lastRefreshAt!) < _staleness) {
      return;
    }

    final completer = Completer<void>();
    _refreshInFlight = completer;
    _lastCityId = cityId;
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      // Fire every query that doesn't depend on another one's result up
      // front instead of awaiting them one at a time - cuts three
      // sequential Firestore round-trips down to one round-trip's worth of
      // latency (only the `ads` lookup below has a real dependency, on
      // which campaigns turned out eligible).
      final citySnapFuture =
          FirebaseFirestore.instance.collection('cities').doc(cityId).get();
      // campaigns.cities holds city ids.
      final campaignsSnapFuture = FirebaseFirestore.instance
          .collection('campaigns')
          .where('active', isEqualTo: true)
          .where('budget', isGreaterThan: 0)
          .where('cities', arrayContains: cityId)
          .get();
      final seenSnapFuture = uid != null
          ? FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('ad_seen')
              .get()
          : null;

      final cityDoc = await citySnapFuture;

      if (!cityDoc.exists) {
        _cache = [];
        _cityDocId = null;
        _advertisementPrice = {};
        return;
      }

      _cityDocId = cityDoc.id;
      _advertisementPrice = Map<String, dynamic>.from(
        (cityDoc.data()?['advertisement_price'] as Map?) ?? const {},
      );

      final campaignsSnap = await campaignsSnapFuture;

      final now = DateTime.now();
      final todayKey = _dayKey(now);
      final campaignById = <String, Map<String, dynamic>>{};
      final eligibleCampaignIds = <String>[];

      for (final doc in campaignsSnap.docs) {
        final data = doc.data();
        campaignById[doc.id] = data;

        final budget = _asDouble(data['budget']);
        final spent = _asDouble(data['spent']);
        if (spent >= budget) continue;

        final dailyLimit = _asDouble(data['daily_budget_limit']);
        if (dailyLimit > 0) {
          final spentTodayDate = data['spent_today_date'] as Timestamp?;
          final spentToday = (spentTodayDate != null &&
                  _dayKey(spentTodayDate.toDate()) == todayKey)
              ? _asDouble(data['spent_today'])
              : 0.0;
          if (spentToday >= dailyLimit) continue;
        }

        final monthlyLimit = _asDouble(data['monthly_budget_limit']);
        if (monthlyLimit > 0) {
          final spentMonthDate = data['spent_month_date'] as Timestamp?;
          final spentMonth = (spentMonthDate != null &&
                  _monthKey(spentMonthDate.toDate()) == _monthKey(now))
              ? _asDouble(data['spent_month'])
              : 0.0;
          if (spentMonth >= monthlyLimit) continue;
        }

        final startDate = (data['start_date'] as Timestamp?)?.toDate();
        final endDate = (data['end_date'] as Timestamp?)?.toDate();
        if (startDate != null && now.isBefore(startDate)) continue;
        if (endDate != null && now.isAfter(endDate)) continue;

        eligibleCampaignIds.add(doc.id);
      }

      if (eligibleCampaignIds.isEmpty) {
        _cache = [];
        return;
      }

      // `whereIn` is capped at 30 values by Firestore.
      final adsDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (var i = 0; i < eligibleCampaignIds.length; i += 30) {
        final chunk = eligibleCampaignIds.sublist(
          i,
          i + 30 > eligibleCampaignIds.length
              ? eligibleCampaignIds.length
              : i + 30,
        );
        final snap = await FirebaseFirestore.instance
            .collection('ads')
            .where('campaign_id', whereIn: chunk)
            .where('active', isEqualTo: true)
            .where('approved', isEqualTo: true)
            .get();
        adsDocs.addAll(snap.docs);
      }

      final seenById = <String, Map<String, dynamic>>{};
      if (seenSnapFuture != null) {
        final seenSnap = await seenSnapFuture;
        for (final d in seenSnap.docs) {
          seenById[d.id] = d.data();
        }
      }

      // Keyed by adId so an ad that's still eligible across this refresh
      // carries its not-yet-flushed view/click counts forward - rebuilding
      // fresh CachedAd instances below would otherwise silently zero out
      // any views/clicks recorded since the last flush() (e.g. a home-page
      // view recorded seconds before a refresh happens to land, losing the
      // count before the 30s flush timer ever gets to persist it).
      final oldByAdId = {for (final ad in _cache) ad.adId: ad};

      _cache = adsDocs.map((doc) {
        final data = doc.data();
        final campaign = campaignById[data['campaign_id']] ?? const {};
        final seen = seenById[doc.id];
        final newAd = CachedAd(
          adId: doc.id,
          campaignId: data['campaign_id'] ?? '',
          pricingModel: campaign['pricing_model'] ?? 'cpv',
          titleFr: data['title_fr'] ?? '',
          titleAr: data['title_ar'] ?? '',
          subtitleFr: data['subtitle_fr'] ?? '',
          subtitleAr: data['subtitle_ar'] ?? '',
          filesType: data['files_type'] ?? 'image',
          files: List<String>.from(data['files'] ?? const []),
          actionType: data['action_type'] ?? 'store',
          actionValue: data['action_value'] ?? '',
          positions: List<String>.from(data['positions'] ?? const []),
          dailyFrequencyCap: (campaign['dailyfrequency_cap'] ?? 0) as int,
          cityId: _cityDocId!,
          seenDay: seen?['seen_day'] as String?,
          seenDayCount: (seen?['seen_day_count'] ?? 0) as int,
        );
        final previous = oldByAdId[doc.id];
        if (previous != null) {
          newAd.localViews.addAll(previous.localViews);
          newAd.localClicks.addAll(previous.localClicks);
        }
        return newAd;
      }).toList();
    } catch (_) {
      // Keep whatever was cached before - display freshness isn't worth
      // dropping ads over a transient read failure.
    } finally {
      _refreshInFlight = null;
      _lastRefreshAt = DateTime.now();
      completer.complete();
    }
  }

  /// Picks one eligible ad for [position] (daily frequency cap already
  /// applied, lazily rolling over to a fresh day first), random rotation.
  /// Returns null if nothing qualifies.
  CachedAd? nextAdFor(String position) {
    final todayKey = _dayKey(DateTime.now());
    final eligible = _cache.where((ad) {
      if (!ad.positions.contains(position)) return false;
      if (ad.seenDay != todayKey) {
        ad.seenDay = todayKey;
        ad.seenDayCount = 0;
      }
      if (ad.dailyFrequencyCap > 0 && ad.seenDayCount >= ad.dailyFrequencyCap) {
        return false;
      }
      return true;
    }).toList();
    if (eligible.isEmpty) return null;
    eligible.shuffle();
    return eligible.first;
  }

  void recordView(CachedAd ad, String position) {
    final todayKey = _dayKey(DateTime.now());
    if (ad.seenDay != todayKey) {
      ad.seenDay = todayKey;
      ad.seenDayCount = 0;
    }
    ad.seenDayCount += 1;
    ad.lastPosition = position;
    ad.localViews[position] = (ad.localViews[position] ?? 0) + 1;
  }

  void recordClick(CachedAd ad, String position) {
    ad.lastPosition = position;
    ad.localClicks[position] = (ad.localClicks[position] ?? 0) + 1;
  }

  void startAutoFlush({Duration interval = const Duration(seconds: 30)}) {
    _flushTimer ??= Timer.periodic(interval, (_) => flush());
  }

  void stopAutoFlush() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void startAutoRefresh({Duration interval = const Duration(minutes: 3)}) {
    _autoRefreshTimer ??= Timer.periodic(interval, (_) {
      final city = _lastCityId;
      if (city != null) refresh(city);
    });
  }

  void stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  /// Every 30s: write view/click counters + seen-state directly (safe,
  /// non-monetary), then charge each slot that had activity through the
  /// server function - it looks up that slot's price for this city and the
  /// live campaign budget itself, so nothing money-related is computed here.
  Future<void> flush() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final toPrune = <String>[];

    for (final ad in _cache) {
      final totalViews = ad.localViews.values.fold(0, (a, b) => a + b);
      final totalClicks = ad.localClicks.values.fold(0, (a, b) => a + b);
      if (totalViews == 0 && totalClicks == 0) continue;

      Map<String, int> viewsByPosition;
      Map<String, int> clicksByPosition;

      try {
        // Batched rather than two sequential writes: if the ad_seen write
        // failed after the counter update had already landed, a retry on
        // the next flush would resend the same totals and double-count
        // the ads.views/clicks increment.
        final adRef = FirebaseFirestore.instance.collection('ads').doc(ad.adId);
        final batch = FirebaseFirestore.instance.batch();
        batch.update(adRef, {
          'views': FieldValue.increment(totalViews),
          'clicks': FieldValue.increment(totalClicks),
        });
        // Same totals, split into a per-day breakdown (ad_analytics/{day})
        // alongside the all-time counters above - lets the ad owner see a
        // trend over time, not just the running total. `set` + `merge`
        // (not `update`) since a given day's doc may not exist yet.
        batch.set(
          adRef.collection('ad_analytics').doc(_dayKey(DateTime.now())),
          {
            'views': FieldValue.increment(totalViews),
            'clicks': FieldValue.increment(totalClicks),
          },
          SetOptions(merge: true),
        );

        if (uid != null) {
          batch.set(
            FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .collection('ad_seen')
                .doc(ad.adId),
            {
              'seen_day': ad.seenDay,
              'seen_day_count': ad.seenDayCount,
            },
            SetOptions(merge: true),
          );
        }

        await batch.commit();

        // Counters are safely persisted at this point - snapshot the
        // per-slot breakdown and clear it before attempting the charge, so
        // a charge failure can't cause the next flush to resend the same
        // views/clicks and double-count them. Losing a charge for an
        // already-counted view just means it goes slightly under-billed,
        // which the spec already tolerates - unlike double-counting, that's
        // not a correctness bug.
        viewsByPosition = Map.of(ad.localViews);
        clicksByPosition = Map.of(ad.localClicks);
        ad.localViews.clear();
        ad.localClicks.clear();
      } catch (_) {
        // Firestore writes failed - leave local counts in place, retried
        // on the next flush tick.
        continue;
      }

      final positions = {...viewsByPosition.keys, ...clicksByPosition.keys};
      for (final position in positions) {
        final views = viewsByPosition[position] ?? 0;
        final clicks = clicksByPosition[position] ?? 0;
        if (views == 0 && clicks == 0) continue;

        try {
          final result = await FirebaseFunctions.instance
              .httpsCallable('chargeAdUsage')
              .call({
            'campaign_id': ad.campaignId,
            'city_id': ad.cityId,
            'position': position,
            'views': views,
            'clicks': clicks,
          });
          if (result.data is Map && result.data['campaign_active'] == false) {
            toPrune.add(ad.campaignId);
          }
        } catch (_) {
          // Charge failed after counters were already persisted - accepted
          // as a tiny under-bill rather than retried (see comment above).
        }
      }
    }

    if (toPrune.isNotEmpty) {
      _cache.removeWhere((ad) => toPrune.contains(ad.campaignId));
    }
  }

  double _asDouble(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

  // UTC + zero-padded, matching the server's `toISOString().slice(...)` in
  // chargeAdUsage - a local-time day key here would let the client's
  // "is this still today" checks (spent_today/spent_month eligibility, and
  // the day rollover for seenDay) disagree with the server's UTC-based
  // truth near midnight for any non-UTC+0 device.
  String _dayKey(DateTime d) => d.toUtc().toIso8601String().substring(0, 10);
  String _monthKey(DateTime d) => d.toUtc().toIso8601String().substring(0, 7);
}
