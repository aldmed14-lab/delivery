import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens the store-info bottom sheet: opening hours (from the `work_time`
/// subcollection), contact phone, and reviews (from `ratings`, newest
/// first).
Future<void> showStoreInfoSheet({
  required BuildContext context,
  required String language,
  required String storeId,
  required String phone,
  double rate = 0,
  int rateNumbers = 0,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _StoreInfoSheet(
      language: language,
      storeId: storeId,
      phone: phone,
      rate: rate,
      rateNumbers: rateNumbers,
    ),
  );
}

class _StoreInfoSheet extends StatelessWidget {
  final String language;
  final String storeId;
  final String phone;
  final double rate;
  final int rateNumbers;

  // A field, not a call inside build(): DraggableScrollableSheet's
  // `builder` re-invokes on every frame while the sheet is being dragged,
  // so calling _loadReviews() straight from build() would re-issue all
  // those Firestore reads (and flash the list back to loading) on every
  // drag frame instead of once.
  late final Future<List<MapEntry<String, Map<String, dynamic>>>>
      _reviewsFuture = _loadReviews();

  // Same reasoning as _reviewsFuture - cached so drag-triggered rebuilds
  // don't re-fetch work_time on every frame.
  late final Future<QuerySnapshot<Map<String, dynamic>>> _workTimeFuture =
      FirebaseFirestore.instance
          .collection('stores')
          .doc(storeId)
          .collection('work_time')
          .orderBy('index')
          .get();

  _StoreInfoSheet({
    required this.language,
    required this.storeId,
    required this.phone,
    required this.rate,
    required this.rateNumbers,
  });

  bool get _isArabic => language == 'ar';

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          color: Colors.black.withValues(alpha: 0.4),
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            maxChildSize: 0.92,
            minChildSize: 0.4,
            builder: (context, scrollController) => GestureDetector(
              onTap: () {},
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3E5E9),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Align(
                        alignment: _isArabic
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Text(
                          TranslationHelper.get('store_info_title'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF2E3A59),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        children: [
                          _buildSectionLabel(
                              TranslationHelper.get('opening_hours')),
                          _buildWorkTimeSection(),
                          const SizedBox(height: 20),
                          _buildSectionLabel(
                              TranslationHelper.get('contact_label')),
                          _buildContactRow(),
                          const SizedBox(height: 20),
                          _buildReviewsHeader(),
                          const SizedBox(height: 8),
                          _buildReviewsSection(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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

  String _dayLabel(String day) =>
      TranslationHelper.get('day_${day.toLowerCase()}');

  Widget _buildWorkTimeSection() {
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: _workTimeFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CircularProgressIndicator(color: Color(0xFFFF9800)),
            ),
          );
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return Text(
            TranslationHelper.get('no_description'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
          );
        }
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF6F7F9),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              for (int i = 0; i < docs.length; i++)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Builder(builder: (context) {
                        final d = docs[i].data();
                        final startDay = d['start_day'] as String? ?? '';
                        final endDay = d['end_day'] as String? ?? '';
                        final label = (endDay.isNotEmpty && endDay != startDay)
                            ? '${_dayLabel(startDay)} - ${_dayLabel(endDay)}'
                            : _dayLabel(startDay);
                        return Text(
                          label,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF2E3A59),
                          ),
                        );
                      }),
                      Builder(builder: (context) {
                        final d = docs[i].data();
                        return Text(
                          '${d['start_time'] ?? ''} - ${d['end_time'] ?? ''}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF9AA1AC),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContactRow() {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: phone.isEmpty
          ? null
          : () => launchUrl(Uri(scheme: 'tel', path: phone)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F7F9),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  const Icon(Icons.phone, color: Color(0xFFFF9800), size: 18),
            ),
            const SizedBox(width: 12),
            Text(
              phone.isEmpty ? '—' : phone,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2E3A59),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewsHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          TranslationHelper.get('reviews_label'),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: Color(0xFF9AA1AC),
            letterSpacing: 0.5,
          ),
        ),
        if (rateNumbers > 0)
          Row(
            children: [
              const Icon(Icons.star, color: Color(0xFFF5A623), size: 15),
              const SizedBox(width: 4),
              Text(
                (rate / rateNumbers).toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// `ratings/{id}` (`lib/map.txt`) - `id` is now a random Firestore id, not
  /// the reviewer's uid (one user can leave a fresh review per order rather
  /// than a single review overwritten each time), so the reviewer is
  /// resolved from the doc's own `user_id` field instead of its id; their
  /// display name still lives on `users/{user_id}.name` rather than being
  /// duplicated onto the rating doc.
  Future<List<MapEntry<String, Map<String, dynamic>>>> _loadReviews() async {
    final ratingsSnap = await FirebaseFirestore.instance
        .collection('stores')
        .doc(storeId)
        .collection('ratings')
        .orderBy('created_at', descending: true)
        .limit(5)
        .get();

    final names = await Future.wait(ratingsSnap.docs.map((doc) async {
      final userId = doc.data()['user_id'] as String? ?? '';
      if (userId.isEmpty) return '';
      final userSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      return userSnap.data()?['name'] as String? ?? '';
    }));

    return [
      for (var i = 0; i < ratingsSnap.docs.length; i++)
        MapEntry(names[i], ratingsSnap.docs[i].data()),
    ];
  }

  Widget _buildReviewsSection() {
    return FutureBuilder<List<MapEntry<String, Map<String, dynamic>>>>(
      future: _reviewsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text(
            TranslationHelper.get('error'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CircularProgressIndicator(color: Color(0xFFFF9800)),
            ),
          );
        }
        final reviews = snapshot.data!;
        if (reviews.isEmpty) {
          return Text(
            TranslationHelper.get('no_reviews_yet'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
          );
        }
        return Column(
          children: [
            for (int i = 0; i < reviews.length; i++) ...[
              _buildReviewRow(reviews[i].key, reviews[i].value),
              if (i < reviews.length - 1)
                const Divider(height: 20, color: Color(0xFFEDEFF2)),
            ],
          ],
        );
      },
    );
  }

  Widget _buildReviewRow(String name, Map<String, dynamic> data) {
    final rating = (data['rating'] as num?)?.toInt() ?? 0;
    final comment = data['comment'] as String? ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            Row(
              children: List.generate(
                5,
                (i) => Icon(
                  i < rating ? Icons.star : Icons.star_border,
                  color: const Color(0xFFF5A623),
                  size: 13,
                ),
              ),
            ),
          ],
        ),
        if (comment.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            comment,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
          ),
        ],
      ],
    );
  }
}
