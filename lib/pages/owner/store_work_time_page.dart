import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:flutter_application_1/widgets/discard_changes_dialog.dart';

const _days = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// One opening-hours slot - `start_day`/`end_day` differing lets a slot
/// cross midnight into (or span several) other days, e.g. "Friday 18:00 →
/// Saturday 02:00" (map.txt's own example format).
class _WorkSlot {
  String startDay;
  TimeOfDay startTime;
  String endDay;
  TimeOfDay endTime;

  _WorkSlot({
    required this.startDay,
    required this.startTime,
    required this.endDay,
    required this.endTime,
  });
}

/// Owner-editable opening hours (`stores/{storeId}/work_time`) - a list of
/// day+time slots, edited locally and committed all at once by "Enregistrer
/// les horaires" (delete-then-recreate the whole subcollection, since these
/// docs are only ever read as an ordered set, never addressed by their own
/// id elsewhere - see lib/map.txt).
class StoreWorkTimePage extends StatefulWidget {
  final String language;
  final String storeId;
  const StoreWorkTimePage(this.language, this.storeId, {super.key});

  @override
  State<StoreWorkTimePage> createState() => _StoreWorkTimePageState();
}

class _StoreWorkTimePageState extends State<StoreWorkTimePage>
    with AlertCardMixin {
  final _firestore = FirebaseFirestore.instance;

  bool get _isArabic => widget.language == 'ar';

  bool _isLoading = true;
  bool _isSaving = false;
  Object? _loadError;
  final List<_WorkSlot> _slots = [];

  // What's actually saved, as comparable strings (TimeOfDay has no useful
  // equality of its own) - refreshed after both _load() and a successful
  // _save(), so a stray back-tap with pending edits can be caught.
  List<String> _savedSignature = [];

  String _newStartDay = _days.first;
  TimeOfDay _newStartTime = const TimeOfDay(hour: 9, minute: 0);
  String _newEndDay = _days.first;
  TimeOfDay _newEndTime = const TimeOfDay(hour: 22, minute: 0);

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
          .collection('stores')
          .doc(widget.storeId)
          .collection('work_time')
          .orderBy('index')
          .get();
      if (!mounted) return;
      setState(() {
        _slots
          ..clear()
          ..addAll(snap.docs.map((d) {
            final data = d.data();
            return _WorkSlot(
              startDay: data['start_day'] as String? ?? _days.first,
              startTime: _parseTime(data['start_time'] as String?) ??
                  const TimeOfDay(hour: 9, minute: 0),
              endDay: data['end_day'] as String? ?? _days.first,
              endTime: _parseTime(data['end_time'] as String?) ??
                  const TimeOfDay(hour: 22, minute: 0),
            );
          }));
        _isLoading = false;
        _syncSavedSnapshot();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _isLoading = false;
      });
    }
  }

  String _slotSignature(_WorkSlot s) =>
      '${s.startDay}|${_formatTime24(s.startTime)}|${s.endDay}|${_formatTime24(s.endTime)}';

  void _syncSavedSnapshot() {
    _savedSignature = _slots.map(_slotSignature).toList();
  }

  bool _hasUnsavedChanges() {
    if (_isLoading || _loadError != null) return false;
    final current = _slots.map(_slotSignature).toList();
    if (current.length != _savedSignature.length) return true;
    for (var i = 0; i < current.length; i++) {
      if (current[i] != _savedSignature[i]) return true;
    }
    return false;
  }

  Future<void> _handleBack() async {
    if (!_hasUnsavedChanges()) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await confirmDiscardChanges(context, isArabic: _isArabic);
    if (!mounted) return;
    if (discard) Navigator.of(context).pop();
  }

  TimeOfDay? _parseTime(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _formatTime24(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _dayLabel(String day) => TranslationHelper.get('day_$day');

  int _weeklyMinutes(String day, TimeOfDay time) =>
      _days.indexOf(day) * 1440 + time.hour * 60 + time.minute;

  /// One slot as one or two (start, end) ranges on a 0..7*1440 weekly
  /// timeline - normally just one, but a slot that wraps past Sunday back
  /// into Monday (e.g. "Sunday 23:00 → Monday 02:00") has to split into
  /// the tail of the week plus the head of the next one, or a straight
  /// `start < end` comparison against another slot would see it backwards.
  List<(int, int)> _slotRanges(_WorkSlot slot) {
    const weekMinutes = 7 * 1440;
    final start = _weeklyMinutes(slot.startDay, slot.startTime);
    final end = _weeklyMinutes(slot.endDay, slot.endTime);
    if (end <= start) {
      return [(start, weekMinutes), (0, end)];
    }
    return [(start, end)];
  }

  bool _rangesOverlap((int, int) a, (int, int) b) => a.$1 < b.$2 && b.$1 < a.$2;

  /// The existing slot [_slots] that the given day/time range collides
  /// with, if any - checked against every range-pair of both (a wrap-
  /// around slot contributes two), so a new "Sunday 22:00 → Monday 01:00"
  /// slot correctly catches a conflict with an existing "Monday 00:30 →
  /// Monday 06:00" one even though neither's start times are close.
  _WorkSlot? _findOverlap(_WorkSlot candidate) {
    final candidateRanges = _slotRanges(candidate);
    for (final existing in _slots) {
      for (final r1 in candidateRanges) {
        for (final r2 in _slotRanges(existing)) {
          if (_rangesOverlap(r1, r2)) return existing;
        }
      }
    }
    return null;
  }

  void _addSlot() {
    final candidate = _WorkSlot(
      startDay: _newStartDay,
      startTime: _newStartTime,
      endDay: _newEndDay,
      endTime: _newEndTime,
    );
    if (_weeklyMinutes(candidate.startDay, candidate.startTime) ==
        _weeklyMinutes(candidate.endDay, candidate.endTime)) {
      showAlert(TranslationHelper.get('work_time_zero_length'), isError: true);
      return;
    }
    final conflict = _findOverlap(candidate);
    if (conflict != null) {
      final conflictLabel = conflict.endDay != conflict.startDay
          ? '${_dayLabel(conflict.startDay)} ${_formatTime24(conflict.startTime)} → ${_dayLabel(conflict.endDay)} ${_formatTime24(conflict.endTime)}'
          : '${_dayLabel(conflict.startDay)} ${_formatTime24(conflict.startTime)} → ${_formatTime24(conflict.endTime)}';
      showAlert(
        TranslationHelper.get(
            'work_time_overlap_message', {'slot': conflictLabel}),
        isError: true,
      );
      return;
    }
    setState(() => _slots.add(candidate));
  }

  void _removeSlot(int index) {
    setState(() => _slots.removeAt(index));
  }

  Future<void> _pickTime(
      TimeOfDay initial, ValueChanged<TimeOfDay> onPicked) async {
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) onPicked(picked);
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final workTimeRef = _firestore
          .collection('stores')
          .doc(widget.storeId)
          .collection('work_time');
      final existing = await workTimeRef.get();

      final batch = _firestore.batch();
      for (final doc in existing.docs) {
        batch.delete(doc.reference);
      }
      for (var i = 0; i < _slots.length; i++) {
        final slot = _slots[i];
        batch.set(workTimeRef.doc(), {
          'index': i,
          'start_day': slot.startDay,
          'start_time': _formatTime24(slot.startTime),
          'end_day': slot.endDay,
          'end_time': _formatTime24(slot.endTime),
        });
      }
      await batch.commit();
      _syncSavedSnapshot();
      if (mounted) showAlert(TranslationHelper.get('changes_saved'));
    } catch (e) {
      if (mounted) {
        showAlert(
          TranslationHelper.get(
              isConnectivityError(e) ? 'no_internet' : 'error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          backgroundColor: const Color(0xFFF7F8FA),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
                  ? _buildErrorState()
                  : Column(
                      children: [
                        _buildHeader(),
                        if (alertCard != null) alertCard!,
                        Expanded(child: _buildBody()),
                        _buildSaveBar(),
                      ],
                    ),
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
              onPressed: () => Navigator.of(context).pop(),
              child: Text(TranslationHelper.get('go_back')),
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
            onTap: _handleBack,
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
          Text(
            TranslationHelper.get('work_time_page_title'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildSectionLabel('slots_section_label'),
        const SizedBox(height: 10),
        if (_slots.isEmpty)
          _buildEmptySlots()
        else
          for (var i = 0; i < _slots.length; i++) ...[
            _buildSlotRow(i),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 12),
        _buildSectionLabel('add_slot_section_label'),
        const SizedBox(height: 10),
        _buildAddSlotForm(),
      ],
    );
  }

  Widget _buildSectionLabel(String key) => Text(
        TranslationHelper.get(key),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Color(0xFF9AA1AC),
          letterSpacing: 0.5,
        ),
      );

  Widget _buildEmptySlots() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFFE1E4E9), style: BorderStyle.solid),
      ),
      child: Center(
        child: Text(
          TranslationHelper.get('no_work_time_slots'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF9AA1AC)),
        ),
      ),
    );
  }

  Widget _buildSlotRow(int index) {
    final slot = _slots[index];
    final label = slot.endDay != slot.startDay
        ? '${_dayLabel(slot.startDay)} ${_formatTime24(slot.startTime)} → ${_dayLabel(slot.endDay)} ${_formatTime24(slot.endTime)}'
        : '${_dayLabel(slot.startDay)} ${_formatTime24(slot.startTime)} → ${_formatTime24(slot.endTime)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
          const Icon(Icons.schedule, color: Color(0xFFFF9800), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2E3A59),
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _removeSlot(index),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.delete_outline,
                  color: Color(0xFFE74C3C), size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddSlotForm() {
    return Container(
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
        children: [
          Row(
            children: [
              Expanded(
                child: _buildDayDropdownField(
                  label: 'start_day_label',
                  value: _newStartDay,
                  onChanged: (v) => setState(() => _newStartDay = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTimeField(
                  label: 'start_time_label',
                  time: _newStartTime,
                  onTap: () => _pickTime(
                      _newStartTime, (t) => setState(() => _newStartTime = t)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildDayDropdownField(
                  label: 'end_day_label',
                  value: _newEndDay,
                  onChanged: (v) => setState(() => _newEndDay = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTimeField(
                  label: 'end_time_label',
                  time: _newEndTime,
                  onTap: () => _pickTime(
                      _newEndTime, (t) => setState(() => _newEndTime = t)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _addSlot,
              icon: const Icon(Icons.add, size: 18),
              label: Text(TranslationHelper.get('add_slot_button')),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9800),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDayDropdownField({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          TranslationHelper.get(label),
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE1E4E9)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down,
                  color: Color(0xFFFF9800)),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2E3A59),
              ),
              items: [
                for (final day in _days)
                  DropdownMenuItem(value: day, child: Text(_dayLabel(day))),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeField({
    required String label,
    required TimeOfDay time,
    required VoidCallback onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          TranslationHelper.get(label),
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF9AA1AC)),
        ),
        const SizedBox(height: 4),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE1E4E9)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  time.format(context),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFFF9800),
                  ),
                ),
                const Icon(Icons.access_time,
                    size: 16, color: Color(0xFF9AA1AC)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isSaving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF9800),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  )
                : Text(
                    TranslationHelper.get('save_work_time_button'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ),
    );
  }
}
