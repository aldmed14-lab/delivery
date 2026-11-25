import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/pages/client/home_shell.dart';
import 'package:flutter_application_1/pages/auth/auth_page.dart';
import 'package:flutter_application_1/pages/auth/language_selection_page.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/connection_dialog.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/delivery_offer_overlay.dart';
import 'package:flutter_application_1/widgets/update_required_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: false,
  );
  String? language = await TranslationHelper.getSavedLanguage();
  await TranslationHelper.loadTranslations(language ?? 'english');
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Firebase Auth FCM Check',
      home: MainPage(),
      // Wraps every route (not just one page) so a delivery driver's
      // "Nouvelle course" offer can appear on top regardless of which
      // screen they're currently on - see DeliveryOfferOverlay.
      builder: (context, child) =>
          DeliveryOfferOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  String? language;
  final InternetConnectionService _connectionService =
      InternetConnectionService();
  bool _alreadyChecked = false;

  @override
  void initState() {
    super.initState();

    // Do an immediate check on launch
    _checkInitialConnection();

    // Also listen for ongoing connection changes
    _connectionService.connectionStream.listen((hasConnection) {
      if (mounted && !_alreadyChecked && hasConnection) {
        _alreadyChecked = true;
        _checkAuthAndFCM();
      } else if (!_alreadyChecked && !hasConnection) {
        _showSnack(TranslationHelper.get('no_internet'));
      }
    });
  }

  Future<void> _checkInitialConnection() async {
    bool hasConnection = await _connectionService.checkNow();
    if (mounted && !_alreadyChecked && hasConnection) {
      _alreadyChecked = true;
      _checkAuthAndFCM();
    } else if (!_alreadyChecked && !hasConnection) {
      _showSnack(TranslationHelper.get('no_internet'));
    }
  }

  /// Returns true when the app may continue. Compares lib/version.json's
  /// `version` against system/config's android_version (ios_version on
  /// iOS); on mismatch shows the blocking update dialog with
  /// android_applink / ios_applink and returns false.
  ///
  /// A missing config doc or an empty version field skips the check, so a
  /// config mistake never locks every user out of the app.
  Future<bool> _checkAppVersion() async {
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;

    final localJson = await rootBundle.loadString('lib/version.json');
    final localVersion =
        ((jsonDecode(localJson) as Map<String, dynamic>)['version'] ?? '')
            .toString()
            .trim();

    final config = (await FirebaseFirestore.instance
                .collection('system')
                .doc('config')
                .get())
            .data() ??
        const {};
    final requiredVersion =
        (config[isIos ? 'ios_version' : 'android_version'] ?? '')
            .toString()
            .trim();
    if (requiredVersion.isEmpty || requiredVersion == localVersion) {
      return true;
    }

    if (!mounted) return false;
    UpdateRequiredDialog.show(
      context,
      language: TranslationHelper.currentLanguage,
      appLink: (config[isIos ? 'ios_applink' : 'android_applink'] ?? '')
          .toString(),
    );
    return false;
  }

  Future<void> _checkAuthAndFCM() async {
    try {
      if (!await _checkAppVersion()) return;
    } catch (e) {
      if (!mounted) return;
      _showSnack(isConnectivityError(e)
          ? TranslationHelper.get('no_internet')
          : TranslationHelper.get('error'));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    String? languagePref = prefs.getString('language');

    if (languagePref != "ar" && languagePref != "fr") {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => LanguageSelectionPage()),
      );
      return;
    }

    language = languagePref;

    User? user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _goToAuthPage();
      return;
    }

    try {
      String uid = user.uid;
      String? currentFcm = await FirebaseMessaging.instance.getToken();

      if (currentFcm == null) {
        _goToAuthPage();
        return;
      }

      DocumentReference userDoc =
          FirebaseFirestore.instance.collection('users').doc(uid);
      DocumentSnapshot snapshot = await userDoc.get();
      if (snapshot.exists && snapshot["active"] == true) {
        _goToHomePage();
      } else {
        _goblockPage();
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(isConnectivityError(e)
          ? TranslationHelper.get('no_internet')
          : TranslationHelper.get('error'));
    }
  }

  void _goblockPage() {
    if (!mounted) return;
    ConnectionDialog.show(
      context,
      language: language ?? 'fr',
      message: TranslationHelper.get('account_blocked'),
      onDismiss: _goToAuthPage,
    );
  }

  void _goToHomePage() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => HomeShell(language!)),
    );
  }

  void _goToAuthPage() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => AuthPage(language!)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/background.png',
            fit: BoxFit.fill,
            width: double.infinity,
            height: double.infinity,
          ),
          const Center(
            child: CircularProgressIndicator(),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ConnectionDialog.show(
      context,
      language: language ?? 'fr',
      message: msg,
      onDismiss: () => _alreadyChecked = false,
    );
  }
}
