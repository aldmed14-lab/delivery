import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/pages/client/account_page.dart';
import 'package:flutter_application_1/pages/client/home_shell.dart';
import 'package:flutter_application_1/pages/client/order_history_list_page.dart';
import 'package:flutter_application_1/pages/client/reports_page.dart';
import 'package:flutter_application_1/pages/client/transactions_page.dart';
import 'package:flutter_application_1/pages/delivery/delivery_home_page.dart';
import 'package:flutter_application_1/pages/owner/owner_stores_page.dart';
import 'package:flutter_application_1/pages/shared/faq_page.dart';
import 'package:flutter_application_1/pages/shared/help_page.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/user_profile_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';

class ProfilePage extends StatefulWidget {
  final String language;

  const ProfilePage(this.language, {super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

/// No fetch, no loading state: name/phone come from [UserProfileCache],
/// which the home page already populates once on app start from the same
/// `users/{uid}` read it needs anyway - opening this tab is just reading
/// that cache, not another round-trip.
class _ProfilePageState extends State<ProfilePage> {
  final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool _isDialogShowing = false;

  bool get _isArabic => widget.language == "ar";

  String get _initials {
    final name = UserProfileCache.instance.name?.trim() ?? '';
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+'));
    final first = parts[0].isNotEmpty ? parts[0][0] : '';
    final second = parts.length > 1 && parts[1].isNotEmpty ? parts[1][0] : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F9),
        body: SafeArea(
          bottom: false,
          child: ListenableBuilder(
            listenable: UserProfileCache.instance,
            builder: (context, _) => Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            TranslationHelper.get('profile'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Text(
                    _initials,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      UserProfileCache.instance.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      UserProfileCache.instance.phone ?? '',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final role = UserProfileCache.instance.role;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        if (role == 'owner') ...[
          _buildSpaceButton(
            icon: Icons.storefront_outlined,
            label: TranslationHelper.get('store_space'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OwnerStoresPage(widget.language),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ] else if (role == 'delivery') ...[
          _buildSpaceButton(
            icon: Icons.two_wheeler_outlined,
            label: TranslationHelper.get('delivery_space'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeliveryHomePage(widget.language),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        _buildSectionLabel(TranslationHelper.get('account_section')),
        _buildGroupCard([
          _buildRow(
            icon: Icons.person_outline,
            label: TranslationHelper.get('account'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AccountPage(widget.language),
              ),
            ),
          ),
          _buildRow(
            icon: Icons.receipt_long_outlined,
            label: TranslationHelper.get('order_history'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OrderHistoryListPage(widget.language),
              ),
            ),
          ),
          _buildRow(
            icon: Icons.account_balance_wallet_outlined,
            label: TranslationHelper.get('transactions'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TransactionsPage(widget.language),
              ),
            ),
          ),
          _buildRow(
            icon: Icons.flag_outlined,
            label: TranslationHelper.get('my_reports'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReportsPage(widget.language)),
            ),
          ),
        ]),
        _buildSectionLabel(TranslationHelper.get('preferences_section')),
        _buildGroupCard([
          _buildRow(
            icon: Icons.language,
            label: TranslationHelper.get('language_label'),
            trailingText: TranslationHelper.get('current_language_name'),
            onTap: _openLanguageSheet,
          ),
          _buildRow(
            icon: Icons.help_outline,
            label: TranslationHelper.get('help'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => HelpPage(widget.language)),
            ),
          ),
          _buildRow(
            icon: Icons.quiz_outlined,
            label: TranslationHelper.get('faq'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => FaqPage(widget.language)),
            ),
          ),
        ]),
        _buildGroupCard([
          _buildRow(
            icon: Icons.logout_rounded,
            label: TranslationHelper.get('logout'),
            iconBg: const Color(0xFFFDF1F0),
            iconColor: const Color(0xFFE74C3C),
            labelColor: const Color(0xFFE74C3C),
            showChevron: false,
            onTap: _showLogoutConfirmationDialog,
          ),
        ]),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Talabaty v1.0.0',
            style: TextStyle(fontSize: 11, color: Color(0xFFB8BEC9)),
          ),
        ),
      ],
    );
  }

  /// The dark "Espace magasin"/"Espace livreur" shortcut shown above the
  /// regular menu when this account is also a store owner or delivery
  /// driver, not just a client.
  Widget _buildSpaceButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: const Color(0xFF2E3A59),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2E3A59).withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            Icon(
              _isArabic ? Icons.chevron_left : Icons.chevron_right,
              color: Colors.white.withValues(alpha: 0.7),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildGroupCard(List<Widget> rows) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
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
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i != rows.length - 1)
              const Divider(height: 1, color: Color(0xFFF2F2F2)),
          ],
        ],
      ),
    );
  }

  Widget _buildRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? trailingText,
    Color iconBg = const Color(0xFFFFF3E0),
    Color iconColor = const Color(0xFFFF9800),
    Color labelColor = const Color(0xFF2E3A59),
    bool showChevron = true,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: iconColor, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
              ),
            ),
            if (trailingText != null) ...[
              Text(
                trailingText,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF9AA1AC),
                ),
              ),
              const SizedBox(width: 4),
            ],
            if (showChevron)
              Icon(
                _isArabic ? Icons.chevron_left : Icons.chevron_right,
                color: const Color(0xFFC9CDD4),
                size: 18,
              ),
          ],
        ),
      ),
    );
  }

  void _showLogoutConfirmationDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (BuildContext context) {
        return Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDF1F0),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.logout_rounded,
                        color: Color(0xFFE74C3C), size: 28),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    TranslationHelper.get('confirm_logout'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    TranslationHelper.get('confirm_logout_message'),
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF677489),
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFE5E8ED)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(
                              TranslationHelper.get('cancel'),
                              style: const TextStyle(
                                color: Color(0xFF677489),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              _performLogout();
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE74C3C),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(
                              TranslationHelper.get('logout'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _performLogout() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFFF9800)),
              const SizedBox(height: 16),
              Text(
                TranslationHelper.get('logging_out'),
                style: const TextStyle(fontSize: 16, color: Color(0xFF677489)),
              ),
            ],
          ),
        ),
      ),
    );

    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted) return;
      Navigator.of(context).pop();
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .update({'fmc': "null"});
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => MainPage()),
          (Route<dynamic> route) => false,
        );
      } catch (e) {
        if (mounted) {
          _showSnack(TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'));
        }
      }
    });
  }

  /// Bottom sheet language picker. Only French/Arabic are offered - the
  /// app only actually ships translations for those two (the "fr.json"
  /// file is loaded for any non-"ar" code), so a third "English" option
  /// would silently behave like French instead of doing anything.
  void _openLanguageSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3E5E9),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment:
                      _isArabic ? Alignment.centerRight : Alignment.centerLeft,
                  child: Text(
                    TranslationHelper.get('choose_language'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                _buildLanguageRow('fr', 'Français'),
                const Divider(height: 1, color: Color(0xFFF2F2F2)),
                _buildLanguageRow('ar', 'العربية'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLanguageRow(String code, String label) {
    final selected = widget.language == code;
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        _switchLanguage(code);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            if (selected)
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Color(0xFFFF9800),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 14),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchLanguage(String languageCode) async {
    if (widget.language == languageCode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', languageCode);
    await TranslationHelper.loadTranslations(languageCode);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => HomeShell(languageCode)),
      (Route<dynamic> route) => false,
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted || _isDialogShowing) return;
    _isDialogShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            elevation: 10,
            child: Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isError ? Icons.error_outline : Icons.info_outline,
                    color: isError
                        ? const Color(0xFFFF3B30)
                        : const Color(0xFFFF9800),
                    size: 40,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    msg,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFF677489),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () {
                        _isDialogShowing = false;
                        Navigator.of(context).pop();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isError
                            ? const Color(0xFFFF3B30)
                            : const Color(0xFFFF9800),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('ok'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
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
