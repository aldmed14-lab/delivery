import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Single place that renders the "something went wrong" dialog so every
/// page shows the same look for connection/network errors instead of each
/// screen growing its own copy-pasted dialog (or, worse, silently
/// swallowing the error).
class ConnectionDialog {
  ConnectionDialog._();

  static bool _isShowing = false;

  /// Shows the standard error dialog. Safe to call from anywhere: it no-ops
  /// if the widget is gone or a dialog is already up, so callers never need
  /// to track that themselves.
  static void show(
    BuildContext context, {
    required String language,
    required String message,
    VoidCallback? onDismiss,
  }) {
    if (_isShowing) return;
    if (!context.mounted) return;

    final isArabic = language == 'ar';
    _isShowing = true;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          elevation: 10,
          child: Directionality(
            textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
            child: Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.wifi_off_rounded,
                          color: Color(0xFFFF3B30),
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        TranslationHelper.get('error'),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2E3A59),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    message,
                    textAlign: isArabic ? TextAlign.right : TextAlign.left,
                    style: const TextStyle(
                      fontSize: 20,
                      color: Color(0xFF677489),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF3B30),
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('ok'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).then((_) {
      _isShowing = false;
      onDismiss?.call();
    });
  }

  /// Convenience for the most common case: tell the user they're offline.
  static void showNoInternet(BuildContext context, {required String language}) {
    show(context,
        language: language, message: TranslationHelper.get('no_internet'));
  }
}

/// Mixin for `State<T>` classes that need to (a) know the live connection
/// status and (b) run network calls with a single, consistent error path
/// instead of each async method inventing its own try/catch behavior.
///
/// Usage:
/// ```dart
/// class _MyPageState extends State<MyPage> with ConnectionAware<MyPage> {
///   Future<void> _load() async {
///     final data = await runGuarded(() => FirebaseFirestore.instance...get());
///     if (data == null) return; // error already surfaced to the user
///     ...
///   }
/// }
/// ```
mixin ConnectionAware<T extends StatefulWidget> on State<T> {
  final InternetConnectionService _connectionService =
      InternetConnectionService();
  StreamSubscription<bool>? _connectionSub;
  bool hasInternet = true;

  /// Override to react to connection changes (e.g. retry a load). Called
  /// after [hasInternet] has been updated and, when offline, after the
  /// standard dialog has been shown.
  void onConnectionChanged(bool hasConnection) {}

  /// Language code used to pick the dialog's text direction/translations.
  /// Override in the page (most pages already carry `widget.language`).
  String get connectionLanguage => 'fr';

  void initConnectionAwareness() {
    hasInternet = InternetConnectionService().lastKnownStatus;
    _connectionSub = _connectionService.connectionStream.listen((connected) {
      if (!mounted) return;
      setState(() => hasInternet = connected);
      if (!connected) {
        ConnectionDialog.showNoInternet(context, language: connectionLanguage);
      }
      onConnectionChanged(connected);
    });
  }

  void disposeConnectionAwareness() {
    _connectionSub?.cancel();
  }

  /// Runs [action], but first makes sure there's a connection and, on
  /// failure, classifies the error and shows the right message instead of
  /// letting it disappear into a `print()` or a generic snackbar.
  ///
  /// Returns the result, or `null` if the call failed (the caller can
  /// distinguish a "real" null result from a failure at the call site if
  /// needed by checking [hasInternet] or wrapping a non-nullable type).
  Future<R?> runGuarded<R>(
    Future<R> Function() action, {
    String? offlineMessage,
    String? errorMessage,
  }) async {
    final online = await _connectionService.checkNow();
    if (!online) {
      if (mounted) {
        ConnectionDialog.show(
          context,
          language: connectionLanguage,
          message: offlineMessage ?? TranslationHelper.get('no_internet'),
        );
      }
      return null;
    }

    try {
      return await action();
    } catch (e) {
      if (!mounted) return null;
      final message = isConnectivityError(e)
          ? (offlineMessage ?? TranslationHelper.get('no_internet'))
          : (errorMessage ?? TranslationHelper.get('error'));
      ConnectionDialog.show(context,
          language: connectionLanguage, message: message);
      return null;
    }
  }
}
