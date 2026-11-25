import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/utils/url_utils.dart';

/// Blocking "please update" dialog shown by MainPage when the installed
/// version (lib/version.json) doesn't match system/config's
/// android_version / ios_version. It can't be dismissed (no barrier tap, no
/// back button) - the only action opens the store link, and the dialog
/// stays up so the user can't continue on the outdated build.
class UpdateRequiredDialog {
  UpdateRequiredDialog._();

  static Future<void> show(
    BuildContext context, {
    required String language,
    required String appLink,
  }) {
    final isArabic = language == 'ar';
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          elevation: 10,
          child: Directionality(
            textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9800).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: Color(0xFFFF9800),
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    TranslationHelper.get('update_required_title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E3A59),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    TranslationHelper.get('update_required_message'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xFF677489),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: appLink.isEmpty
                          ? null
                          : () => openExternalUrl(appLink),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF9800),
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('update_now'),
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
        ),
      ),
    );
  }
}
