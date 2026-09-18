import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/pages/owner/store_orders_page.dart' show OrderCard;
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';

enum _HistoryFilter { all, delivered, cancelled }

/// Owner's order history - every ended order (`order_end == true`) for this
/// store, browsable and filterable, instead of only being reachable one at
/// a time via the live board's exact order_number search.
class StoreOrderHistoryPage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreOrderHistoryPage(this.language, this.storeId, {super.key});

  @override
  State<StoreOrderHistoryPage> createState() => _StoreOrderHistoryPageState();
}

class _StoreOrderHistoryPageState extends State<StoreOrderHistoryPage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _orders = [];
  _HistoryFilter _filter = _HistoryFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    disposeAlert();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final snap = await _firestore
          .collection('orders')
          .where('store_id', isEqualTo: widget.storeId)
          .where('order_end', isEqualTo: true)
          .orderBy('created_at', descending: true)
          .limit(50)
          .get();
      if (!mounted) return;
      setState(() {
        _orders = snap.docs;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoading = false;
      });
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _filtered {
    switch (_filter) {
      case _HistoryFilter.all:
        return _orders;
      case _HistoryFilter.delivered:
        return _orders
            .where((d) => d.data()['delivery_status'] == 'delivered')
            .toList();
      case _HistoryFilter.cancelled:
        return _orders
            .where((d) => d.data()['order_status'] == 'cancelled')
            .toList();
    }
  }

  // No status-changing action ever applies to an ended order - OrderCard
  // only renders its action buttons when order_end is false, so these are
  // never actually invoked; they just satisfy OrderCard's required callbacks.
  void _noop() {}

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
                });
                _load();
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
          16, MediaQuery.of(context).padding.top + 12, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF9800), Color(0xFFFB6D0A)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Row(
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
                  TranslationHelper.get('order_history_page_title'),
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
          const SizedBox(height: 14),
          _buildFilterChips(),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final f in _HistoryFilter.values) ...[
            _buildFilterChip(f),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip(_HistoryFilter f) {
    final selected = _filter == f;
    final label = TranslationHelper.get(switch (f) {
      _HistoryFilter.all => 'filter_all_label',
      _HistoryFilter.delivered => 'delivery_status_delivered',
      _HistoryFilter.cancelled => 'order_status_cancelled',
    });
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _filter = f),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? const Color(0xFFFF9800) : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final docs = _filtered;
    if (docs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history_rounded, size: 48, color: Color(0xFFC9CDD4)),
              const SizedBox(height: 12),
              Text(
                TranslationHelper.get('owner_no_order_history'),
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Color(0xFF677489)),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: docs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => OrderCard(
        language: widget.language,
        order: docs[i],
        onAccept: _noop,
        onRefuse: _noop,
        onStartPreparing: _noop,
        onMarkReady: _noop,
        onOpenChat: docs[i].data()['conversation_id'] != null
            ? () => showAlert(TranslationHelper.get('chat_coming_soon'))
            : null,
      ),
    );
  }
}
