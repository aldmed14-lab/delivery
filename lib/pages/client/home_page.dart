import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_application_1/pages/client/app_bottom_nav.dart';
import 'package:flutter_application_1/pages/client/location_picker_sheet.dart';
import 'package:flutter_application_1/pages/client/search_page.dart';
import 'package:flutter_application_1/pages/client/select_location_page.dart';
import 'package:flutter_application_1/pages/client/store_details_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/banner_service.dart';
import 'package:flutter_application_1/utils/city_resolver.dart';
import 'package:flutter_application_1/utils/connection.dart';
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
  _HomePageState createState() => _HomePageState();
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
  String? cityName;

  /// Name of the currently active saved address (null for the unnamed
  /// "current location" default) - just for highlighting the active row in
  /// [LocationPickerSheet].
  String? _activeLocationName;
  bool _needsLocation = false;

  /// True while an on-demand "use current location" GPS lookup (see
  /// [_useCurrentLocation]) is in flight, so its trigger button(s) can show
  /// a spinner instead of double-firing.
  bool _locatingCurrentPosition = false;
  int aaaa = 0;
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

  /// Loads the signed-in user's doc exactly once and hands its `address` to
  /// [_checkUserLocation] instead of that function re-fetching the same
  /// document again.
  Future<void> _initializeHomeData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    uid = user.uid;

    Map<String, dynamic>? data;
    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      data = userDoc.data();
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      }
    }

    name = data?['name'] ?? '';
    if (mounted) setState(() {});
    // Only overwrites the cache on an actual successful read - on a
    // transient fetch failure `data` is null, and blindly calling update()
    // would wipe out whatever the cache already had (e.g. from an earlier
    // successful load) to blank name/phone/role instead of just leaving it.
    if (data != null) {
      UserProfileCache.instance.update(
        name: data['name'] as String?,
        phone: data['phone'] as String?,
        role: data['role'] as String?,
      );
    }

    await _checkUserLocation(data?['address'] as Map<String, dynamic>?);
  }

  /// Uses the already-fetched `address` map as-is - no GPS call here, named
  /// or not: a "current location" address (unnamed, `location_name` null)
  /// is resolved once via [_useCurrentLocation] and then just as sticky as
  /// a named saved address until the user explicitly asks to re-resolve it.
  /// That keeps every normal app open instant instead of blocking on a
  /// fresh GPS fix. If there's no usable address yet, this sets
  /// [_needsLocation], whose prompt offers both a fast path (use current
  /// location, on demand) and the manual map picker. There is deliberately
  /// no "skip and see all cities" fallback.
  Future<void> _checkUserLocation(Map<String, dynamic>? address) async {
    String? validCity;
    String? validLocationName;
    try {
      final city = address?['city'] as String?;
      final lat = address?['lat'];
      final lng = address?['lng'];

      if (city != null && city.isNotEmpty && lat != null && lng != null) {
        final citySnapshot = await FirebaseFirestore.instance
            .collection('cities')
            .where('name', isEqualTo: city)
            .limit(1)
            .get();
        if (citySnapshot.docs.isNotEmpty) {
          validCity = city;
          validLocationName = address?['location_name'] as String?;
        }
      }
    } catch (_) {
      // Any error here falls through to the "add location" prompt - there
      // is no city to silently fall back to.
    }

    if (!mounted) return;

    if (validCity != null) {
      setState(() {
        cityName = validCity;
        _activeLocationName = validLocationName;
        _needsLocation = false;
      });
      fetchTrendingStores();
      _loadBannerAndAds(validCity);
    } else {
      setState(() => _needsLocation = true);
    }
  }

  Future<void> _openSelectMap({required bool canCancel}) async {
    if (!mounted) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelectMapPage(widget.language, canCancel: canCancel),
      ),
    );
    if (mounted && result is Map && result['city'] != null) {
      final newCity = result['city'] as String;
      setState(() {
        cityName = newCity;
        _activeLocationName = null;
        _needsLocation = false;
      });
      fetchTrendingStores();
      _loadBannerAndAds(newCity);
    }
  }

  /// Opens the saved-address list (see [LocationPickerSheet]). Picking a
  /// saved address makes it the active, named `address` (no more live GPS
  /// re-check on future loads); "+ Add address" hands off to
  /// [_addNewAddress] to pick a new point on the map and name it.
  Future<void> _openLocationPicker() async {
    if (uid.isEmpty) {
      _openSelectMap(canCancel: true);
      return;
    }

    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LocationPickerSheet(
        uid: uid,
        language: widget.language,
        activeCity: cityName,
        activeLocationName: _activeLocationName,
      ),
    );

    if (!mounted || result == null) return;

    if (result == 'add') {
      await _addNewAddress();
      return;
    }

    if (result == 'current') {
      await _useCurrentLocation();
      return;
    }

    if (result is Map) {
      final city = result['city'] as String?;
      if (city == null || city.isEmpty) return;
      final locationName = result['name'] as String?;

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'address': {
          'location_name': locationName,
          'lat': result['lat'],
          'lng': result['lng'],
          'city': city,
        },
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        cityName = city;
        _activeLocationName = locationName;
        _needsLocation = false;
      });
      fetchTrendingStores();
      _loadBannerAndAds(city);
    }
  }

  /// On-demand GPS resolve (see [CityResolver]) - only runs when the user
  /// explicitly asks for it (the "needs location" screen's fast-path button,
  /// or the picker sheet's "Use current location" row), never automatically
  /// on app open. Success makes it the active, unnamed address; failure
  /// shows an inline message instead of blocking the whole page.
  Future<void> _useCurrentLocation() async {
    if (_locatingCurrentPosition) return;
    setState(() => _locatingCurrentPosition = true);

    final result = await CityResolver.resolveFromDevice();

    if (!mounted) return;
    setState(() => _locatingCurrentPosition = false);

    switch (result.status) {
      case CityResolveStatus.resolved:
        final city = result.city!;
        if (uid.isNotEmpty) {
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            'address': {
              'location_name': null,
              'lat': result.lat,
              'lng': result.lng,
              'city': city,
            },
          }, SetOptions(merge: true));
        }
        if (!mounted) return;
        setState(() {
          cityName = city;
          _activeLocationName = null;
          _needsLocation = false;
        });
        fetchTrendingStores();
        _loadBannerAndAds(city);
        break;
      case CityResolveStatus.outOfZone:
        _showSnack(TranslationHelper.get('not_in_delivery_zone'),
            isError: true);
        break;
      case CityResolveStatus.unavailable:
        _showSnack(TranslationHelper.get('location_lookup_failed'),
            isError: true);
        break;
    }
  }

  /// Picks a point on the map, names it, saves it to
  /// `users/{uid}/locations` and makes it the active address.
  Future<void> _addNewAddress() async {
    if (!mounted) return;
    final picked = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelectMapPage(widget.language, canCancel: true),
      ),
    );
    if (!mounted || picked is! Map || picked['city'] == null) return;

    final city = picked['city'] as String;
    final lat = picked['lat'];
    final lng = picked['lng'];

    final addressName = await _promptAddressName();
    if (!mounted || addressName == null || addressName.trim().isEmpty) return;
    final trimmedName = addressName.trim();

    if (uid.isNotEmpty) {
      // Saving the address to the user's location list and setting it as
      // the active address are two writes for one action - batched so a
      // dropped connection between them can't save one without the other
      // and leave the saved-address list out of sync with the active one.
      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final newLocationRef = userRef.collection('locations').doc();
      final batch = FirebaseFirestore.instance.batch();
      batch.set(newLocationRef,
          {'name': trimmedName, 'lat': lat, 'lng': lng, 'city': city});
      batch.set(
        userRef,
        {
          'address': {
            'location_name': trimmedName,
            'lat': lat,
            'lng': lng,
            'city': city,
          },
        },
        SetOptions(merge: true),
      );
      await batch.commit();
    }

    if (!mounted) return;
    setState(() {
      cityName = city;
      _activeLocationName = trimmedName;
      _needsLocation = false;
    });
    fetchTrendingStores();
    _loadBannerAndAds(city);
  }

  Future<String?> _promptAddressName() {
    final controller = TextEditingController();
    final isArabic = widget.language == 'ar';
    return showDialog<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(TranslationHelper.get('add_address')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: TranslationHelper.get('address_name_hint'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(TranslationHelper.get('cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(TranslationHelper.get('save')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Not stopping/flushing AdService here - HomeShell owns that timer's
    // lifetime now (see home_shell.dart), since this page's own dispose
    // only fires when the whole shell is torn down anyway (its State stays
    // alive across tab switches in the shell's IndexedStack), so stopping
    // it here and starting it there was two places doing the same job.
    WidgetsBinding.instance.removeObserver(this);
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
  /// picks one "home" slot ad and marks it seen. Called whenever the
  /// resolved city changes (initial location fix or manual city switch).
  ///
  /// Guarded with a request id so that if this fires twice in quick
  /// succession (e.g. a duplicate init call), an older, slower response
  /// can't land after a newer one and stomp its result.
  Future<void> _loadBannerAndAds(String city) async {
    final requestId = ++_bannerAdsRequestId;
    if (mounted) setState(() => _adsReady = false);

    // Fired together instead of one after the other - neither depends on
    // the other's result, so there's no reason to pay for both round-trips
    // in sequence.
    final bannerFuture = BannerService.fetchForCity(city);
    final adsRefreshFuture = AdService.instance.refresh(city);
    final banner = await bannerFuture;
    await adsRefreshFuture;
    final ad = AdService.instance.nextAdFor('home');
    if (ad != null) AdService.instance.recordView(ad, 'home');
    // Not starting the flush/refresh timers here - HomeShell already
    // started them once for the whole session (see home_shell.dart).

    if (!mounted || requestId != _bannerAdsRequestId) return;
    setState(() {
      _cityBanner = banner;
      _homeAd = ad;
      _adsReady = true;
    });
  }

  Future<void> fetchTrendingStores() async {
    if (!_hasInternetConnection) {
      _showSnack(TranslationHelper.get('no_internet'));
      return;
    }
    // No city, no query - there's no "show stores from everywhere" fallback.
    if (cityName == null) return;

    try {
      setState(() {
        isLoading = true;
        stores = [];
        lastDocument = null;
        hasMoreData = true;
      });

      Query query = FirebaseFirestore.instance
          .collection("stores")
          .where("start", isEqualTo: true)
          .where("city", isEqualTo: cityName);
      QuerySnapshot querySnapshot =
          await query.orderBy('trend', descending: true).limit(pageSize).get();

      if (querySnapshot.docs.isNotEmpty) {
        setState(() {
          stores = querySnapshot.docs;
          lastDocument = querySnapshot.docs.last;
          isLoading = false;
        });
      } else {
        setState(() {
          hasMoreData = false;
          isLoading = false;
        });
      }
    } catch (e) {
      _showSnack(TranslationHelper.get(
          isConnectivityError(e) ? 'no_internet' : 'error'));
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> loadMoreStores() async {
    if (!hasMoreData || isLoadingMore || stores.length >= 30) return;
    if (cityName == null) return;

    try {
      setState(() {
        isLoadingMore = true;
      });

      Query query = FirebaseFirestore.instance
          .collection("stores")
          .where("start", isEqualTo: true)
          .where("city", isEqualTo: cityName);
      QuerySnapshot querySnapshot = await query
          .orderBy('trend', descending: true)
          .startAfterDocument(lastDocument!)
          .limit(pageSize)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        setState(() {
          stores.addAll(querySnapshot.docs);
          lastDocument = querySnapshot.docs.last;
          isLoadingMore = false;
        });
      } else {
        setState(() {
          hasMoreData = false;
          isLoadingMore = false;
        });
      }
    } catch (e) {
      _showSnack(TranslationHelper.get(
          isConnectivityError(e) ? 'no_internet' : 'error'));
      setState(() {
        isLoadingMore = false;
      });
    }
  }

  Future<void> refreshStores() async {
    // Fired together - fetchTrendingStores' own Firestore query doesn't
    // depend on the ads/banner refresh (or vice versa), so there's no
    // reason to make the pull-to-refresh gesture wait for both in
    // sequence. _loadBannerAndAds still respects AdService's own staleness
    // window, so this can't spam Firestore reads on a rapid double-pull.
    final city = cityName;
    await Future.wait([
      fetchTrendingStores(),
      if (city != null) _loadBannerAndAds(city),
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
                  onPressed: () => _openSelectMap(canCancel: false),
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
                  _buildCategoryChip(TranslationHelper.get('coffee'), "coffee",
                      Icons.coffee_rounded),
                  _buildCategoryChip(TranslationHelper.get('desserts'),
                      "desserts", Icons.icecream_rounded),
                  _buildCategoryChip(TranslationHelper.get('burger'), "burger",
                      Icons.lunch_dining_rounded),
                  _buildCategoryChip(TranslationHelper.get('shawerma'),
                      "shawerma", Icons.kebab_dining_rounded),
                  _buildCategoryChip(TranslationHelper.get('kebab'), "kebab",
                      Icons.dinner_dining_rounded),
                  _buildCategoryChip(TranslationHelper.get('fish'), "fish",
                      Icons.set_meal_rounded),
                  _buildCategoryChip(TranslationHelper.get('healthy'),
                      "healthy", Icons.eco_rounded),
                  _buildCategoryChip(TranslationHelper.get('drinks'), "drinks",
                      Icons.local_drink_rounded),
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
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 12, 12, 0),
                                  sliver: SliverToBoxAdapter(
                                    child: _buildCityBannerImage(),
                                  ),
                                ),
                              if (_homeAd != null)
                                SliverPadding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
                      cityName ?? TranslationHelper.get('delivery_location'),
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
            ddd();
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

  Future<void> ddd() async {
    if (cityName == null) return;
    if (_hasInternetConnection == true) {
      try {
        setState(() {
          isLoading = true;
          stores = [];
          lastDocument = null;
          hasMoreData = true;
        });
        // Get first batch of trending stores
        Query query = FirebaseFirestore.instance
            .collection("stores")
            .where("start", isEqualTo: true)
            .where("city", isEqualTo: cityName);
        if (isSelected != "all") {
          query = query.where("tags", arrayContains: isSelected);
        }
        QuerySnapshot querySnapshot = await query
            .orderBy('trend', descending: true)
            .limit(pageSize)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          setState(() {
            stores = querySnapshot.docs;
            lastDocument = querySnapshot.docs.last;
            isLoading = false;
          });
        } else {
          setState(() {
            hasMoreData = false;
            isLoading = false;
          });
        }
      } catch (e) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        setState(() {
          isLoading = false;
        });
      }
    } else {
      _showSnack(TranslationHelper.get('no_internet'));
      setState(() {
        isLoading = false;
      });
    }
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
