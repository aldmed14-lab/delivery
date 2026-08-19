import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Static FAQ list (no Firestore-backed schema for it exists in
/// `lib/map.txt` yet) - question/answer pairs come from translation keys
/// so the page stays bilingual like everything else in the app.
class FaqPage extends StatefulWidget {
  final String language;
  const FaqPage(this.language, {super.key});

  @override
  State<FaqPage> createState() => _FaqPageState();
}

class _FaqEntry {
  final String questionKey;
  final String answerKey;
  const _FaqEntry(this.questionKey, this.answerKey);
}

class _FaqPageState extends State<FaqPage> {
  static const _entries = [
    _FaqEntry('faq_q_order', 'faq_a_order'),
    _FaqEntry('faq_q_payment', 'faq_a_payment'),
    _FaqEntry('faq_q_delivery_time', 'faq_a_delivery_time'),
    _FaqEntry('faq_q_cancel', 'faq_a_cancel'),
    _FaqEntry('faq_q_refund', 'faq_a_refund'),
    _FaqEntry('faq_q_track', 'faq_a_track'),
    _FaqEntry('faq_q_wallet', 'faq_a_wallet'),
    _FaqEntry('faq_q_support', 'faq_a_support'),
  ];

  int? _expandedIndex;

  bool get _isArabic => widget.language == 'ar';

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
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _entries.length,
                  separatorBuilder: (_, i) => const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _buildEntry(index, _entries[index]),
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
          Expanded(
            child: Text(
              TranslationHelper.get('faq_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
          const SizedBox(width: 38),
        ],
      ),
    );
  }

  Widget _buildEntry(int index, _FaqEntry entry) {
    final isExpanded = _expandedIndex == index;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(
                () => _expandedIndex = isExpanded ? null : index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
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
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Color(0xFFFF9800),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState:
                isExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  TranslationHelper.get(entry.answerKey),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9AA1AC),
                    height: 1.5,
                  ),
                ),
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
