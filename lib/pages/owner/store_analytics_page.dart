import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

enum _Period { d7, d30, y1 }

/// Store analytics dashboard - period-scoped stats grid (7 days / 30 days /
/// 1 year, computed locally from a single fetch of the last 30 daily and 12
/// monthly stores_analytics docs, so switching tabs never re-queries),
/// a 12-month completed-orders trend, a 7-day hourly trend (today vs the
/// week's average), and the store's reviews.
class StoreAnalyticsPage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreAnalyticsPage(this.language, this.storeId, {super.key});

  @override
  State<StoreAnalyticsPage> createState() => _StoreAnalyticsPageState();
}

class _StoreAnalyticsPageState extends State<StoreAnalyticsPage> {
  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  Object? _loadError;

  _Period _period = _Period.d7;

  // Both fetched newest-first (documentId order matches "YYYY-MM"/"YYYY-MM-DD").
  List<Map<String, dynamic>> _monthly = [];
  List<Map<String, dynamic>> _daily = [];
  double _rate = 0;
  int _rateNumbers = 0;
  List<Map<String, dynamic>> _reviews = [];
  Map<String, String> _userNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final analyticsRef =
          _firestore.collection('stores_analytics').doc(widget.storeId);
      final results = await Future.wait([
        _firestore.collection('stores').doc(widget.storeId).get(),
        // 24 months / 60 days, not 12/30 - the extra half funds the
        // previous-period comparison (delta badges) without a second query.
        analyticsRef
            .collection('monthly')
            .orderBy(FieldPath.documentId, descending: true)
            .limit(24)
            .get(),
        analyticsRef
            .collection('daily')
            .orderBy(FieldPath.documentId, descending: true)
            .limit(60)
            .get(),
        _firestore
            .collection('stores')
            .doc(widget.storeId)
            .collection('ratings')
            .orderBy('created_at', descending: true)
            .limit(10)
            .get(),
      ]);

      final storeSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
      final monthlySnap = results[1] as QuerySnapshot<Map<String, dynamic>>;
      final dailySnap = results[2] as QuerySnapshot<Map<String, dynamic>>;
      final ratingsSnap = results[3] as QuerySnapshot<Map<String, dynamic>>;

      final store = storeSnap.data() ?? {};
      final rateSum = (store['rate'] as num?)?.toDouble() ?? 0;
      final rateNumbers = (store['rate_numbers'] as num?)?.toInt() ?? 0;

      // Rating docs already carry the reviewer's name directly (doc id is
      // the user id, but there's no separate user_id field to join on) -
      // only fall back to a users/ lookup for older docs missing that name.
      final reviews =
          ratingsSnap.docs.map((d) => {...d.data(), '_id': d.id}).toList();
      final missingNameIds = reviews
          .where((r) => (r['name'] as String? ?? '').isEmpty)
          .map((r) => r['_id'] as String)
          .toSet()
          .toList();
      final userNames = <String, String>{};
      if (missingNameIds.isNotEmpty) {
        final userSnaps = await Future.wait(missingNameIds
            .map((id) => _firestore.collection('users').doc(id).get()));
        for (var i = 0; i < missingNameIds.length; i++) {
          userNames[missingNameIds[i]] =
              (userSnaps[i].data()?['name'] as String?) ?? '';
        }
      }

      if (!mounted) return;
      setState(() {
        _monthly = monthlySnap.docs.map((d) => d.data()).toList();
        _daily = dailySnap.docs.map((d) => d.data()).toList();
        _rate = rateNumbers > 0 ? rateSum / rateNumbers : 0;
        _rateNumbers = rateNumbers;
        _reviews = reviews;
        _userNames = userNames;
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

  /// (source, offset, count) for the current vs. previous window of a period
  /// - e.g. d7's previous window is _daily[7..14), which is why _load fetches
  /// 60 days / 24 months instead of just 30/12.
  (List<Map<String, dynamic>>, int, int) _rangeFor(_Period period,
      {required bool previous}) {
    switch (period) {
      case _Period.d7:
        return (_daily, previous ? 7 : 0, 7);
      case _Period.d30:
        return (_daily, previous ? 30 : 0, 30);
      case _Period.y1:
        return (_monthly, previous ? 12 : 0, 12);
    }
  }

  Map<String, num> _sumRange(
      List<Map<String, dynamic>> source, int offset, int count) {
    final docs = source.skip(offset).take(count).toList();
    num orders = 0;
    num completed = 0;
    num canceled = 0;
    double revenue = 0;
    for (final d in docs) {
      orders += (d['total_orders'] as num?) ?? 0;
      completed += (d['completed_orders'] as num?) ?? 0;
      canceled += (d['total_canceled'] as num?) ?? 0;
      revenue += (d['total_revenue'] as num?)?.toDouble() ?? 0;
    }
    return {
      'orders': orders,
      'completed': completed,
      'canceled': canceled,
      'revenue': revenue
    };
  }

  Map<String, num> _statsFor(_Period period) {
    final (source, offset, count) = _rangeFor(period, previous: false);
    return _sumRange(source, offset, count);
  }

  /// null when the fetched window doesn't reach far enough back to cover a
  /// full previous period (e.g. a brand new store) - the delta badge is
  /// hidden rather than compared against a partial, misleading window.
  Map<String, num>? _previousStatsFor(_Period period) {
    final (source, offset, count) = _rangeFor(period, previous: true);
    if (source.length < offset + count) return null;
    return _sumRange(source, offset, count);
  }

  /// Percent change vs. the previous period, or null if there's nothing
  /// meaningful to compare against (no previous data, or previous was zero).
  double? _deltaPercent(num current, num? previous) {
    if (previous == null || previous <= 0) return null;
    return (current - previous) / previous * 100;
  }

  String _formatCount(num value) {
    if (value >= 1000) {
      final k = value / 1000;
      return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
    }
    return value.toStringAsFixed(0);
  }

  List<double> _hoursArray(Map<String, dynamic>? hours) {
    final arr = List<double>.filled(24, 0);
    if (hours == null) return arr;
    hours.forEach((key, value) {
      final h = int.tryParse(key);
      if (h != null && h >= 0 && h < 24) {
        arr[h] = (value as num?)?.toDouble() ?? 0;
      }
    });
    return arr;
  }

  List<double> _avgHoursArray(List<Map<String, dynamic>> days) {
    final sum = List<double>.filled(24, 0);
    var count = 0;
    for (final d in days) {
      final hours = d['hours'] as Map<String, dynamic>?;
      if (hours == null) continue;
      final arr = _hoursArray(hours);
      for (var i = 0; i < 24; i++) {
        sum[i] += arr[i];
      }
      count++;
    }
    if (count == 0) return sum;
    return sum.map((v) => v / count).toList();
  }

  String _monthLabel(String? monthKey) {
    if (monthKey == null || monthKey.length < 7) return '';
    const names = [
      'Jan',
      'Fev',
      'Mar',
      'Avr',
      'Mai',
      'Jun',
      'Jul',
      'Aou',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = int.tryParse(monthKey.substring(5, 7));
    if (m == null || m < 1 || m > 12) return '';
    return names[m - 1];
  }

  String _dayLabel(String? dayKey) {
    if (dayKey == null || dayKey.length < 10) return '';
    return dayKey.substring(8, 10);
  }

  String _periodChartLabel(_Period period) {
    switch (period) {
      case _Period.d7:
        return TranslationHelper.get('analytics_period_label_7d');
      case _Period.d30:
        return TranslationHelper.get('analytics_period_label_30d');
      case _Period.y1:
        return TranslationHelper.get('analytics_period_label_1y');
    }
  }

  /// Completed-orders trend follows the selected period tab (unlike the
  /// hours trend below, which always stays pinned to the last 7 days) -
  /// daily docs for 7/30 days, monthly docs for the 1-year view.
  (List<double>, List<String>) _completedOrdersSeries(_Period period) {
    switch (period) {
      case _Period.d7:
        final days = _daily.take(7).toList().reversed.toList();
        return (
          days
              .map((d) => ((d['completed_orders'] as num?) ?? 0).toDouble())
              .toList(),
          days.map((d) => _dayLabel(d['day'] as String?)).toList(),
        );
      case _Period.d30:
        final days = _daily.take(30).toList().reversed.toList();
        return (
          days
              .map((d) => ((d['completed_orders'] as num?) ?? 0).toDouble())
              .toList(),
          days.map((d) => _dayLabel(d['day'] as String?)).toList(),
        );
      case _Period.y1:
        final months = _monthly.reversed.toList();
        return (
          months
              .map((d) => ((d['completed_orders'] as num?) ?? 0).toDouble())
              .toList(),
          months.map((d) => _monthLabel(d['month'] as String?)).toList(),
        );
    }
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
              TranslationHelper.get('analytics_page_title'),
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
    final stats = _statsFor(_period);
    final orders = stats['orders']!;
    final completed = stats['completed']!;
    final canceled = stats['canceled']!;
    final revenue = stats['revenue']!.toDouble();
    final avgOrderValue = completed > 0 ? revenue / completed : 0.0;
    final completionRate = orders > 0 ? completed / orders * 100 : 0.0;

    final previous = _previousStatsFor(_period);
    final prevOrders = previous?['orders'];
    final prevCompleted = previous?['completed'];
    final prevCanceled = previous?['canceled'];
    final prevRevenue = previous?['revenue'];
    final prevAvgOrderValue = previous != null && previous['completed']! > 0
        ? previous['revenue']!.toDouble() / previous['completed']!
        : null;
    final prevCompletionRate = previous != null && previous['orders']! > 0
        ? previous['completed']! / previous['orders']! * 100
        : null;

    final hasPeriodData = _statsFor(_period)['orders']! > 0 ||
        (_period == _Period.y1 ? _monthly.isNotEmpty : _daily.isNotEmpty);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildPeriodSelector(),
        const SizedBox(height: 16),
        if (!hasPeriodData)
          _buildEmptyCard(TranslationHelper.get('analytics_no_data'))
        else
          _buildStatsGrid(
            revenue: revenue,
            orders: orders,
            completed: completed,
            canceled: canceled,
            avgOrderValue: avgOrderValue,
            completionRate: completionRate,
            revenueDelta: _deltaPercent(revenue, prevRevenue),
            ordersDelta: _deltaPercent(orders, prevOrders),
            completedDelta: _deltaPercent(completed, prevCompleted),
            canceledDelta: _deltaPercent(canceled, prevCanceled),
            avgOrderValueDelta: _deltaPercent(avgOrderValue, prevAvgOrderValue),
            completionRateDelta:
                _deltaPercent(completionRate, prevCompletionRate),
          ),
        const SizedBox(height: 22),
        _buildChartCard(
          title: TranslationHelper.get('analytics_completed_orders_chart_title',
              {'period': _periodChartLabel(_period)}),
          child: _buildCompletedOrdersChart(),
        ),
        const SizedBox(height: 16),
        _buildChartCard(
          title: TranslationHelper.get('analytics_hours_trend_chart_title'),
          child: _daily.isEmpty
              ? _buildEmptyChartPlaceholder()
              : _buildHoursTrendChart(),
        ),
        const SizedBox(height: 22),
        _buildReviewsSection(),
      ],
    );
  }

  Widget _buildPeriodSelector() {
    Widget tab(_Period p, String label) {
      final selected = _period == p;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _period = p),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFFF9800) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : const Color(0xFF9AA1AC),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
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
      child: Row(
        children: [
          tab(_Period.d7, TranslationHelper.get('analytics_period_7d')),
          tab(_Period.d30, TranslationHelper.get('analytics_period_30d')),
          tab(_Period.y1, TranslationHelper.get('analytics_period_1y')),
        ],
      ),
    );
  }

  Widget _buildStatsGrid({
    required double revenue,
    required num orders,
    required num completed,
    required num canceled,
    required double avgOrderValue,
    required double completionRate,
    double? revenueDelta,
    double? ordersDelta,
    double? completedDelta,
    double? canceledDelta,
    double? avgOrderValueDelta,
    double? completionRateDelta,
  }) {
    final currency = TranslationHelper.get('currency_unit');
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.7,
      children: [
        _buildStatCard(
          value: '${_formatCount(revenue)} $currency',
          label: TranslationHelper.get('analytics_total_revenue'),
          delta: revenueDelta,
        ),
        _buildStatCard(
          value: _formatCount(orders),
          label: TranslationHelper.get('analytics_total_orders'),
          delta: ordersDelta,
        ),
        _buildStatCard(
          value: _formatCount(completed),
          label: TranslationHelper.get('analytics_completed_orders'),
          valueColor: const Color(0xFF1B8A3E),
          delta: completedDelta,
        ),
        _buildStatCard(
          value: _formatCount(canceled),
          label: TranslationHelper.get('analytics_total_canceled'),
          valueColor: const Color(0xFFE74C3C),
          delta: canceledDelta,
          higherIsBetter: false,
        ),
        _buildStatCard(
          value: '${_formatCount(avgOrderValue)} $currency',
          label: TranslationHelper.get('analytics_avg_order_value'),
          delta: avgOrderValueDelta,
        ),
        _buildStatCard(
          value: '${completionRate.toStringAsFixed(0)}%',
          label: TranslationHelper.get('analytics_completion_rate'),
          valueColor: const Color(0xFF1B8A3E),
          delta: completionRateDelta,
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String value,
    required String label,
    Color valueColor = const Color(0xFF2E3A59),
    double? delta,
    bool higherIsBetter = true,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  ),
                ),
              ),
              if (delta != null) ...[
                const SizedBox(width: 6),
                _buildDeltaBadge(delta, higherIsBetter),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
          ),
        ],
      ),
    );
  }

  /// A small colored "+12% / -4%" badge next to a stat's value, comparing it
  /// to the equivalent previous period. Direction of "good" flips for
  /// higherIsBetter: false (canceled orders going up is bad, not good).
  Widget _buildDeltaBadge(double delta, bool higherIsBetter) {
    final isFlat = delta.abs() < 0.5;
    final isUp = delta > 0;
    final isGood = isFlat ? true : (isUp == higherIsBetter);
    final color = isGood ? const Color(0xFF1B8A3E) : const Color(0xFFE74C3C);
    final arrow = isFlat
        ? Icons.remove_rounded
        : (isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(arrow, size: 9, color: color),
          Text(
            '${delta.abs().toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
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

  Widget _buildEmptyChartPlaceholder() {
    return SizedBox(
      height: 140,
      child: Center(
        child: Text(
          TranslationHelper.get('analytics_no_data'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
        ),
      ),
    );
  }

  Widget _buildChartCard({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
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
          Text(
            title,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF9AA1AC),
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildCompletedOrdersChart() {
    final (values, labels) = _completedOrdersSeries(_period);
    if (values.isEmpty) return _buildEmptyChartPlaceholder();

    return SizedBox(
      height: 150,
      child: CustomPaint(
        size: Size.infinite,
        painter: _MonthlyChartPainter(values: values, labels: labels),
      ),
    );
  }

  Widget _buildHoursTrendChart() {
    final last7 = _daily.take(7).toList();
    final today = last7.isNotEmpty
        ? _hoursArray(last7.first['hours'] as Map<String, dynamic>?)
        : List<double>.filled(24, 0);
    final average = _avgHoursArray(last7);
    final peakHour = _peakHour(average);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 140,
          child: CustomPaint(
            size: Size.infinite,
            painter: _HoursTrendChartPainter(today: today, average: average),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _buildLegendDot(const Color(0xFFFF9800),
                TranslationHelper.get('analytics_hours_today_legend')),
            const SizedBox(width: 16),
            _buildLegendDash(const Color(0xFFBFC5D2),
                TranslationHelper.get('analytics_hours_average_legend')),
          ],
        ),
        if (peakHour != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.trending_up_rounded,
                    size: 16, color: Color(0xFFFF9800)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    TranslationHelper.get('analytics_peak_hour',
                        {'range': '${peakHour}h - ${(peakHour + 1) % 24}h'}),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Busiest hour across the last 7 days' average trend, or null when there's
  /// no signal at all (every hour scored 0 - e.g. a brand new store).
  int? _peakHour(List<double> average) {
    var peakIndex = 0;
    var peakValue = average[0];
    for (var i = 1; i < average.length; i++) {
      if (average[i] > peakValue) {
        peakValue = average[i];
        peakIndex = i;
      }
    }
    return peakValue > 0 ? peakIndex : null;
  }

  Widget _buildLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC))),
      ],
    );
  }

  Widget _buildLegendDash(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 8,
          child: CustomPaint(painter: _DashPainter(color: color)),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC))),
      ],
    );
  }

  Widget _buildReviewsSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
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
              Text(
                TranslationHelper.get('analytics_reviews_section_title'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const Spacer(),
              if (_rateNumbers > 0) ...[
                const Icon(Icons.star_rounded,
                    size: 18, color: Color(0xFFFF9800)),
                const SizedBox(width: 3),
                Text(
                  _rate.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  TranslationHelper.get(
                      'analytics_reviews_count', {'count': _rateNumbers}),
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA1AC)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (_reviews.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                TranslationHelper.get('analytics_no_reviews'),
                style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
              ),
            )
          else
            for (var i = 0; i < _reviews.length; i++) ...[
              if (i > 0) const Divider(height: 24, color: Color(0xFFF0F1F4)),
              _buildReviewRow(_reviews[i]),
            ],
        ],
      ),
    );
  }

  Widget _buildReviewRow(Map<String, dynamic> review) {
    final id = review['_id'] as String?;
    final name = (review['name'] as String?)?.isNotEmpty == true
        ? review['name'] as String
        : ((id != null ? _userNames[id] : null) ?? '');
    final rating = ((review['rating'] as num?) ?? 0).toInt().clamp(0, 5);
    final comment = review['comment'] as String? ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name.isNotEmpty
                    ? name
                    : TranslationHelper.get('analytics_anonymous_reviewer'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2E3A59),
                ),
              ),
            ),
            Row(
              children: List.generate(5, (i) {
                return Icon(
                  i < rating ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 14,
                  color: const Color(0xFFFF9800),
                );
              }),
            ),
          ],
        ),
        if (comment.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            comment,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF677489)),
          ),
        ],
      ],
    );
  }
}

/// Compact axis-number formatting shared by both chart painters - "1.2k"
/// past 1000, otherwise a plain rounded integer.
String _formatAxisValue(double value) {
  if (value >= 1000) {
    final k = value / 1000;
    return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
  }
  return value.round().toString();
}

void _drawYAxis(
    Canvas canvas, double leftAxis, double chartWidth, double chartHeight) {
  final gridPaint = Paint()
    ..color = const Color(0xFFF0F1F4)
    ..strokeWidth = 1;
  const ticks = [1.0, 0.5, 0.0];
  for (final t in ticks) {
    final y = chartHeight - t * chartHeight;
    canvas.drawLine(
        Offset(leftAxis, y), Offset(leftAxis + chartWidth, y), gridPaint);
  }
}

void _drawYAxisLabels(
    Canvas canvas, double leftAxis, double chartHeight, double safeMax) {
  const ticks = [1.0, 0.5, 0.0];
  for (final t in ticks) {
    final y = chartHeight - t * chartHeight;
    final tp = TextPainter(
      text: TextSpan(
        text: _formatAxisValue(safeMax * t),
        style: const TextStyle(fontSize: 10, color: Color(0xFF9AA1AC)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(leftAxis - 6 - tp.width, y - tp.height / 2));
  }
}

class _MonthlyChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;

  _MonthlyChartPainter({required this.values, required this.labels});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    const bottomAxis = 20.0;
    const leftAxis = 34.0;
    final chartHeight = size.height - bottomAxis;
    final chartWidth = size.width - leftAxis;
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final safeMax = maxValue <= 0 ? 1.0 : maxValue;
    final stepX = values.length > 1 ? chartWidth / (values.length - 1) : 0.0;

    _drawYAxis(canvas, leftAxis, chartWidth, chartHeight);

    Offset pointAt(int i) {
      final x = leftAxis + (values.length > 1 ? stepX * i : chartWidth / 2);
      final y = chartHeight - (values[i] / safeMax) * chartHeight;
      return Offset(x, y);
    }

    final linePath = Path();
    for (var i = 0; i < values.length; i++) {
      final p = pointAt(i);
      if (i == 0) {
        linePath.moveTo(p.dx, p.dy);
      } else {
        linePath.lineTo(p.dx, p.dy);
      }
    }

    final fillPath = Path.from(linePath)
      ..lineTo(pointAt(values.length - 1).dx, chartHeight)
      ..lineTo(pointAt(0).dx, chartHeight)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFFFF9800).withValues(alpha: 0.22),
          const Color(0xFFFF9800).withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(leftAxis, 0, chartWidth, chartHeight));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = const Color(0xFFFF9800)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(linePath, linePaint);

    final dotPaint = Paint()..color = const Color(0xFFFF9800);
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(pointAt(i), 2.6, dotPaint);
    }

    _drawYAxisLabels(canvas, leftAxis, chartHeight, safeMax);

    // A handful of month labels along the bottom - all of them would crowd a
    // 12-point axis, so only every few are drawn.
    final labelStep = (values.length / 6).ceil().clamp(1, values.length);
    for (var i = 0; i < labels.length; i += labelStep) {
      final p = pointAt(i);
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(fontSize: 10, color: Color(0xFF9AA1AC)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(p.dx - tp.width / 2, chartHeight + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _MonthlyChartPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.labels != labels;
}

class _HoursTrendChartPainter extends CustomPainter {
  final List<double> today;
  final List<double> average;

  _HoursTrendChartPainter({required this.today, required this.average});

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxis = 30.0;
    const bottomAxis = 16.0;
    final chartWidth = size.width - leftAxis;
    final chartHeight = size.height - bottomAxis;
    final maxValue =
        [...today, ...average].fold<double>(0, (m, v) => v > m ? v : m);
    final safeMax = maxValue <= 0 ? 1.0 : maxValue;
    final stepX = chartWidth / 23;

    _drawYAxis(canvas, leftAxis, chartWidth, chartHeight);
    _drawYAxisLabels(canvas, leftAxis, chartHeight, safeMax);

    Offset pointAt(List<double> series, int i) {
      final x = leftAxis + stepX * i;
      final y = chartHeight - (series[i] / safeMax) * chartHeight;
      return Offset(x, y);
    }

    void drawLine(List<double> series, Paint paint, {bool dashed = false}) {
      if (!dashed) {
        final path = Path();
        for (var i = 0; i < 24; i++) {
          final p = pointAt(series, i);
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        canvas.drawPath(path, paint);
        return;
      }
      const dashWidth = 5.0;
      const dashGap = 4.0;
      for (var i = 0; i < 23; i++) {
        final p1 = pointAt(series, i);
        final p2 = pointAt(series, i + 1);
        final segmentLength = (p2 - p1).distance;
        if (segmentLength == 0) continue;
        final dir = (p2 - p1) / segmentLength;
        var drawn = 0.0;
        var draw = true;
        while (drawn < segmentLength) {
          final len = draw ? dashWidth : dashGap;
          final next =
              (drawn + len) > segmentLength ? segmentLength : drawn + len;
          if (draw) {
            canvas.drawLine(p1 + dir * drawn, p1 + dir * next, paint);
          }
          drawn = next;
          draw = !draw;
        }
      }
    }

    final averagePaint = Paint()
      ..color = const Color(0xFFBFC5D2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    drawLine(average, averagePaint, dashed: true);

    final todayPaint = Paint()
      ..color = const Color(0xFFFF9800)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    drawLine(today, todayPaint);

    // Hour markers every 4 hours (0h, 4h, ... 20h) along the bottom - a
    // label per hour would crowd a 24-point axis.
    for (var h = 0; h < 24; h += 4) {
      final x = leftAxis + stepX * h;
      final tp = TextPainter(
        text: TextSpan(
          text: '${h}h',
          style: const TextStyle(fontSize: 10, color: Color(0xFF9AA1AC)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, chartHeight + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _HoursTrendChartPainter oldDelegate) =>
      oldDelegate.today != today || oldDelegate.average != average;
}

class _DashPainter extends CustomPainter {
  final Color color;
  const _DashPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(covariant _DashPainter oldDelegate) =>
      oldDelegate.color != color;
}
