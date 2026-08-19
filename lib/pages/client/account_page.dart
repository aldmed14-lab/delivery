import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/shared/support_page.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/user_profile_cache.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

class AccountPage extends StatefulWidget {
  final String language;
  const AccountPage(this.language, {super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> with AlertCardMixin {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  String uid = '';
  String phone = '';
  bool isLoading = true;
  bool isSaving = false;

  bool get _isArabic => widget.language == 'ar';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => isLoading = false);
      return;
    }
    uid = user.uid;

    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = doc.data();
      _nameController.text = data?['name'] ?? '';
      _emailController.text = data?['email'] ?? '';
      phone = data?['phone'] ?? '';
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _save() async {
    if (isSaving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showAlert(TranslationHelper.get('full_name_required'), isError: true);
      return;
    }

    setState(() => isSaving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {
          'name': name,
          'email': _emailController.text.trim(),
        },
        SetOptions(merge: true),
      );
      UserProfileCache.instance.update(
        name: name,
        phone: UserProfileCache.instance.phone,
        role: UserProfileCache.instance.role,
      );
      if (!mounted) return;
      showAlert(TranslationHelper.get('profile_updated'));
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  String get _initials {
    final name = _nameController.text.trim();
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
          child: isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFF9800)),
                )
              : Column(
                  children: [
                    _buildTopBar(),
                    if (alertCard != null) alertCard!,
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                        children: [
                          _buildAvatarBlock(),
                          const SizedBox(height: 24),
                          _buildSectionLabel(
                              TranslationHelper.get('personal_information')),
                          _buildInfoCard(),
                          const SizedBox(height: 20),
                          _buildDeleteAccountRow(),
                        ],
                      ),
                    ),
                    _buildSaveBar(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F1F4),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                _isArabic ? Icons.arrow_forward : Icons.arrow_back,
                color: const Color(0xFF2E3A59),
                size: 16,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              TranslationHelper.get('account'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
          Text(
            phone,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF9AA1AC),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarBlock() {
    return Column(
      children: [
        Stack(
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _initials,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child:
                    const Icon(Icons.edit, color: Color(0xFFFF9800), size: 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _nameController.text.isEmpty ? '—' : _nameController.text,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: Color(0xFF2E3A59),
          ),
        ),
      ],
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

  Widget _buildInfoCard() {
    return Container(
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
      child: Column(
        children: [
          _buildEditableField(
            label: TranslationHelper.get('full_name'),
            controller: _nameController,
            onChanged: (_) => setState(() {}),
          ),
          const Divider(height: 1, color: Color(0xFFF2F2F2)),
          _buildEditableField(
            label: TranslationHelper.get('email'),
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
          ),
        ],
      ),
    );
  }

  Widget _buildEditableField({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9AA1AC)),
          ),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            onChanged: onChanged,
            textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF2E3A59),
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeleteAccountRow() {
    return Container(
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
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _showDeleteAccountDialog,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFFDF1F0),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.delete_outline,
                    color: Color(0xFFE74C3C), size: 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  TranslationHelper.get('delete_account'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE74C3C),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Actually deleting an account means cascading through orders, wallet
  /// balance, carts, transactions, etc. - none of which this app has a
  /// safe path for yet. Rather than silently no-op or (worse) delete just
  /// the auth user and orphan the Firestore data, this hands off to
  /// support instead of performing the deletion itself.
  void _showDeleteAccountDialog() {
    showDialog(
      context: context,
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            TranslationHelper.get('delete_account_title'),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          content: Text(
            TranslationHelper.get('delete_account_message'),
            style: const TextStyle(fontSize: 14, color: Color(0xFF677489)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(TranslationHelper.get('cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE74C3C),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SupportPage(widget.language),
                  ),
                );
              },
              child: Text(TranslationHelper.get('contact_support')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF9800),
            disabledBackgroundColor: const Color(0xFFFFCC80),
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: isSaving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                )
              : Text(
                  TranslationHelper.get('save'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    );
  }

}
