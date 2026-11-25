import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// One question/answer pair in the "common questions" section right under
/// the call card - unlike [_Topic] above, these are real, answered
/// questions, not a "coming soon" placeholder.
class _Faq {
  final String questionKey;
  final String answerKey;
  const _Faq(this.questionKey, this.answerKey);
}

const _storeFaq = [
  _Faq('support_faq_store_q_withdraw', 'support_faq_store_a_withdraw'),
  _Faq('support_faq_store_q_status', 'support_faq_store_a_status'),
  _Faq('support_faq_store_q_item_hidden', 'support_faq_store_a_item_hidden'),
  _Faq('support_faq_store_q_no_driver', 'support_faq_store_a_no_driver'),
];

const _deliveryFaq = [
  _Faq('support_faq_delivery_q_no_offers', 'support_faq_delivery_a_no_offers'),
  _Faq('support_faq_delivery_q_cash_deduction',
      'support_faq_delivery_a_cash_deduction'),
  _Faq('support_faq_delivery_q_withdraw', 'support_faq_delivery_a_withdraw'),
  _Faq('support_faq_delivery_q_missed_offer',
      'support_faq_delivery_a_missed_offer'),
];

/// Support page for store owners and delivery drivers - reached from
/// owner_store_detail_page.dart's/delivery_home_page.dart's/
/// delivery_order_detail_page.dart's own "Support" row, whose FAQ list
/// (SUJETS MAGASIN vs SUJETS LIVREUR renamed to real Q&A) depends on
/// [audience]. Also reached from account_page.dart's delete-account dialog
/// ("Contact support" instead of deleting) with no audience at all - that's
/// a plain customer, who gets the call/email cards but no store/delivery
/// FAQ section (there's nothing generic to put there instead of guessing at
/// fake customer questions).
///
/// The call button still doesn't go anywhere - no real support phone number
/// is configured anywhere in this app (same situation help_page.dart's own
/// doc comment already noted for the customer side) - so it shows an honest
/// "coming soon" rather than a fake number. The email row is real and does
/// open a mail client, since a business contact address is low-risk either
/// way, and the FAQ section right below the call card is fully answered,
/// not a placeholder.
class SupportPage extends StatefulWidget {
  final String language;

  /// 'owner', 'delivery', or null for a plain customer (no topics section).
  final String? audience;

  const SupportPage(this.language, {this.audience, super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> with AlertCardMixin {
  static const _supportEmail = 'pro@talabaty.mr';

  bool get _isArabic => widget.language == 'ar';
  bool get _isOwner => widget.audience == 'owner';
  bool get _isDelivery => widget.audience == 'delivery';

  int? _expandedFaqIndex;

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  Future<void> _emailSupport() async {
    final uri = Uri(scheme: 'mailto', path: _supportEmail);
    try {
      await launchUrl(uri);
    } catch (_) {
      if (mounted) showAlert(TranslationHelper.get('error'), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              if (alertCard != null) alertCard!,
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildCallCard(),
                    if (_isOwner || _isDelivery) ...[
                      const SizedBox(height: 22),
                      _buildSectionLabel('support_common_questions_label'),
                      const SizedBox(height: 8),
                      _buildFaqCard(_isOwner ? _storeFaq : _deliveryFaq),
                    ],
                    const SizedBox(height: 22),
                    _buildSectionLabel('support_other_label'),
                    const SizedBox(height: 8),
                    _buildEmailCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _isArabic
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: const Color(0xFF2E3A59),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            TranslationHelper.get('support_title'),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => showAlert(TranslationHelper.get('support_coming_soon')),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF27AE60), Color(0xFF1E8449)],
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF27AE60).withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.support_agent_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Text(
              TranslationHelper.get('support_call_button'),
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String key) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Text(
        TranslationHelper.get(key),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildFaqCard(List<_Faq> entries) {
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
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _buildFaqRow(i, entries[i]),
            if (i != entries.length - 1)
              const Divider(height: 1, color: Color(0xFFF2F2F2)),
          ],
        ],
      ),
    );
  }

  Widget _buildFaqRow(int index, _Faq entry) {
    final isExpanded = _expandedFaqIndex == index;
    return InkWell(
      onTap: () =>
          setState(() => _expandedFaqIndex = isExpanded ? null : index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    TranslationHelper.get(entry.questionKey),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      color: Color(0xFFFF9800)),
                ),
              ],
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: isExpanded
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              firstChild: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    TranslationHelper.get(entry.answerKey),
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF9AA1AC), height: 1.5),
                  ),
                ),
              ),
              secondChild: const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailCard() {
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
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _emailSupport,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.email_outlined,
                    size: 16, color: Color(0xFFFF9800)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _supportEmail,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2E3A59),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
