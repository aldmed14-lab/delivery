import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Shared "leave without saving?" confirmation - shown by an edit page
/// (store info / work time / item edit, ...) when the owner tries to
/// navigate away with unsaved changes. Returns true only if they chose to
/// discard; false/null (dismissed) means stay on the page.
Future<bool> confirmDiscardChanges(BuildContext context,
    {required bool isArabic}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                TranslationHelper.get('discard_changes_title'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2E3A59),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                TranslationHelper.get('discard_changes_message'),
                style:
                    const TextStyle(fontSize: 13.5, color: Color(0xFF677489)),
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
                        TranslationHelper.get('keep_editing_button'),
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
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE74C3C),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        TranslationHelper.get('discard_button'),
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
  );
  return result ?? false;
}
