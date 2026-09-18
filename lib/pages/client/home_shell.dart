import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/app_bottom_nav.dart';
import 'package:flutter_application_1/pages/client/cart_list_page.dart';
import 'package:flutter_application_1/pages/client/home_page.dart';
import 'package:flutter_application_1/pages/client/orders_list_page.dart';
import 'package:flutter_application_1/pages/client/profile_page.dart';
import 'package:flutter_application_1/pages/client/search_page.dart';
import 'package:flutter_application_1/utils/ad_service.dart';
import 'package:flutter_application_1/utils/delivery_offer_service.dart';

/// Hosts the 5 client tabs (Home / Search / Cart / Orders / Profile) behind
/// one shared [AppBottomNav] so switching tabs never pushes a new route -
/// only [HomePage] used to own the bottom nav, which meant it vanished the
/// moment you navigated away from Home. Tabs are built lazily on first
/// visit and then kept alive in an [IndexedStack].
class HomeShell extends StatefulWidget {
  final String language;
  const HomeShell(this.language, {super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = AppBottomNav.homeIndex;
  late final List<Widget?> _tabs;
  late final String _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    _tabs = List<Widget?>.filled(5, null);
    _tabs[AppBottomNav.homeIndex] = HomePage(
      widget.language,
      onNavigateTab: _goToTab,
    );

    // Owned here, not by HomePage - HomePage's own dispose only fires when
    // this whole shell is torn down (its State stays alive in the
    // IndexedStack below across every tab switch), but starting these
    // timers from a page rather than the shell they all sit inside made it
    // easy to assume they'd behave the same either way. Starting them here
    // instead ties their lifetime directly to the session (this shell),
    // not to any one tab's own init timing.
    AdService.instance.startAutoFlush();
    AdService.instance.startAutoRefresh();
    _startDeliveryOfferListenerIfDriver();
  }

  /// Only a "delivery" account ever has a matching delivery/{uid} doc at
  /// all, and only while `is_online` is already true there does this
  /// actually start listening - DeliveryHomePage's own online/offline
  /// toggle is what keeps the listener's lifetime in sync with `is_online`
  /// for the rest of the session (this call only covers app launch).
  Future<void> _startDeliveryOfferListenerIfDriver() async {
    if (_uid.isEmpty) return;
    try {
      final userSnap =
          await FirebaseFirestore.instance.collection('users').doc(_uid).get();
      if (userSnap.data()?['role'] == 'delivery') {
        await DeliveryOfferService.instance.startIfOnline(_uid);
      }
    } catch (_) {
      // Silently skip - same reasoning as startIfOnline's own catch: a
      // transient failure here just delays offers until the driver next
      // toggles online themselves.
    }
  }

  @override
  void dispose() {
    AdService.instance.flush();
    AdService.instance.stopAutoFlush();
    AdService.instance.stopAutoRefresh();
    DeliveryOfferService.instance.stop();
    super.dispose();
  }

  Widget _buildTab(int index) {
    final cached = _tabs[index];
    if (cached != null) return cached;

    late final Widget page;
    switch (index) {
      case AppBottomNav.homeIndex:
        page = HomePage(widget.language, onNavigateTab: _goToTab);
        break;
      case AppBottomNav.searchIndex:
        page = SearchPage(
          widget.language,
          onBack: () => _goToTab(AppBottomNav.homeIndex),
        );
        break;
      case AppBottomNav.cartIndex:
        page = CartListPage(
          widget.language,
          _uid,
          onBack: () => _goToTab(AppBottomNav.homeIndex),
        );
        break;
      case AppBottomNav.ordersIndex:
        page = OrdersListPage(widget.language);
        break;
      case AppBottomNav.profileIndex:
      default:
        page = ProfilePage(widget.language);
        break;
    }
    _tabs[index] = page;
    return page;
  }

  void _goToTab(int index) {
    setState(() {
      _buildTab(index);
      _index = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.language == 'ar';
    // Make sure the active tab (and Home, always) is built before laying
    // out the IndexedStack.
    _buildTab(_index);

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: List.generate(
            5,
            (i) => _tabs[i] ?? const SizedBox.shrink(),
          ),
        ),
        bottomNavigationBar: AppBottomNav(
          currentIndex: _index,
          onTap: _goToTab,
          isArabic: isArabic,
        ),
      ),
    );
  }
}
