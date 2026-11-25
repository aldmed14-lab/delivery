import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TranslationHelper {
  static Map<String, String>? _translations;

  // The language code loadTranslations was last called with - most widgets
  // already get `language` passed down from whatever page created them,
  // but something rendered outside any specific page (e.g. a global
  // overlay wired into MaterialApp.builder) has no page context to read it
  // from, so it reads this static instead.
  static String currentLanguage = 'fr';

  // Load the translations from JSON file based on the selected language
  static Future<void> loadTranslations(String language) async {
    String jsonString;
    switch (language) {
      case 'ar':
        jsonString = await rootBundle.loadString('lib/translation/ar.json');
        break;
      default:
        jsonString = await rootBundle.loadString('lib/translation/fr.json');
    }
    _translations = Map<String, String>.from(json.decode(jsonString));
    currentLanguage = language;
  }

  // Get the translation for a given key. Pass [params] to substitute
  // "{name}"-style placeholders in the translated string, e.g.
  // TranslationHelper.get('greeting', {'name': userName}).
  static String get(String key, [Map<String, dynamic>? params]) {
    String value =
        _translations?[key] ?? key; // Fallback to the key if not found
    if (params != null) {
      params.forEach((placeholder, replacement) {
        value = value.replaceAll('{$placeholder}', replacement.toString());
      });
    }
    return value;
  }

  // Save user language preference
  static Future<void> saveLanguagePreference(String language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', language);
  }

  // Get saved language preference
  static Future<String?> getSavedLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('language') ?? 'english'; // Default to 'english'
  }
}
