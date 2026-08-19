import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// The bottom nav bar shared by all 5 client tabs (Home / Search / Cart /
/// Orders / Profile), matching the "Home Page" design. Lives in [HomeShell]
/// so switching tabs doesn't push a new route - only the active tab's
/// content and highlight change.
class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool isArabic;

  const AppBottomNav({
    required this.currentIndex,
    required this.onTap,
    required this.isArabic,
    super.key,
  });

  static const int homeIndex = 0;
  static const int searchIndex = 1;
  static const int cartIndex = 2;
  static const int ordersIndex = 3;
  static const int profileIndex = 4;

  @override
  Widget build(BuildContext context) {
    // The cart button floats above the bar's top edge. That used to be a
    // Container with a negative top margin, which crashes at runtime
    // (Container asserts `margin.isNonNegative` - `flutter analyze`
    // doesn't execute the widget tree, so it never caught this). A Stack
    // with the button in a Positioned child achieves the same look without
    // giving any Container a negative margin.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Row(
            textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.home_rounded,
                label: TranslationHelper.get('nav_home'),
                active: currentIndex == homeIndex,
                onTap: () => onTap(homeIndex),
              ),
              _NavItem(
                icon: Icons.search_rounded,
                label: TranslationHelper.get('nav_search'),
                active: currentIndex == searchIndex,
                onTap: () => onTap(searchIndex),
              ),
              // Reserves the cart button's horizontal slot in the row so
              // the other 4 items stay evenly spaced around it.
              const SizedBox(width: 52),
              _NavItem(
                icon: Icons.receipt_long_rounded,
                label: TranslationHelper.get('nav_current_orders'),
                active: currentIndex == ordersIndex,
                onTap: () => onTap(ordersIndex),
              ),
              _NavItem(
                icon: Icons.person_rounded,
                label: TranslationHelper.get('profile'),
                active: currentIndex == profileIndex,
                onTap: () => onTap(profileIndex),
              ),
            ],
          ),
        ),
        Positioned(
          top: -28,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: () => onTap(cartIndex),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9800),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF9800).withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(Icons.shopping_bag_rounded,
                    color: Colors.white, size: 22),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFFFF9800) : const Color(0xFF9AA1AC);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
