import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_application_1/pages/client/address_flow.dart';
import 'package:flutter_application_1/pages/client/app_bottom_nav.dart';
import 'package:flutter_application_1/pages/client/search_page.dart';
import 'package:flutter_application_1/pages/client/store_details_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/banner_service.dart';
import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:flutter_application_1/utils/city_resolver.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/location_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/utils/user_profile_cache.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';
import 'package:flutter_application_1/widgets/store_grid_card.dart';

class HomePage extends StatefulWidget {
  final String language;

  /// Switches the shared bottom nav to another tab instead of pushing a new
  /// route - set when this page is hosted inside [HomeShell]. Falls back to
  /// pushing [SearchPage] when null (e.g. if HomePage is ever used stand-
  /// alone outside the shell).
  final ValueChanged<int>? onNavigateTab;

  const HomePage(this.language, {this.onNavigateTab, super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<DocumentSnapshot> stores = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  DocumentSnapshot? lastDocument;
  static const int pageSize = 7;
  bool hasMoreData = true;
  final ScrollController _scrollController = ScrollController();
  String isSelected = "all";
  String uid = "";
  String name = "";
  /// The active location's city (LocationService) - what the feed, banner
  /// and ads are for.
  String? _cityId;
  double? _activeLat;
  double? _activeLng;
  bool _needsLocation = false;

  /// True while an on-demand "use current location" GPS lookup (see
  /// [_useCurrentLocation]) is in flight, so its trigger button(s) can show
  /// a spinner instead of double-firing.
  bool _locatingCurrentPosition = false;
  bool _isDialogShowing = false;
  final InternetConnectionService _connectionService =
      InternetConnectionService();
  bool _hasInternetConnection = false;
  bool _alreadyChecked = false;
  StreamSubscription<bool>? _connectionSub;

  CityBanner? _cityBanner;
  CachedAd? _homeAd;

  /// Set once the banner/ad load finishes, so the store section can wait
  /// for it alongside [isLoading] and reveal everything in one go instead
  /// of showing the store list first and having the banner/ad shove it down
  /// a moment later.
  bool _adsReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LocationService.instance.addListener(_onLocationChanged);
    _initConnectivity();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent * 0.8 &&
          !isLoadingMore &&
          hasMoreData &&
          stores.length < 30 &&
          _hasInternetConnection) {
        loadMoreStores();
      }
    });
  }

  Future<void> _initConnectivity() async {
    // Step 1: Immediate check
    bool initialConnection = await _connectionService.checkNow();

    if (!mounted) return;

    setState(() {
      _hasInternetConnection = initialConnection;
    });

    // Step 2: If already connected, load user info + location, then stores
    if (initialConnection) {
      _alreadyChecked = true;
      _initializeHomeData();
    } else {
      _showSnack(TranslationHelper.get('no_internet'));
    }

    // Step 3: Listen for future changes
    _connectionSub =
        _connectionService.connectionStream.listen((hasConnection) {
      if (!mounted) return;

      setState(() {
        _hasInternetConnection = hasConnection;
      });

      // If regained connection, fetch data once
      if (!_alreadyChecked && hasConnection) {
        _alreadyChecked = true;
        _initializeHomeData();
      }

      if (!_alreadyChecked && !hasConnection) {
        _showSnack(TranslationHelper.get('no_internet'));
      }
    });
  }

  /// Home start (lib/note.txt LOCATION SYSTEM "home start"):
  ///  1. instant - the last active location saved on this phone, so the
  ///     city's stores show without waiting for the network or GPS;
  ///  2. background - cities (re-downloaded only if cities_version changed,
  ///     then saved addresses re-checked), the user doc, the default saved
  ///     address (switched to if it differs), and a quiet GPS check;
  ///  3. default_address_id == "current_location" (the user picked current
  ///     location) or no saved address - fresh GPS, browsing only (the
  ///     point is NOT saved); if GPS fails, the last local location, else
  ///     the "Where should we deliver?" screen.
  /// Only [LocationService] is touched here - [_onLocationChanged] is the
  /// single place that applies a location to the page.
  Future<void> _initializeHomeData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    uid = user.uid;

    final location = LocationService.instance;
    final local = await location.loadLocal();

    var citiesChanged = false;
    try {
      citiesChanged = await CitiesService.instance.ensureLoaded();
    } catch (_) {
      // Offline with no local copy - nothing can be resolved yet.
      if (local == null && mounted) {
        setState(() => _needsLocation = true);
        _showSnack(TranslationHelper.get('no_internet'));
      }
      return;
    }
    if (local != null) _onLocationChanged();

    Map<String, dynamic>? data;
    try {
      data =
          (await FirebaseFirestore.instance.collection('users').doc(uid).get())
              .data();
    } catch (e) {
      // Keep whatever the phone already had; nothing to compare against.
      if (local == null && mounted) {
        setState(() => _needsLocation = true);
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      }
      return;
    }

    name = data?['name'] ?? '';
    if (mounted) setState(() {});
    if (data != null) {
      UserProfileCache.instance.update(
        name: data['name'] as String?,
        phone: data['phone'] as String?,
        role: data['role'] as String?,
      );
    }

    if (citiesChanged) {
      try {
        await location.recheckAddresses();
      } catch (_) {}
    }

    SavedAddress? defaultAddress;
    try {
      defaultAddress = await location.fetchDefault(data);
    } catch (_) {}
    if (!mounted) return;

    if (defaultAddress != null) {
      final active = location.active;
      if (active == null ||
          active.addressId != defaultAddress.id ||
          active.lat != defaultAddress.lat ||
          active.lng != defaultAddress.lng ||
          active.cityId != defaultAddress.cityId) {
        await location.applyDefault(defaultAddress);
      }
      _checkMovedCity();
      return;
    }

    // default_address_id == "current_location" (fetchDefault returns null
    // for it), or no usable saved address: read the GPS fresh every start.
    // If it fails, keep the last location this phone had.
    final result = await CityResolver.resolveFromDevice();
    if (!mounted) return;
    if (result.status == CityResolveStatus.resolved) {
      await location.useUnsaved(
          lat: result.lat!, lng: result.lng!, cityId: result.cityId!);
    } else if (location.active == null) {
      setState(() => _needsLocation = true);
    }
  }

  /// Follows [LocationService] - every location change (home start, the
  /// picker, a new address, checkout, the moved-city banner) lands here.
  void _onLocationChanged() {
    if (!mounted) return;
    final active = LocationService.instance.active;
    if (active == null) {
      // E.g. the active saved address was deleted / left every city.
      if (CitiesService.instance.isLoaded && uid.isNotEmpty) {
        _statusSub?.cancel();
        setState(() {
          _cityId = null;
          _needsLocation = true;
        });
      }
      return;
    }
    final pointChanged =
        active.lat != _activeLat || active.lng != _activeLng;
    _activeLat = active.lat;
    _activeLng = active.lng;
    if (active.cityId != _cityId) {
      _activateCity(active.cityId);
    } else {
      setState(() {});
      // Same city, new point: the too-far filter depends on the point.
      if (pointChanged && _serviceStopMessage == null && _feedCityId != null) {
        _loadStores(reset: true);
      }
    }
  }

  /// Set when the active city isn't taking orders - its stop reason (+
  /// reopen time), or "no service right now". Replaces the feed; the
  /// header's location switcher still works.
  String? _serviceStopMessage;
  StreamSubscription<CityStatus>? _statusSub;

  /// The city whose feed is currently loaded (null while it isn't).
  String? _feedCityId;

  void _activateCity(String cityId) {
    setState(() {
      _cityId = cityId;
      _needsLocation = false;
      _serviceStopMessage = null;
      if (_movedCitySuggestion?.cityId == cityId) _movedCitySuggestion = null;
      isLoading = true;
      stores = [];
      _feedCityId = null;
    });

    // Live status: a pause or reopen shows up without a restart.
    _statusSub?.cancel();
    _statusSub = CitiesService.instance.watchStatus(cityId).listen(
      (status) {
        if (!mounted || cityId != _cityId) return;
        final message = status.message(widget.language);
        if (message != null) {
          setState(() {
            _serviceStopMessage = message;
            isLoading = false;
            _feedCityId = null;
          });
          return;
        }
        if (_serviceStopMessage != null || _feedCityId != cityId) {
          setState(() => _serviceStopMessage = null);
          _feedCityId = cityId;
          _loadStores(reset: true);
          _loadBannerAndAds(cityId);
        }
      },
      // Offline: keep showing the last known state - never flash
      // "no service" just because the network dropped.
      onError: (Object e) {
        if (!mounted || cityId != _cityId || _feedCityId == cityId) return;
        setState(() => isLoading = false);
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      },
    );
  }

  /// "You seem to be in {city}" - set by [_checkMovedCity].
  CityResolveResult? _movedCitySuggestion;
  bool _movedCityChecked = false;

  /// Once per session, after starting from a saved address: if the device
  /// is in a different city that's taking orders, suggest switching. Never
  /// asks for location permission and never switches by itself.
  Future<void> _checkMovedCity() async {
    if (_movedCityChecked) return;
    _movedCityChecked = true;

    final result =
        await CityResolver.resolveFromDevice(requestPermission: false);
    if (!mounted ||
        result.status != CityResolveStatus.resolved ||
        result.cityId == LocationService.instance.cityId) {
      return;
    }
    try {
      final status = await CitiesService.instance.fetchStatus(result.cityId!);
      if (!status.active) return;
    } catch (_) {
      return;
    }
    if (!mounted || result.cityId == LocationService.instance.cityId) return;
    setState(() => _movedCitySuggestion = result);
  }

  /// "Switch" on the banner: browse where the device is (not saved) and
  /// make "current location" the default.
  Future<void> _acceptMovedCity() async {
    final suggestion = _movedCitySuggestion;
    if (suggestion == null) return;
    setState(() => _movedCitySuggestion = null);
    try {
      await LocationService.instance.useCurrentAsDefault(
          lat: suggestion.lat!,
          lng: suggestion.lng!,
          cityId: suggestion.cityId!);
    } catch (e) {
      _showSnack(TranslationHelper.get(
          isConnectivityError(e) ? 'no_internet' : 'error'));
    }
  }

  Future<void> _openLocationPicker() =>
      AddressFlow.openPicker(context, widget.language);

  /// "Where should we deliver?" - [Use my location].
  Future<void> _useCurrentLocation() async {
    if (_locatingCurrentPosition) return;
    setState(() => _locatingCurrentPosition = true);
    await AddressFlow.useCurrentLocation(context, widget.language);
    if (mounted) setState(() => _locatingCurrentPosition = false);
  }

  /// "Where should we deliver?" - [Choose on map]: pin -> label -> SAVED.
  Future<void> _chooseOnMap() =>
      AddressFlow.addAddress(context, widget.language);

  @override
  void dispose() {
    // Not stopping/flushing AdService here - HomeShell owns that timer's
    // lifetime (see home_shell.dart).
    WidgetsBinding.instance.removeObserver(this);
    LocationService.instance.removeListener(_onLocationChanged);
    _statusSub?.cancel();
    _scrollController.dispose();
    _connectionSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AdService.instance.flush();
    }
  }

  int _bannerAdsRequestId = 0;

  /// Loads the city's head banner and refreshes the shared ad cache, then
  /// picks one "home" slot ad and marks it seen. Guarded with a request id
  /// so an older, slower response can't land after a newer one.
  Future<void> _loadBannerAndAds(String cityId) async {
    final requestId = ++_bannerAdsRequestId;
    if (mounted) setState(() => _adsReady = false);

    final bannerFuture = BannerService.fetchForCity(cityId);
    final adsRefreshFuture = AdService.instance.refresh(cityId);
    final banner = await bannerFuture;
    await adsRefreshFuture;
    final ad = AdService.instance.nextAdFor('home');
    if (ad != null) AdService.instance.recordView(ad, 'home');

    if (!mounted || requestId != _bannerAdsRequestId) return;
    setState(() {
      _cityBanner = banner;
      _homeAd = ad;
      _adsReady = true;
    });
  }

  static const int _maxStores = 30;
  int _storesRequestId = 0;

  /// The store feed: start + city_id (+ tag) + trend. Stores beyond their
  /// max_delivery_km from the active location are HIDDEN; since Firestore
  /// can't filter by distance, pages keep loading until a page's worth of
  /// visible stores is collected (or there's no more data), so the feed
  /// never looks empty while closer stores exist. [reset] starts over
  /// (new city / point / category / pull-to-refresh).
  Future<void> _loadStores({required bool reset}) async {
    final cityId = _cityId;
    final active = LocationService.instance.active;
    if (cityId == null || active == null) return;
    if (!reset && (!hasMoreData || isLoadingMore || stores.length >= _maxStores)) {
      return;
    }
    if (!_hasInternetConnection) {
      _showSnack(TranslationHelper.get('no_internet'));
      return;
    }

    final requestId = ++_storesRequestId;
    setState(() {
      if (reset) {
        isLoading = true;
        stores = [];
        lastDocument = null;
        hasMoreData = true;
      } else {
        isLoadingMore = true;
      }
    });

    try {
      final visible = <DocumentSnapshot>[];
      var cursor = reset ? null : lastDocument;
      var more = true;
      final target = (stores.length + pageSize).clamp(0, _maxStores);
      while (more && stores.length + visible.length < target) {
        Query query = FirebaseFirestore.instance
            .collection('stores')
            .where('start', isEqualTo: true)
            .where('city_id', isEqualTo: cityId);
        if (isSelected != 'all') {
          query = query.where('tags', arrayContains: isSelected);
        }
        query = query.orderBy('trend', descending: true);
        if (cursor != null) query = query.startAfterDocument(cursor);
        final snap = await query.limit(pageSize).get();
        if (snap.docs.isEmpty) {
          more = false;
          break;
        }
        cursor = snap.docs.last;
        if (snap.docs.length < pageSize) more = false;
        for (final doc in snap.docs) {
          final data = doc.data() as Map<String, dynamic>;
          if (!CitiesService.instance.isTooFar(data, active.lat, active.lng)) {
            visible.add(doc);
          }
        }
      }

      // A newer load (city/point/category change) took over.
      if (!mounted || requestId != _storesRequestId) return;
      setState(() {
        stores = [...stores, ...visible].take(_maxStores).toList();
        lastDocument = cursor;
        hasMoreData = more && stores.length < _maxStores;
        isLoading = false;
        isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || requestId != _storesRequestId) return;
      _showSnack(TranslationHelper.get(
          isConnectivityError(e) ? 'no_internet' : 'error'));
      setState(() {
        isLoading = false;
        isLoadingMore = false;
      });
    }
  }

  Future<void> loadMoreStores() => _loadStores(reset: false);

  Future<void> refreshStores() async {
    final cityId = _cityId;
    await Future.wait([
      _loadStores(reset: true),
      if (cityId != null) _loadBannerAndAds(cityId),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // Set the text direction based on language
    final isArabic = widget.language == 'ar';

    // Nothing else in this page - drawer, search, cart, store feed - is
    // reachable until a valid, serviced city has been resolved. While that
    // resolution is still in flight (not yet known to need a location
    // prompt), fall through to the normal shell below instead of a bare
    // spinner screen - the header renders with a placeholder city label and
    // the store section already shows its skeleton while `isLoading` is
    // true, so there's no separate blank loading screen to flash through.
    if (_needsLocation) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.location_off_outlined,
                  size: 72,
                  color: Color(0xFFFF9800),
                ),
                const SizedBox(height: 24),
                Text(
                  TranslationHelper.get('add_location_to_start'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed:
                        _locatingCurrentPosition ? null : _useCurrentLocation,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9800),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade400,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _locatingCurrentPosition
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            TranslationHelper.get('use_current_location'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _chooseOnMap,
                  child: Text(
                    TranslationHelper.get('choose_on_map'),
                    style: const TextStyle(
                      color: Color(0xFF677489),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Directionality(
      // Apply RTL direction for Arabic language
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: Column(
          children: [
            _buildHeader(isArabic),

            if (_movedCitySuggestion != null) _buildMovedCityBanner(isArabic),

            // City not serviced right now - its stop_reason instead of the
            // feed. Chips are hidden too, since picking one would query
            // stores for a city that isn't running.
            if (_serviceStopMessage != null)
              Expanded(child: _buildServiceStopped(_serviceStopMessage!))
            else ...[
              // Category chips
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                height: 96,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _buildCategoryChip(TranslationHelper.get('all'), "all",
                        Icons.grid_view_rounded),
                    _buildCategoryChip(TranslationHelper.get('fast food'),
                        "fast food", Icons.fastfood_rounded),
                    _buildCategoryChip(TranslationHelper.get('pizza'), "pizza",
                        Icons.local_pizza_rounded),
                    _buildCategoryChip(TranslationHelper.get('coffee'),
                        "coffee", Icons.coffee_rounded),
                    _buildCategoryChip(TranslationHelper.get('desserts'),
                        "desserts", Icons.icecream_rounded),
                    _buildCategoryChip(TranslationHelper.get('burger'),
                        "burger", Icons.lunch_dining_rounded),
                    _buildCategoryChip(TranslationHelper.get('shawerma'),
                        "shawerma", Icons.kebab_dining_rounded),
                    _buildCategoryChip(TranslationHelper.get('kebab'), "kebab",
                        Icons.dinner_dining_rounded),
                    _buildCategoryChip(TranslationHelper.get('fish'), "fish",
                        Icons.set_meal_rounded),
                    _buildCategoryChip(TranslationHelper.get('healthy'),
                        "healthy", Icons.eco_rounded),
                    _buildCategoryChip(TranslationHelper.get('drinks'),
                        "drinks", Icons.local_drink_rounded),
                  ],
                ),
              ),

              // Stores list - waits for the banner/ad load too, so the store
              // grid and the sponsored slots above it appear together instead
              // of the grid rendering first and the banner/ad shoving it down
              // a moment later.
              Expanded(
                child: (isLoading || !_adsReady)
                    ? _buildLoadingSkeletons(isArabic)
                    : stores.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.lock_clock,
                                  size: 80,
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  TranslationHelper.get('no_stores_available'),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            color: const Color(0xFFFF9800),
                            onRefresh: refreshStores,
                            child: CustomScrollView(
                              controller: _scrollController,
                              slivers: [
                                if (_cityBanner != null)
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(
                                        12, 12, 12, 0),
                                    sliver: SliverToBoxAdapter(
                                      child: _buildCityBannerImage(),
                                    ),
                                  ),
                                if (_homeAd != null)
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(
                                        12, 12, 12, 0),
                                    sliver: SliverToBoxAdapter(
                                      child: _buildSponsoredAdCard(),
                                    ),
                                  ),
                                SliverPadding(
                                  padding: const EdgeInsets.all(12),
                                  sliver: SliverGrid(
                                    gridDelegate: storeGridDelegate,
                                    delegate: SliverChildBuilderDelegate(
                                      (context, storeIndex) {
                                        var store = stores[storeIndex].data()
                                            as Map<String, dynamic>;
                                        String name =
                                            store['name_${widget.language}'] ??
                                                'Unknown Store';
                                        String namear =
                                            store['name_ar'] ?? 'Unknown Store';
                                        String namefr =
                                            store['name_fr'] ?? 'Unknown Store';
                                        String isOpen =
                                            store['status'] ?? "close";
                                        String imageUrl = store['image'] ??
                                            'https://via.placeholder.com/150';
                                        int rateNumbers =
                                            store['rate_numbers'] ?? 0;
                                        double rating = (rateNumbers <= 100)
                                            ? 0
                                            : (store['rate'] ?? 0).toDouble();
                                        int? deliveryMinutes =
                                            (store['estimated_delivery_time']
                                                    as num?)
                                                ?.toInt();

                                        return _buildStoreCard(
                                          context,
                                          name,
                                          isOpen,
                                          imageUrl,
                                          rateNumbers,
                                          rating,
                                          deliveryMinutes,
                                          stores[storeIndex].id,
                                          namear,
                                          namefr,
                                        );
                                      },
                                      childCount: stores.length,
                                    ),
                                  ),
                                ),
                                if (isLoadingMore)
                                  const SliverToBoxAdapter(
                                    child: Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: Center(
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
            ],
          ],
        ),
      ),
    );
  }

  /// "You seem to be in {city} - switch?" (see [_checkMovedCity]).
  Widget _buildMovedCityBanner(bool isArabic) {
    final city = CitiesService.instance
        .cityName(_movedCitySuggestion!.cityId, widget.language);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3E0),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFFFD8A8)),
        ),
        child: Row(
          children: [
            const Icon(Icons.near_me_rounded,
                color: Color(0xFFFF9800), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                TranslationHelper.get('moved_city_message', {'city': city}),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            TextButton(
              onPressed: _acceptMovedCity,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFF9800),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(
                TranslationHelper.get('switch_city'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _movedCitySuggestion = null),
              icon: const Icon(Icons.close, size: 18, color: Color(0xFF9AA1AC)),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceStopped(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                color: Color(0xFFFFF3E0),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.pause_circle_outline_rounded,
                  size: 40, color: Color(0xFFFF9800)),
            ),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2E3A59),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Gradient header: city switcher, greeting, search entry.
  /// Matches the "Home Page" design's head section.
  Widget _buildHeader(bool isArabic) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(6, topPadding + 6, 6, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openLocationPicker,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.location_on, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _headerLabel(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_arrow_down,
                      color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              TranslationHelper.get('home_greeting'),
              textAlign: isArabic ? TextAlign.right : TextAlign.left,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                if (widget.onNavigateTab != null) {
                  widget.onNavigateTab!(AppBottomNav.searchIndex);
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SearchPage(widget.language),
                    ),
                  );
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  textDirection:
                      isArabic ? TextDirection.rtl : TextDirection.ltr,
                  children: [
                    const Icon(Icons.search,
                        color: Color(0xFF9AA1AC), size: 20),
                    const SizedBox(width: 10),
                    Text(
                      TranslationHelper.get('search_hint'),
                      style: const TextStyle(
                        color: Color(0xFF9AA1AC),
                        fontSize: 14,
                      ),
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

  /// The saved address's label (+ city), "Current location" (+ city) for
  /// the unsaved GPS one, or a placeholder while nothing is resolved yet.
  String _headerLabel() {
    final active = LocationService.instance.active;
    if (active == null) return TranslationHelper.get('delivery_location');
    final city =
        CitiesService.instance.cityName(active.cityId, widget.language);
    final label = active.label ?? TranslationHelper.get('current_location');
    return city.isEmpty ? label : '$label · $city';
  }

  Widget _buildCityBannerImage() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 380 / 130,
        child: CachedNetworkImage(
          imageUrl: _cityBanner!.imageUrl,
          fit: BoxFit.cover,
          placeholder: (context, url) => Container(color: Colors.grey[300]),
          errorWidget: (context, url, error) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, 'home');
    if (ad.actionType == 'store' && ad.actionValue.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => StoreDetails(
              widget.language, ad.actionValue, uid, '', '', ad.imageUrl ?? ''),
        ),
      );
    } else if (ad.actionType == 'url' && ad.actionValue.isNotEmpty) {
      openExternalUrl(ad.actionValue);
    }
  }

  Widget _buildSponsoredAdCard() {
    final ad = _homeAd!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SponsoredAdCard(
        ad: ad,
        language: widget.language,
        onTap: () => _handleAdTap(ad),
      ),
    );
  }

  Widget _buildCategoryChip(String label, String type, IconData icon) {
    final selected = isSelected == type;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: () {
          if (isSelected != type) {
            setState(() => isSelected = type);
            _loadStores(reset: true);
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFFFF3E0)
                    : const Color(0xFFF0F1F4),
                borderRadius: BorderRadius.circular(16),
                border: selected
                    ? Border.all(color: const Color(0xFFFF9800), width: 2)
                    : null,
              ),
              child: Icon(
                icon,
                color: selected
                    ? const Color(0xFFFF9800)
                    : const Color(0xFF9AA1AC),
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected
                    ? const Color(0xFF2E3A59)
                    : const Color(0xFF677489),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoreCard(
      BuildContext context,
      String name,
      String isOpen,
      String imageUrl,
      int rateNumbers,
      double rating,
      int? deliveryMinutes,
      String id,
      String namear,
      String namefr) {
    return StoreGridCard(
      name: name,
      isOpen: isOpen,
      imageUrl: imageUrl,
      rateNumbers: rateNumbers,
      rating: rating,
      deliveryMinutes: deliveryMinutes,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              StoreDetails(widget.language, id, uid, namear, namefr, imageUrl),
        ),
      ),
    );
  }

  Widget _buildLoadingSkeletons(bool isArabic) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: storeGridDelegate,
      itemCount: 6,
      itemBuilder: (context, index) => const StoreGridCardSkeleton(),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted || _isDialogShowing) return;
    _isDialogShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final isArabic = widget.language == "ar";

        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          elevation: 10,
          child: Directionality(
            textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
            child: Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: widget.language == "fr"
                        ? [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isError
                                    ? const Color(0xFFFF3B30)
                                        .withValues(alpha: 0.1)
                                    : const Color(0xFF3D5CFF)
                                        .withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isError
                                    ? Icons.error_outline
                                    : Icons.info_outline,
                                color: isError
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF3D5CFF),
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              TranslationHelper.get('error'),
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF2E3A59),
                              ),
                            ),
                          ]
                        : [
                            Text(
                              TranslationHelper.get('error'),
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF2E3A59),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isError
                                    ? const Color(0xFFFF3B30)
                                        .withValues(alpha: 0.1)
                                    : const Color(0xFF3D5CFF)
                                        .withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isError
                                    ? Icons.error_outline
                                    : Icons.info_outline,
                                color: isError
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF3D5CFF),
                                size: 26,
                              ),
                            ),
                          ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    msg,
                    textAlign: isArabic ? TextAlign.right : TextAlign.left,
                    style: const TextStyle(
                      fontSize: 20,
                      color: Color(0xFF677489),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _isDialogShowing = false;
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isError
                            ? const Color(0xFFFF3B30)
                            : const Color(0xFF3D5CFF),
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('ok'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
