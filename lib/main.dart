import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/pages/client/home_shell.dart';
import 'package:flutter_application_1/pages/registre/auth_page.dart';
import 'package:flutter_application_1/pages/registre/language.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/connection_ui.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
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
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  _MainPageState createState() => _MainPageState();
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

  Future<void> _checkAuthAndFCM() async {
    final prefs = await SharedPreferences.getInstance();
    String? languagePref = prefs.getString('language');

    if (languagePref != "ar" && languagePref != "fr") {
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

      if (snapshot.exists && snapshot["fmc"] == currentFcm) {
        if (snapshot["active"] == true) {
          _goToHomePage();
        } else {
          _goblockPage();
        }
      } else {
        _goToAuthPage();
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
