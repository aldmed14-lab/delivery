import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// The client's wallet/order transaction history, from the top-level
/// `users_transactions` collection (`lib/map.txt`) filtered to this user -
/// order payments, refunds, deductions, withdrawals.
class TransactionsPage extends StatefulWidget {
  final String language;
  const TransactionsPage(this.language, {super.key});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  static const _pageSize = 20;
  static const _maxTransactions = 50;

  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _isArabic => widget.language == 'ar';

  Query<Map<String, dynamic>> get _baseQuery => _firestore
      .collection('users_transactions')
      .where('user_id', isEqualTo: _uid)
      .orderBy('created_at', descending: true);

  final _scrollController = ScrollController();
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _transactions = [];
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _isLoadingInitial = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _loadInitial();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isLoadingMore || !_hasMore) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    try {
      final snap = await _baseQuery.limit(_pageSize).get();
      if (!mounted) return;
      setState(() {
        _transactions.addAll(snap.docs);
        _lastDoc = snap.docs.isEmpty ? null : snap.docs.last;
        _hasMore = snap.docs.length == _pageSize;
        _isLoadingInitial = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoadingInitial = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_lastDoc == null || !_hasMore || _isLoadingMore) return;
    // Never fetches past _maxTransactions total - the last page is
    // shrunk to land exactly on the cap instead of overshooting it.
    final remaining = _maxTransactions - _transactions.length;
    if (remaining <= 0) {
      setState(() => _hasMore = false);
      return;
    }
    final take = remaining < _pageSize ? remaining : _pageSize;

    setState(() => _isLoadingMore = true);
    try {
      final snap =
          await _baseQuery.startAfterDocument(_lastDoc!).limit(take).get();
      if (!mounted) return;
      setState(() {
        _transactions.addAll(snap.docs);
        if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
        _hasMore = snap.docs.length == take && _transactions.length < _maxTransactions;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
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
              _buildBalanceCard(),
              Expanded(child: _buildBody()),
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
              TranslationHelper.get('transactions_title'),
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

  Widget _buildBalanceCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _firestore.collection('users').doc(_uid).snapshots(),
        builder: (context, snapshot) {
          final credit = (snapshot.data?.data()?['wallet_balance'] as num?) ?? 0;
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF9800).withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      TranslationHelper.get('current_balance_label'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${credit.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoadingInitial) return _buildLoadingSkeleton();

    if (_loadError != null) {
      return Center(
        child: Text(
          TranslationHelper.get(
              isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
          style: const TextStyle(color: Color(0xFF9AA1AC)),
        ),
      );
    }

    if (_transactions.isEmpty) return _buildEmptyState();

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _transactions.length + (_isLoadingMore ? 1 : 0),
      separatorBuilder: (_, i) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == _transactions.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF9800)),
              ),
            ),
          );
        }
        return _buildTransactionRow(_transactions[index]);
      },
    );
  }

  Widget _buildLoadingSkeleton() {
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFEDEFF2),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(width: 120, height: 13),
                    const SizedBox(height: 8),
                    bar(width: 80, height: 11),
                  ],
                ),
              ),
              bar(width: 60, height: 16),
            ],
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (var i = 0; i < 5; i++)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: row()),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 130,
              height: 130,
              decoration: const BoxDecoration(
                color: Color(0xFFFFEFD9),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.account_balance_wallet_outlined,
                size: 56,
                color: Color(0xFFFF9800),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              TranslationHelper.get('no_transactions'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2E3A59),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              TranslationHelper.get('no_transactions_subtitle'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionRow(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final type = data['type'] as String? ?? 'order_payment';
    final status = data['status'] as String? ?? 'completed';
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    final createdAt = (data['created_at'] as Timestamp?)?.toDate();

    final isCredit = type == 'refund';
    final icon = switch (type) {
      'refund' => Icons.replay_rounded,
      'withdraw' => Icons.arrow_upward_rounded,
      'deduction' => Icons.remove_circle_outline_rounded,
      _ => Icons.shopping_bag_outlined,
    };
    final iconColor = isCredit ? const Color(0xFF1B8A3E) : const Color(0xFFFF9800);
    final iconBg = isCredit ? const Color(0xFFE6F7EA) : const Color(0xFFFFF3E0);

    final isPending = status == 'pending';
    final isFailed = status == 'failed' || status == 'expired';
    final statusColor = isFailed
        ? const Color(0xFFE74C3C)
        : (isPending ? const Color(0xFFB8860B) : const Color(0xFF1B8A3E));
    final statusBg = isFailed
        ? const Color(0xFFFDF1F0)
        : (isPending ? const Color(0xFFFFF3E0) : const Color(0xFFE6F7EA));

    return Container(
      padding: const EdgeInsets.all(12),
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
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TranslationHelper.get('transaction_type_$type'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _dateLabel(createdAt),
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isCredit ? '+' : '-'}${amount.toStringAsFixed(0)} ${TranslationHelper.get('currency_unit')}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: isCredit ? const Color(0xFF1B8A3E) : const Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration:
                    BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  TranslationHelper.get('transaction_status_$status'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _dateLabel(DateTime? date) {
    if (date == null) return '';
    final month = TranslationHelper.get('month_${date.month}').toLowerCase();
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day} $month ${date.year}, $hour:$minute';
  }
}
