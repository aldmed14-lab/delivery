import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

/// Store finance ledger - current balance (stores/{storeId}.earnings, kept
/// in sync with the ledger by whatever writes client_transactions docs, the
/// same way users/{uid}.wallet_balance tracks users_transactions) plus a
/// filterable list of that store's transactions (order_payment / withdraw /
/// deduction / refund), and a request-a-withdraw dialog. The withdrawal
/// itself goes through the `requestStoreWithdraw` Cloud Function rather than
/// a raw client write - it re-checks the store is started and the amount
/// against its real earnings server-side, debits earnings, and records a
/// "pending" client_transactions doc for staff to actually process.
class StoreFinancePage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreFinancePage(this.language, this.storeId, {super.key});

  @override
  State<StoreFinancePage> createState() => _StoreFinancePageState();
}

class _StoreFinancePageState extends State<StoreFinancePage>
    with AlertCardMixin {
  // Mirrors MIN_WITHDRAW_AMOUNT in requestStoreWithdraw.js - checked here
  // too so the dialog can reject it immediately instead of round-tripping
  // to the server first for something this cheap to catch locally.
  static const _minWithdrawAmount = 1000;

  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;
  double _balance = 0;
  List<Map<String, dynamic>> _transactions = [];
  String? _filterType;
  bool _storeStarted = true;

  // Whether each of the two independent data sources has delivered its
  // first value yet - _isLoading only clears once both have, even though
  // the store doc keeps updating live afterward.
  bool _storeLoaded = false;
  bool _transactionsLoaded = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _storeSub;

  @override
  void initState() {
    super.initState();
    _listenStore();
    _loadTransactions();
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    disposeAlert();
    super.dispose();
  }

  /// The balance shown here has to stay live - a withdrawal being approved,
  /// or a new order_payment landing, changes stores/{id}.earnings from
  /// outside this page entirely, so a one-time fetch would go stale the
  /// moment either happens while the owner is looking at it.
  void _listenStore() {
    _storeSub?.cancel();
    _storeSub = _firestore
        .collection('stores')
        .doc(widget.storeId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final store = snap.data() ?? {};
      setState(() {
        _balance = (store['earnings'] as num?)?.toDouble() ?? 0.0;
        _storeStarted = store['start'] != false;
        _storeLoaded = true;
        _isLoading = !(_storeLoaded && _transactionsLoaded);
      });
    }, onError: (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoading = false;
      });
    });
  }

  Future<void> _loadTransactions() async {
    try {
      final snap = await _firestore
          .collection('client_transactions')
          .where('transactioner_type', isEqualTo: 'store')
          .where('transactioner_id', isEqualTo: widget.storeId)
          .orderBy('created_at', descending: true)
          .limit(50)
          .get();

      if (!mounted) return;
      setState(() {
        _transactions = snap.docs.map((d) => d.data()).toList();
        _transactionsLoaded = true;
        _isLoading = !(_storeLoaded && _transactionsLoaded);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoading = false;
      });
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'order_payment':
        return TranslationHelper.get('finance_type_order_payment');
      case 'withdraw':
        return TranslationHelper.get('finance_type_withdraw');
      case 'deduction':
        return TranslationHelper.get('finance_type_deduction');
      case 'refund':
        return TranslationHelper.get('finance_type_refund');
      default:
        return type;
    }
  }

  bool _isCredit(String type) => type == 'order_payment' || type == 'refund';

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return const Color(0xFF1B8A3E);
      case 'pending':
        return const Color(0xFFB8860B);
      default:
        return const Color(0xFFE74C3C);
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'completed':
        return TranslationHelper.get('finance_status_completed');
      case 'pending':
        return TranslationHelper.get('finance_status_pending');
      default:
        return TranslationHelper.get('finance_status_failed');
    }
  }

  static const _frMonths = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];
  static const _arMonths = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];

  String _formatDate(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate().toLocal();
    final months = _isArabic ? _arMonths : _frMonths;
    final month = months[d.month - 1];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day.toString().padLeft(2, '0')} $month ${d.year}, $hh:$mm';
  }

  String _formatAmount(num value) {
    if (value >= 1000) {
      final k = value / 1000;
      return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
    }
    return value.toStringAsFixed(0);
  }

  Future<void> _showWithdrawDialog() async {
    if (!_storeStarted) {
      showAlert(TranslationHelper.get('store_inactive_action_blocked'),
          isError: true);
      return;
    }
    final controller = TextEditingController();
    final currency = TranslationHelper.get('currency_unit');
    String? errorText;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Dialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    TranslationHelper.get('finance_withdraw_dialog_title'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    TranslationHelper.get(
                        'finance_withdraw_available_balance', {
                      'amount': _balance.toStringAsFixed(0),
                      'currency': currency
                    }),
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF9AA1AC)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText:
                          TranslationHelper.get('finance_withdraw_amount_hint'),
                      errorText: errorText,
                      suffixText: currency,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context, false),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            side: const BorderSide(color: Color(0xFFE1E4E9)),
                          ),
                          child: Text(
                            TranslationHelper.get('cancel'),
                            style: const TextStyle(
                              color: Color(0xFF2E3A59),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            final amount = double.tryParse(
                                controller.text.trim().replaceAll(',', '.'));
                            if (amount == null || amount <= 0) {
                              setDialogState(() => errorText =
                                  TranslationHelper.get('invalid_amount'));
                              return;
                            }
                            if (amount < _minWithdrawAmount) {
                              setDialogState(() => errorText =
                                  TranslationHelper.get(
                                      'finance_withdraw_below_minimum',
                                      {'min': _minWithdrawAmount}));
                              return;
                            }
                            if (amount > _balance) {
                              setDialogState(() => errorText =
                                  TranslationHelper.get(
                                      'finance_withdraw_amount_exceeds_balance'));
                              return;
                            }
                            Navigator.pop(context, true);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF9800),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            TranslationHelper.get('confirm_button'),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    final amount = double.tryParse(controller.text.trim().replaceAll(',', '.'));
    if (amount == null) return;

    try {
      await FirebaseFunctions.instance
          .httpsCallable('requestStoreWithdraw')
          .call({
        'store_id': widget.storeId,
        'amount': amount,
      });
      if (mounted) {
        showAlert(TranslationHelper.get('finance_withdraw_request_sent'));
        // The balance itself updates via the live store listener already -
        // only the transaction list (the new pending row) needs a refetch.
        await _loadTransactions();
      }
    } catch (e) {
      if (mounted) {
        // The dialog's own check above already catches this locally, but the
        // server re-checks it too (never trust a client-only guard) - same
        // {min} substitution, just reached over a slower path.
        if (e is FirebaseFunctionsException &&
            (e.details is Map ? e.details['code'] : null) ==
                'withdraw_below_minimum') {
          showAlert(
            TranslationHelper.get(
                'finance_withdraw_below_minimum', {'min': _minWithdrawAmount}),
            isError: true,
          );
        } else {
          showAlert(TranslationHelper.get(_withdrawErrorKey(e)), isError: true);
        }
      }
    }
  }

  /// requestStoreWithdraw re-checks the store/earnings server-side (never
  /// trust the client's cached balance/start flag) - these two codes surface
  /// as specific, already-existing messages instead of the generic fallback.
  String _withdrawErrorKey(Object e) {
    if (e is FirebaseFunctionsException) {
      switch (e.details is Map ? e.details['code'] : null) {
        case 'store_not_started':
          return 'store_inactive_action_blocked';
        case 'insufficient_earnings':
          return 'finance_withdraw_amount_exceeds_balance';
      }
    }
    return isConnectivityError(e) ? 'no_internet' : 'error';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: Column(
          children: [
            _buildHeader(),
            if (alertCard != null) alertCard!,
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadError != null
                      ? _buildErrorState()
                      : _buildBody(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              TranslationHelper.get(
                  isConnectivityError(_loadError!) ? 'no_internet' : 'error'),
              style: const TextStyle(color: Color(0xFF9AA1AC)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _loadError = null;
                  _storeLoaded = false;
                  _transactionsLoaded = false;
                });
                _listenStore();
                _loadTransactions();
              },
              child: Text(TranslationHelper.get('retry')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.of(context).padding.top + 12, 16, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Row(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(19),
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.22),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isArabic
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.arrow_back_ios_new_rounded,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              TranslationHelper.get('finance_page_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final filtered = _filterType == null
        ? _transactions
        : _transactions.where((t) => t['type'] == _filterType).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildBalanceCard(),
        const SizedBox(height: 20),
        _buildFilterTabs(),
        const SizedBox(height: 18),
        Text(
          TranslationHelper.get('finance_transactions_section'),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF9AA1AC),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          _buildEmptyCard(TranslationHelper.get('finance_no_transactions'))
        else
          for (final t in filtered) ...[
            _buildTransactionCard(t),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildBalanceCard() {
    final currency = TranslationHelper.get('currency_unit');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            TranslationHelper.get('finance_balance_label'),
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF9AA1AC)),
          ),
          const SizedBox(height: 6),
          Text(
            '${_formatAmount(_balance)} $currency',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Color(0xFF2E3A59),
            ),
          ),
          const SizedBox(height: 16),
          Opacity(
            opacity: _storeStarted ? 1 : 0.5,
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _showWithdrawDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  TranslationHelper.get('finance_request_withdraw_button'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTabs() {
    final labels = <String?, String>{
      null: TranslationHelper.get('finance_filter_all'),
      'order_payment': TranslationHelper.get('finance_filter_payments'),
      'withdraw': TranslationHelper.get('finance_filter_withdrawals'),
      'deduction': TranslationHelper.get('finance_filter_deductions'),
      'refund': TranslationHelper.get('finance_filter_refunds'),
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: _isArabic,
      child: Row(
        children: [
          for (final type in labels.keys) ...[
            _buildFilterChip(type, labels[type]!),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip(String? type, String label) {
    final selected = _filterType == type;
    return GestureDetector(
      onTap: () => setState(() => _filterType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFF9800) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: selected
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : const Color(0xFF9AA1AC),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyCard(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
      ),
    );
  }

  Widget _buildTransactionCard(Map<String, dynamic> t) {
    final type = t['type'] as String? ?? '';
    final status = t['status'] as String? ?? 'completed';
    final amount = (t['amount'] as num?) ?? 0;
    final number = t['transaction_number'] as String? ?? '';
    final currency = TranslationHelper.get('currency_unit');
    final isCredit = _isCredit(type);
    final amountColor =
        isCredit ? const Color(0xFF1B8A3E) : const Color(0xFFE74C3C);
    final sign = isCredit ? '+' : '-';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
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
                  '#$number — ${_typeLabel(type)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2E3A59),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor(status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _statusLabel(status),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: _statusColor(status),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _formatDate(t['created_at'] as Timestamp?),
                  style:
                      const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
                ),
              ),
              Text(
                '$sign${_formatAmount(amount)} $currency',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: amountColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
