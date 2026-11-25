import 'dart:async';

import 'package:flutter/material.dart';

/// Dismissible in-page alert banner - green for success, red for errors -
/// used in place of a ScaffoldMessenger SnackBar wherever a SnackBar would
/// visually clash with (or sit right on top of) a bottom nav bar. One
/// shared widget so every page using it looks identical.
class AlertCard extends StatelessWidget {
  final String message;
  final bool isError;
  final VoidCallback onDismiss;

  const AlertCard({
    required this.message,
    required this.onDismiss,
    this.isError = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final color = isError ? const Color(0xFFE74C3C) : const Color(0xFF1B8A3E);
    final bg = isError ? const Color(0xFFFDF1F0) : const Color(0xFFE6F7EA);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_rounded,
              color: color,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
              ),
            ),
            InkWell(
              onTap: onDismiss,
              child: Icon(Icons.close_rounded, color: color, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds [showAlert]/[alertCard] to a [State] - owns the message, error
/// flag and auto-dismiss timer so pages don't each reimplement them.
/// Call [disposeAlert] from the page's own `dispose()`.
mixin AlertCardMixin<T extends StatefulWidget> on State<T> {
  String? _alertMessage;
  bool _alertIsError = false;
  Timer? _alertTimer;

  void showAlert(String message, {bool isError = false}) {
    if (!mounted) return;
    _alertTimer?.cancel();
    setState(() {
      _alertMessage = message;
      _alertIsError = isError;
    });
    _alertTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _alertMessage = null);
    });
  }

  void dismissAlert() {
    if (mounted) setState(() => _alertMessage = null);
  }

  void disposeAlert() => _alertTimer?.cancel();

  /// Null when there's nothing to show - callers should conditionally
  /// include it (`if (alertCard != null) alertCard!`) rather than always
  /// rendering it, so no space is reserved when there's no alert.
  Widget? get alertCard => _alertMessage == null
      ? null
      : AlertCard(
          message: _alertMessage!,
          isError: _alertIsError,
          onDismiss: dismissAlert,
        );
}
