import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// The signed-in user's own reports (`reports` where `reporter == uid`,
/// `lib/map.txt`) - reached from account_page.dart. Each row needs a name
/// and a status the user actually recognizes, so this reuses the exact
/// same `help_report_type_$type`/`help_report_status_$status` labels
/// help_page.dart's own "you already have an open report" card already
/// shows, rather than a second, possibly-inconsistent set of labels.
class ReportsPage extends StatefulWidget {
  final String language;
  const ReportsPage(this.language, {super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  late final Future<QuerySnapshot<Map<String, dynamic>>> _reportsFuture =
      _firestore
          .collection('reports')
          .where('reporter', isEqualTo: _uid)
          .orderBy('created_at', descending: true)
          .get();

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return const Color(0xFF1B8A3E);
      case 'processing':
        return const Color(0xFF2F80ED);
      default:
        return const Color(0xFFB8860B);
    }
  }

  Color _statusBg(String status) {
    switch (status) {
      case 'completed':
        return const Color(0xFFE6F7EA);
      case 'processing':
        return const Color(0xFFE3F0FF);
      default:
        return const Color(0xFFFFF3E0);
    }
  }

  String _dateLabel(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final month = TranslationHelper.get('month_${d.month}').toLowerCase();
    return '${d.day} $month ${d.year}';
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
              Expanded(
                child: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  future: _reportsFuture,
                  builder: (context, snapshot) => _buildBody(snapshot),
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
            TranslationHelper.get('reports_page_title'),
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

  Widget _buildBody(
      AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Text(
          TranslationHelper.get(
              isConnectivityError(snapshot.error!) ? 'no_internet' : 'error'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }
    final docs = snapshot.data?.docs ?? [];
    if (docs.isEmpty) {
      return Center(
        child: Text(
          TranslationHelper.get('no_reports_yet'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: docs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _reportRow(docs[i].data()),
    );
  }

  Widget _reportRow(Map<String, dynamic> data) {
    final type = data['report_type'] as String? ?? '';
    final status = data['status'] as String? ?? 'pending';
    final message = data['messages'] as String? ?? '';
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _showDetail(data),
      child: Container(
        padding: const EdgeInsets.all(14),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    TranslationHelper.get('help_report_type_$type'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusBg(status),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    TranslationHelper.get('help_report_status_$status'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: _statusColor(status),
                    ),
                  ),
                ),
              ],
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xFF677489)),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              _dateLabel(data['created_at'] as Timestamp?),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(Map<String, dynamic> data) {
    final type = data['report_type'] as String? ?? '';
    final status = data['status'] as String? ?? 'pending';
    final message = data['messages'] as String? ?? '';
    final action = data['action'] as String? ?? 'none';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                TranslationHelper.get('help_report_type_$type'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                TranslationHelper.get('help_report_status_$status'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _statusColor(status),
                ),
              ),
              const SizedBox(height: 14),
              if (message.isNotEmpty)
                Text(message,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFF2E3A59))),
              if (action == 'blocking' || action == 'deduction') ...[
                const SizedBox(height: 14),
                Text(
                  TranslationHelper.get('help_report_action_$action'),
                  style:
                      const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
