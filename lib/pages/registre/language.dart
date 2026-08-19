import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/registre/auth_page.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:flutter_application_1/widgets/alert_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageSelectionPage extends StatefulWidget {
  const LanguageSelectionPage({super.key});

  @override
  State<LanguageSelectionPage> createState() => _LanguageSelectionPageState();
}

class _LanguageSelectionPageState extends State<LanguageSelectionPage>
    with SingleTickerProviderStateMixin, AlertCardMixin {
  String? selectedLanguage = "fr";
  String headerText = "";
  String subtitleText = "";
  String continueButtonText = "";
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );
    _controller.forward();
    _loadPreviewText('fr');
  }

  @override
  void dispose() {
    _controller.dispose();
    disposeAlert();
    super.dispose();
  }

  // This screen runs before a language has been committed, and needs to
  // preview either language's UI text before the user picks one - so unlike
  // every other page, it has to (re)load TranslationHelper's strings itself
  // for whichever language is currently being previewed.
  Future<void> _loadPreviewText(String language) async {
    await TranslationHelper.loadTranslations(language);
    if (!mounted) return;
    setState(() {
      headerText = TranslationHelper.get('choose_language');
      subtitleText = TranslationHelper.get('language_subtitle');
      continueButtonText = TranslationHelper.get('continue_button');
    });
  }

  Future<void> _selectLanguage(String language) async {
    selectedLanguage = language;
    await _loadPreviewText(language);
  }

  void _saveLanguageAndNavigate() async {
    if (selectedLanguage != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('language', selectedLanguage!);

        // ✅ Load translations here
        await TranslationHelper.loadTranslations(selectedLanguage!);
      } catch (e) {
        if (mounted) {
          showAlert(TranslationHelper.get('generic_error_retry'), isError: true);
        }
        return;
      }

      // ✅ THEN navigate to AuthPage
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                AuthPage(selectedLanguage!),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              var begin = const Offset(1.0, 0.0);
              var end = Offset.zero;
              var curve = Curves.easeInOutCubic;
              var tween =
                  Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
              return SlideTransition(
                position: animation.drive(tween),
                child: child,
              );
            },
            transitionDuration: const Duration(milliseconds: 600),
          ),
        );
      }
    } else {
      showAlert(TranslationHelper.get('select_language_first'), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFFF9800),
              Color(0xFFFB6D0A),
              Color(0xFFE85D04),
            ],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -60,
              right: -60,
              child: _decorativeCircle(220, Colors.white.withValues(alpha: 0.08)),
            ),
            Positioned(
              bottom: -40,
              left: -50,
              child: _decorativeCircle(180, Colors.white.withValues(alpha: 0.06)),
            ),
            SafeArea(
              child: Column(
                children: [
                  if (alertCard != null) alertCard!,
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: ScaleTransition(
                          scale: _animation,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 104,
                                height: 104,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: 0.18),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.18),
                                      blurRadius: 30,
                                      offset: const Offset(0, 12),
                                    ),
                                  ],
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.explore_outlined,
                                    size: 44,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 32),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                transitionBuilder:
                                    (Widget child, Animation<double> animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0.0, 0.3),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
                                child: Text(
                                  headerText,
                                  key: ValueKey<String>(headerText),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: 0.3,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 8,
                                        color: Colors.black26,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child: Text(
                                  subtitleText,
                                  key: ValueKey<String>(subtitleText),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white.withValues(alpha: 0.85),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 44),
                              Row(
                                children: [
                                  Expanded(
                                    child: LanguageButton(
                                      language: "Français",
                                      isSelected: selectedLanguage == 'fr',
                                      onTap: () => _selectLanguage('fr'),
                                      flagEmoji: "🇫🇷",
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: LanguageButton(
                                      language: "عربية",
                                      isSelected: selectedLanguage == 'ar',
                                      onTap: () => _selectLanguage('ar'),
                                      flagEmoji: "🇲🇷",
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _saveLanguageAndNavigate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFFFF9800),
                          elevation: 6,
                          shadowColor: Colors.black.withValues(alpha: 0.2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            continueButtonText,
                            key: ValueKey<String>(continueButtonText),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _decorativeCircle(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

// Language selection card matching the "Language Page" design.
class LanguageButton extends StatelessWidget {
  final String language;
  final bool isSelected;
  final VoidCallback onTap;
  final String flagEmoji;

  const LanguageButton({
    super.key,
    required this.language,
    required this.isSelected,
    required this.onTap,
    required this.flagEmoji,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutQuint,
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.white : Colors.transparent,
            width: 3,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected
                    ? const Color(0xFFFFF3E0)
                    : Colors.white.withValues(alpha: 0.15),
              ),
              child: Center(
                child: Text(flagEmoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              language,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: isSelected ? const Color(0xFF2E3A59) : Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? const Color(0xFFFF9800) : Colors.transparent,
                border: isSelected
                    ? null
                    : Border.all(color: Colors.white.withValues(alpha: 0.6), width: 2),
              ),
              child: isSelected
                  ? const Icon(Icons.check, size: 13, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
