import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/store_details_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/connection_ui.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:flutter_application_1/widgets/sponsored_ad_card.dart';
import 'package:flutter_application_1/widgets/store_grid_card.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SearchPage extends StatefulWidget {
  final String language;

  /// Called instead of popping the route when set - used when this page is
  /// hosted as a persistent tab inside HomeShell (there's nothing to pop:
  /// it was never pushed), to switch back to the Home tab instead.
  final VoidCallback? onBack;

  const SearchPage(this.language, {this.onBack, super.key});

  @override
  _SearchPageState createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with AlertCardMixin {
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = false;
  bool _isSearching = false;
  List<Map<String, dynamic>> _trendingStores = [];
  List<Map<String, dynamic>> _searchResults = [];
  List<String> _recentSearches = [];
  String uid = "";
  String? cityName;
  CachedAd? _searchAd;

  static const String _recentSearchesKey = 'recent_searches';
  static const int _maxRecentSearches = 5;

  // Algolia - synced from the `stores` collection by the "Search in
  // Firestore with Algolia" Firebase Extension. This is the search-only
  // (public/read-only) API key: safe to ship inside the app, unlike the
  // admin key the extension itself uses to write the index.
  static const String _algoliaAppId = 'BMVSX1CD4X';
  static const String _algoliaSearchKey = '6297fb71b3d185a6ae62dc2dc9f0ce0e';
  static const String _algoliaIndex = 'store_search';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadRecentSearches();
    await _loadUserAndCity();
    await _fetchTrendingStores();
    // No refresh()/startAutoFlush()/startAutoRefresh() here - HomeShell
    // already keeps the shared ad cache refreshed and those timers running
    // for the whole session (see home_shell.dart); this just reads
    // whatever's cached.
    final ad = AdService.instance.nextAdFor('search');
    if (ad != null) AdService.instance.recordView(ad, 'search');
    if (mounted) setState(() => _searchAd = ad);
  }

  Future<void> _loadUserAndCity() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      uid = user.uid;

      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = userDoc.data();
      final city = (data?['address'] as Map<String, dynamic>?)?['city'];
      if (city is String && city.isNotEmpty) cityName = city;
    } catch (_) {
      // No city - the search ad slot just stays empty, everything else
      // (trending/search) works fine without it.
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    disposeAlert();
    // No AdService.flush() here - HomeShell owns the background flush
    // timer for the whole session (see home_shell.dart).
    super.dispose();
  }

  Future<void> _loadRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final searches = prefs.getStringList(_recentSearchesKey) ?? [];
      if (mounted) setState(() => _recentSearches = searches);
    } catch (e) {
      debugPrint("Erreur lors du chargement des recherches récentes: $e");
    }
  }

  Future<void> _saveRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentSearchesKey, _recentSearches);
    } catch (e) {
      debugPrint("Erreur lors de la sauvegarde des recherches récentes: $e");
    }
  }

  void _addToRecentSearches(String query) {
    if (query.isEmpty) return;
    setState(() {
      _recentSearches.remove(query);
      _recentSearches.insert(0, query);
      if (_recentSearches.length > _maxRecentSearches) {
        _recentSearches = _recentSearches.sublist(0, _maxRecentSearches);
      }
    });
    _saveRecentSearches();
  }

  void _removeFromRecentSearches(String query) {
    setState(() => _recentSearches.remove(query));
    _saveRecentSearches();
  }

  void _clearAllRecentSearches() {
    setState(() => _recentSearches = []);
    _saveRecentSearches();
  }

  void _handleAdTap(CachedAd ad) {
    AdService.instance.recordClick(ad, 'search');
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

  Future<void> _fetchTrendingStores() async {
    if (!mounted) return;
    // No city yet - there's no "show trending from everywhere" fallback,
    // same as the home page.
    if (cityName == null) return;
    setState(() => _isLoading = true);

    try {
      final QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('stores')
          .where('start', isEqualTo: true)
          .where('city', isEqualTo: cityName)
          .orderBy('trend', descending: true)
          .limit(5)
          .get();

      final List<Map<String, dynamic>> stores = snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data() as Map<String, dynamic>})
          .toList();

      if (mounted) {
        setState(() {
          _trendingStores = stores;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Erreur lors de la récupération des magasins tendance: $e");
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      }
    }
  }

  Future<void> _handleSearch(String query) async {
    if (query.trim().isEmpty) return;
    _addToRecentSearches(query);
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _isSearching = true;
      _searchResults = [];
    });

    try {
      // Algolia already has ranking/typo-tolerance built in, so there's no
      // local fuzzy-matching step here.
      final response = await http
          .post(
            Uri.parse(
                'https://$_algoliaAppId-dsn.algolia.net/1/indexes/$_algoliaIndex/query'),
            headers: {
              'X-Algolia-API-Key': _algoliaSearchKey,
              'X-Algolia-Application-Id': _algoliaAppId,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'hitsPerPage': 15,
              if (cityName != null) 'filters': 'city:"$cityName"',
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Algolia search failed (${response.statusCode})');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final hits = (decoded['hits'] as List?) ?? [];

      // Same "only show trending/featured stores" behavior as before -
      // Algolia hits carry every field the extension synced, including `start`.
      final List<Map<String, dynamic>> validStores = hits
          .cast<Map<String, dynamic>>()
          .where((hit) => hit['start'] == true)
          .map((hit) => {'id': hit['objectID'], ...hit})
          .toList();

      if (validStores.isEmpty) {
        await _fetchAdditionalTrendingStores([], 15);
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      if (validStores.length < 15) {
        await _fetchAdditionalTrendingStores(
            validStores, 15 - validStores.length);
      }

      if (mounted) {
        setState(() {
          _searchResults = validStores;
          _isLoading = false;
        });
      }
    } catch (e, stack) {
      debugPrint("❌ Search error: $e");
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      }
    }
  }

  Future<void> _fetchAdditionalTrendingStores(
      List<Map<String, dynamic>> existingStores, int limit) async {
    if (cityName == null) {
      if (mounted) {
        setState(() {
          _searchResults = existingStores;
          _isLoading = false;
        });
      }
      return;
    }

    try {
      final Set<String> existingIds =
          existingStores.map((store) => store['id'] as String).toSet();

      final QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('stores')
          .where('start', isEqualTo: true)
          .where('city', isEqualTo: cityName)
          .orderBy('trend', descending: true)
          .limit(limit + existingIds.length)
          .get();

      int addedCount = 0;
      for (var doc in snapshot.docs) {
        if (addedCount >= limit) break;
        final String storeId = doc.id;
        if (existingIds.contains(storeId)) continue;
        final storeData = doc.data() as Map<String, dynamic>;
        existingStores.add({'id': storeId, ...storeData});
        addedCount++;
      }

      if (mounted) {
        setState(() {
          _searchResults = existingStores;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint(
          "Erreur lors de la récupération des magasins tendance supplémentaires: $e");
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      }
    }
  }

  void _resetSearch() {
    setState(() {
      _isSearching = false;
      _searchController.clear();
    });
  }

  void _openStore(Map<String, dynamic> store) {
    final String id = store['id'] ?? '';
    if (id.isEmpty) {
      showAlert(TranslationHelper.get('invalid_store_id'), isError: true);
      return;
    }
    final String namear = store['name_ar'] ?? 'Sans nom';
    final String namefr = store['name_fr'] ?? 'Sans nom';
    final String imageUrl = store['image'] ?? 'https://via.placeholder.com/150';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            StoreDetails(widget.language, id, uid, namear, namefr, imageUrl),
      ),
    );
  }

  Widget _buildTrendingThumbnailCard(Map<String, dynamic> store) {
    final String name = store['name_${widget.language}'] ?? 'Sans nom';
    final String imageUrl = store['image'] ?? 'https://via.placeholder.com/150';
    final int rateNumbers = store['rate_numbers'] ?? 0;
    final double rating =
        (rateNumbers <= 100) ? 0 : (store['rate'] ?? 0).toDouble();

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openStore(store),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(18)),
              child: SizedBox(
                width: 110,
                height: 88,
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  placeholder: (c, u) => Container(color: Colors.grey[200]),
                  errorWidget: (c, u, e) => Container(
                    color: Colors.grey[200],
                    child: const Icon(Icons.restaurant, color: Colors.grey),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF2E3A59),
                      ),
                    ),
                    const SizedBox(height: 5),
                    if (rateNumbers <= 100)
                      Text(
                        TranslationHelper.get('no_ratings_yet'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9AA1AC),
                        ),
                      )
                    else
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 13),
                          const SizedBox(width: 4),
                          Text(
                            (rating / rateNumbers).toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2E3A59),
                            ),
                          ),
                        ],
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: Directionality(
        textDirection:
            widget.language == "ar" ? TextDirection.rtl : TextDirection.ltr,
        child: SafeArea(
          child: Column(
            children: [
              _buildSearchHeader(),
              if (alertCard != null) alertCard!,
              Expanded(child: _buildMainContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchHeader() {
    final bool isRtl = widget.language == "ar";
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
      ),
      child: Directionality(
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: Row(
          children: [
            if (widget.onBack == null) ...[
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap:
                    _isSearching ? _resetSearch : () => Navigator.pop(context),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Icon(
                    isRtl ? Icons.arrow_forward : Icons.arrow_back,
                    color: const Color(0xFF2E3A59),
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search,
                        color: Color(0xFF9AA1AC), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _handleSearch,
                        textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        textDirection:
                            isRtl ? TextDirection.rtl : TextDirection.ltr,
                        style: const TextStyle(
                            color: Color(0xFF2E3A59), fontSize: 14),
                        decoration: InputDecoration(
                          hintText: TranslationHelper.get('search_hint'),
                          hintStyle: const TextStyle(
                            color: Color(0xFF9AA1AC),
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                      ),
                    ),
                    if (_isSearching && _searchController.text.isNotEmpty)
                      GestureDetector(
                        onTap: _resetSearch,
                        child: const Icon(Icons.close,
                            size: 18, color: Color(0xFFB8BEC9)),
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

  Widget _buildMainContent() {
    if (_isSearching) {
      return _isLoading ? _buildResultsSkeleton() : _buildSearchResults();
    }
    return _buildInitialContent();
  }

  Widget _buildInitialContent() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (_recentSearches.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                TranslationHelper.get('recent_searches'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              GestureDetector(
                onTap: _clearAllRecentSearches,
                child: Text(
                  TranslationHelper.get('clear_all'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFFF9800),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _recentSearches
                .map((query) => _buildRecentSearchChip(query))
                .toList(),
          ),
          const SizedBox(height: 18),
        ],
        if (_searchAd != null) ...[
          SponsoredAdCard(
            ad: _searchAd!,
            language: widget.language,
            onTap: () => _handleAdTap(_searchAd!),
          ),
          const SizedBox(height: 18),
        ],
        Row(
          children: [
            const Icon(Icons.trending_up, color: Color(0xFFFF9800), size: 18),
            const SizedBox(width: 8),
            Text(
              TranslationHelper.get('trending_stores'),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_isLoading)
          _buildTrendingSkeleton()
        else
          Column(
            children: _trendingStores
                .map((store) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildTrendingThumbnailCard(store),
                    ))
                .toList(),
          ),
      ],
    );
  }

  Widget _buildRecentSearchChip(String query) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        _searchController.text = query;
        _handleSearch(query);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              query,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2E3A59),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _removeFromRecentSearches(query),
              child:
                  const Icon(Icons.close, size: 13, color: Color(0xFFB8BEC9)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFF3E0),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.search_off,
                    size: 34, color: Color(0xFFFF9800)),
              ),
              const SizedBox(height: 20),
              Text(
                TranslationHelper.get('no_results_found'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                TranslationHelper.get('no_results_hint'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Shown once results actually land, not while the results skeleton
        // is up - a search that turns out empty already falls through to
        // the "no results" branch above instead of reaching here at all.
        if (_searchAd != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SponsoredAdCard(
              ad: _searchAd!,
              language: widget.language,
              onTap: () => _handleAdTap(_searchAd!),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            gridDelegate: storeGridDelegate,
            itemCount: _searchResults.length,
            itemBuilder: (context, index) {
              final store = _searchResults[index];
              final String name =
                  store['name_${widget.language}'] ?? 'Sans nom';
              final String isOpen = store['status'] ?? "close";
              final String imageUrl =
                  store['image'] ?? 'https://via.placeholder.com/150';
              final int rateNumbers = store['rate_numbers'] ?? 0;
              final double rating =
                  (rateNumbers <= 100) ? 0 : (store['rate'] ?? 0).toDouble();
              final deliveryMinutes =
                  (store['estimated_delivery_time'] as num?)?.toInt();

              return StoreGridCard(
                name: name,
                isOpen: isOpen,
                imageUrl: imageUrl,
                rateNumbers: rateNumbers,
                rating: rating,
                deliveryMinutes: deliveryMinutes,
                onTap: () => _openStore(store),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultsSkeleton() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      gridDelegate: storeGridDelegate,
      itemCount: 6,
      itemBuilder: (context, index) => const StoreGridCardSkeleton(),
    );
  }

  /// Grey placeholder rows shaped like [_buildTrendingThumbnailCard], shown
  /// while the initial trending-stores fetch is in flight instead of a
  /// bare centered spinner - keeps the page looking like itself instead of
  /// going blank for a moment on first load.
  Widget _buildTrendingSkeleton() {
    Widget bar({double width = double.infinity, double height = 12}) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFEDEFF2),
            borderRadius: BorderRadius.circular(6),
          ),
        );

    Widget row() => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(18)),
                child: Container(
                  width: 110,
                  height: 88,
                  color: const Color(0xFFEDEFF2),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(width: 140, height: 14),
                      const SizedBox(height: 8),
                      bar(width: 90),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: row(),
          ),
      ],
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ConnectionDialog.show(context, language: widget.language, message: msg);
  }
}
