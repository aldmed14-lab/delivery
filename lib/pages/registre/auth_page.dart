import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_application_1/pages/client/home_shell.dart';
import 'package:flutter_application_1/utils/connection.dart';
import 'package:flutter_application_1/utils/connection_ui.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

class AuthPage extends StatefulWidget {
  final String language;

  const AuthPage(this.language, {super.key});

  @override
  _AuthPageState createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _phoneController1 = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  bool isauthing = true;
  double _rotationTurns = 0.0;
  bool fontcard = true;

  String? _pendingPhone;
  Timer? _timer;
  bool _isDialogOpen = false;
  bool _isLoading = false;
  bool _isVerifyingCode = false;
  final InternetConnectionService _connectionService =
      InternetConnectionService();
  bool _hasInternetConnection = true;
  StreamSubscription<bool>? _connectionSub;

  /// True from the moment "Se connecter"/"S'inscrire" is tapped (sending
  /// the OTP) through verifying the entered code - covers both network
  /// calls (sendOtp and verifyOtp), not just whichever one is in flight
  /// right now, so the page stays blocked across the whole flow.
  bool get _isBusy => _isLoading || _isVerifyingCode;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeIn,
      ),
    );
    _animationController.forward();
    _loadPreferences();

    _connectionSub =
        _connectionService.connectionStream.listen((hasConnection) {
      if (mounted) {
        setState(() {
          _hasInternetConnection = hasConnection;
        });
        if (!hasConnection) {
          _showSnack(TranslationHelper.get('no_internet'));
        }
      }
    });
  }

  Future<void> _loadPreferences() async {
    if (!_hasInternetConnection) {
      _showSnack(TranslationHelper.get('no_internet'));
      return;
    }
    try {
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get('langnotfound'));
      }
    }
  }

  Future<void> _startPhoneAuth() async {
    // Synchronous re-entrancy guard: _isLoading only takes visual effect on
    // the button after the next rebuild, which leaves a brief window where a
    // fast double-tap fires this again before that happens.
    if (_isLoading || !mounted) return;
    if (!_hasInternetConnection) {
      _showSnack(TranslationHelper.get('no_internet'));
      return;
    }

    final phone = _phoneController.text.trim();
    if (phone.length != 8) {
      _showSnack(TranslationHelper.get('phoneerror'));
      return;
    }

    setState(() => _isLoading = true);

    try {
      isauthing = false;
      final userQuery = await FirebaseFirestore.instance
          .collection('users')
          .where('phone', isEqualTo: phone)
          .get();

      if (userQuery.docs.isEmpty) {
        if (mounted) {
          _showSnack(TranslationHelper.get('notfound'));
          setState(() {
            isauthing = true;
            _isLoading = false;
          });
        }
        return;
      }

      if (userQuery.docs.first.data()['active'] == false) {
        if (mounted) {
          _showSnack(TranslationHelper.get('account_blocked'));
          setState(() {
            isauthing = true;
            _isLoading = false;
          });
        }
        return;
      }

      await _sendOtp(phone, "old");
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        setState(() {
          isauthing = true;
          _isLoading = false;
        });
      }
    }
  }

  /// Requests a WhatsApp OTP for [phone] via the `sendOtp` cloud function and,
  /// once it's been sent, opens the code-entry dialog. [type] is "old" or
  /// "new" and is threaded through to `_handlePostAuth` afterwards.
  Future<void> _sendOtp(String phone, String type) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('sendOtp')
          .call({'phone': phone});

      if (mounted) {
        _pendingPhone = phone;
        setState(() => _isLoading = false);
        _showCodeDialog(type);
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        _showSnack(_sendOtpErrorMessage(e));
        setState(() {
          isauthing = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        setState(() {
          isauthing = true;
          _isLoading = false;
        });
      }
    }
  }

  String _sendOtpErrorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'invalid-argument':
        return TranslationHelper.get('phoneerror');
      case 'resource-exhausted':
        return TranslationHelper.get('otp_rate_limited');
      default:
        return TranslationHelper.get('error');
    }
  }

  String _verifyOtpErrorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'invalid-argument':
        return TranslationHelper.get('Invalid');
      case 'not-found':
      case 'deadline-exceeded':
        return TranslationHelper.get('expired');
      case 'resource-exhausted':
        return TranslationHelper.get('too_many_attempts');
      default:
        return TranslationHelper.get('error');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ConnectionDialog.show(context, language: widget.language, message: msg);
  }

  void _showCodeDialog(String type) {
    if (_isDialogOpen || !mounted) return;
    _isDialogOpen = true;

    final codeController = TextEditingController();
    Timer? localTimer;
    int localSeconds = 300;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return WillPopScope(
          onWillPop: () async {
            localTimer?.cancel();
            _isDialogOpen = false;
            return true;
          },
          child: StatefulBuilder(
            builder: (context, setStateDialog) {
              localTimer ??=
                  Timer.periodic(const Duration(seconds: 1), (timer) {
                if (!mounted) {
                  timer.cancel();
                  return;
                }
                setStateDialog(() {
                  localSeconds--;
                  if (localSeconds <= 0) {
                    timer.cancel();
                    if (mounted) {
                      Navigator.of(context).pop();
                      _isDialogOpen = false;
                      isauthing = true;
                      _showSnack(TranslationHelper.get('expired'));
                    }
                  }
                });
              });

              return Dialog(
                insetPadding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                elevation: 10,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: widget.language == "ar"
                            ? [
                                Text(
                                  TranslationHelper.get('verification_code'),
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF2E3A59),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF3D5CFF)
                                        .withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.lock_outline,
                                    color: Color(0xFF3D5CFF),
                                    size: 26,
                                  ),
                                ),
                              ]
                            : [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF3D5CFF)
                                        .withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.lock_outline,
                                    color: Color(0xFF3D5CFF),
                                    size: 26,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Text(
                                  TranslationHelper.get('verification_code'),
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
                        TranslationHelper.get('codeinfo'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          color: Color(0xFF677489),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 14,
                            height: 14,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF25D366),
                            ),
                            child: Center(
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            TranslationHelper.get('received_whatsapp'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF25D366),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F8FA),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFFE1E5EB),
                            width: 1,
                          ),
                        ),
                        child: TextField(
                          controller: codeController,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          obscureText: true,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 26,
                            letterSpacing: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2E3A59),
                          ),
                          decoration: InputDecoration(
                            hintText: '······',
                            hintStyle: TextStyle(
                              color: const Color(0xFF677489)
                                  .withValues(alpha: 0.5),
                              letterSpacing: 10,
                            ),
                            counterText: '',
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 16, horizontal: 16),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: localSeconds < 60
                              ? const Color(0xFFFFF0F0)
                              : const Color(0xFFF7F8FA),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.timer,
                              color: localSeconds < 60
                                  ? const Color(0xFFFF3B30)
                                  : const Color(0xFF677489),
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "${TranslationHelper.get('authtime')} ${_formatTime(localSeconds)}",
                              style: TextStyle(
                                color: localSeconds < 60
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF677489),
                                fontWeight: FontWeight.w500,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 36),
                      Row(
                          children: widget.language == "fr"
                              ? [
                                  Expanded(
                                    child: TextButton(
                                      onPressed: () {
                                        localTimer?.cancel();
                                        Navigator.of(context).pop();
                                        _isDialogOpen = false;
                                      },
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        backgroundColor:
                                            const Color(0xFFF7F8FA),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: Text(
                                        TranslationHelper.get('cancel'),
                                        style: TextStyle(
                                          color: Color(0xFF677489),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: () {
                                        localTimer?.cancel();
                                        Navigator.of(context).pop();
                                        _submitSmsCode(
                                            codeController.text, type);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        backgroundColor:
                                            const Color(0xFF3D5CFF),
                                        foregroundColor: Colors.white,
                                        elevation: 2,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: Text(
                                        TranslationHelper.get('verify'),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                ]
                              : [
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: () {
                                        localTimer?.cancel();
                                        Navigator.of(context).pop();
                                        _submitSmsCode(
                                            codeController.text, type);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        backgroundColor:
                                            const Color(0xFF3D5CFF),
                                        foregroundColor: Colors.white,
                                        elevation: 2,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: Text(
                                        TranslationHelper.get('verify'),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: TextButton(
                                      onPressed: () {
                                        localTimer?.cancel();
                                        Navigator.of(context).pop();
                                        _isDialogOpen = false;
                                        isauthing = true;
                                        setState(() {});
                                      },
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        backgroundColor:
                                            const Color(0xFFF7F8FA),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: Text(
                                        TranslationHelper.get('cancel'),
                                        style: TextStyle(
                                          color: Color(0xFF677489),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                ]),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    ).then((_) {
      localTimer?.cancel();
      _isDialogOpen = false;
    });
  }

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  Future<void> _submitSmsCode(String smsCode, String type) async {
    // Guards the actual network call, not just the dialog's button - the
    // dialog closes on tap before this even starts, so this is what
    // actually stops a fast resubmission from firing a second verifyOtp
    // call while the first is still in flight.
    if (_isVerifyingCode) return;
    if (_pendingPhone == null || smsCode.length != 6 || !mounted) {
      if (mounted) _showSnack(TranslationHelper.get('Invalid'));
      return;
    }

    setState(() => _isVerifyingCode = true);
    try {
      final result =
          await FirebaseFunctions.instance.httpsCallable('verifyOtp').call(
        {'phone': _pendingPhone, 'code': smsCode},
      );
      final token = result.data['token'] as String;
      final userCred = await _auth.signInWithCustomToken(token);
      _timer?.cancel();
      if (mounted) {
        _isDialogOpen = false;
        await _handlePostAuth(userCred.user, type);
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        _showSnack(_verifyOtpErrorMessage(e));
      }
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'Invalid'));
      }
    } finally {
      if (mounted) {
        setState(() => _isVerifyingCode = false);
      } else {
        _isVerifyingCode = false;
      }
    }
  }

  Future<void> _handlePostAuth(User? user, String type) async {
    if (user == null || !mounted) return;
    final phone = _phoneController1.text.trim();
    final name = _nameController.text.trim();

    try {
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        if (type == "old") {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .update({'fmc': fcmToken});
        } else {
          FirebaseFirestore.instance
              .collection('users') // collection name
              .doc(user.uid)
              .set({
            'name': name,
            'phone': phone,
            'active': true,
            'blocinfo': 0,
            'fmc': fcmToken,
            'wallet_balance': 0,
          });
        }
      }

      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => HomeShell(widget.language)));
      }
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connectionSub?.cancel();
    _animationController.dispose();
    _phoneController.dispose();
    _isDialogOpen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Blocks every tap on the page - phone/name fields, the
          // sign-in/sign-up switch, the submit button - the moment sendOtp
          // or verifyOtp is in flight, until it actually resolves (success
          // or error), not just the submit button itself.
          AbsorbPointer(
            absorbing: _isBusy,
            child: Stack(
              children: [
                SizedBox(
                  width: MediaQuery.of(context).size.width,
                  height: MediaQuery.of(context).size.height,
                  child: Image.asset(
                    'assets/background1.png',
                    fit: BoxFit.fill,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
                _buildAuthCard(),
              ],
            ),
          ),
          if (_isBusy)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.15),
                child: const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFF9800)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAuthCard() {
    return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SingleChildScrollView(
                  reverse: true,
                  child: AnimatedRotation(
                    turns: _rotationTurns,
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOut,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 50,
                            offset: const Offset(0, 20),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: fontcard
                              ? [
                                  FadeTransition(
                                    opacity: _fadeAnimation,
                                    child: Column(
                                      children: [
                                        RichText(
                                          textAlign: TextAlign.center,
                                          text: TextSpan(
                                            children: [
                                              TextSpan(
                                                text: TranslationHelper.get(
                                                    'welcome'),
                                                style: const TextStyle(
                                                  fontSize: 32,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF2E3A59),
                                                  letterSpacing: 0.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Container(
                                          width: 70,
                                          height: 4,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF3D5CFF),
                                            borderRadius:
                                                BorderRadius.circular(2),
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                        Text(
                                          TranslationHelper.get('sign'),
                                          style: const TextStyle(
                                            fontSize: 20,
                                            color: Color(0xFF677489),
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                        const SizedBox(height: 30),
                                        Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF7F8FA),
                                            borderRadius:
                                                BorderRadius.circular(15),
                                            border: Border.all(
                                              color: const Color(0xFFE1E5EB),
                                              width: 1,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 15),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: TextField(
                                                    controller:
                                                        _phoneController,
                                                    keyboardType:
                                                        TextInputType.number,
                                                    maxLength: 8,
                                                    enabled: isauthing,
                                                    textAlign:
                                                        widget.language == "ar"
                                                            ? TextAlign.right
                                                            : TextAlign.left,
                                                    decoration: InputDecoration(
                                                      hintText:
                                                          TranslationHelper.get(
                                                              'phone_hint'),
                                                      hintStyle: TextStyle(
                                                        color: const Color(
                                                                0xFF677489)
                                                            .withValues(
                                                                alpha: 0.7),
                                                      ),
                                                      border: InputBorder.none,
                                                      counterText: '',
                                                      contentPadding:
                                                          const EdgeInsets.only(
                                                              left: 15),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                        GestureDetector(
                                          onTap: () {
                                            _isLoading
                                                ? null
                                                : setState(() {
                                                    _rotationTurns += 1.0;
                                                    fontcard = false;
                                                  });
                                          },
                                          child: Text(
                                            TranslationHelper.get('new_user'),
                                            style: const TextStyle(
                                              fontSize: 20,
                                              color: Color.fromARGB(
                                                  255, 0, 98, 255),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 30),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 55,
                                          child: ElevatedButton(
                                            onPressed: _isLoading
                                                ? null
                                                : _startPhoneAuth,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  const Color.fromARGB(
                                                      255, 255, 166, 0),
                                              foregroundColor: Colors.white,
                                              elevation: 3,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(15),
                                              ),
                                            ),
                                            child: _isLoading
                                                ? const CircularProgressIndicator(
                                                    color: Colors.white,
                                                    strokeWidth: 2.5,
                                                  )
                                                : Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Text(
                                                        TranslationHelper.get(
                                                            'welcome'),
                                                        style: const TextStyle(
                                                          fontSize: 18,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                    ],
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ]
                              : [
                                  FadeTransition(
                                    opacity: _fadeAnimation,
                                    child: Column(
                                      children: [
                                        RichText(
                                          textAlign: TextAlign.center,
                                          text: TextSpan(
                                            children: [
                                              TextSpan(
                                                text: TranslationHelper.get(
                                                    'new_user'),
                                                style: const TextStyle(
                                                  fontSize: 32,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF2E3A59),
                                                  letterSpacing: 0.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          TranslationHelper.get('sign'),
                                          style: const TextStyle(
                                            fontSize: 20,
                                            color: Color(0xFF677489),
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF7F8FA),
                                            borderRadius:
                                                BorderRadius.circular(15),
                                            border: Border.all(
                                              color: const Color(0xFFE1E5EB),
                                              width: 1,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 15),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: TextField(
                                                    controller:
                                                        _nameController, // <-- Define this in your state
                                                    keyboardType:
                                                        TextInputType.text,
                                                    enabled: isauthing,
                                                    maxLength: 15,
                                                    textAlign:
                                                        widget.language == "ar"
                                                            ? TextAlign.right
                                                            : TextAlign.left,
                                                    decoration: InputDecoration(
                                                      hintText:
                                                          TranslationHelper.get(
                                                              'name_hint'), // You can use a custom key
                                                      hintStyle: TextStyle(
                                                        color: const Color(
                                                                0xFF677489)
                                                            .withValues(
                                                                alpha: 0.7),
                                                      ),
                                                      border: InputBorder.none,
                                                      counterText: '',
                                                      contentPadding:
                                                          const EdgeInsets.only(
                                                              left: 15),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 15),
                                        Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF7F8FA),
                                            borderRadius:
                                                BorderRadius.circular(15),
                                            border: Border.all(
                                              color: const Color(0xFFE1E5EB),
                                              width: 1,
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 15),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: TextField(
                                                    controller:
                                                        _phoneController1,
                                                    keyboardType:
                                                        TextInputType.number,
                                                    maxLength: 8,
                                                    enabled: isauthing,
                                                    textAlign:
                                                        widget.language == "ar"
                                                            ? TextAlign.right
                                                            : TextAlign.left,
                                                    decoration: InputDecoration(
                                                      hintText:
                                                          TranslationHelper.get(
                                                              'phone_hint'),
                                                      hintStyle: TextStyle(
                                                        color: const Color(
                                                                0xFF677489)
                                                            .withValues(
                                                                alpha: 0.7),
                                                      ),
                                                      border: InputBorder.none,
                                                      counterText: '',
                                                      contentPadding:
                                                          const EdgeInsets.only(
                                                              left: 15),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                        const SizedBox(height: 20),
                                        GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _isLoading
                                                  ? null
                                                  : setState(() {
                                                      _rotationTurns += 1.0;
                                                      fontcard = true;
                                                    });
                                            });
                                          },
                                          child: Text(
                                            TranslationHelper.get(
                                                'have_acount'),
                                            style: const TextStyle(
                                              fontSize: 20,
                                              color: Color.fromARGB(
                                                  255, 0, 98, 255),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 30),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 55,
                                          child: ElevatedButton(
                                            onPressed: _isLoading
                                                ? null
                                                : _startPhoneAuth1,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  const Color.fromARGB(
                                                      255, 255, 166, 0),
                                              foregroundColor: Colors.white,
                                              elevation: 3,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(15),
                                              ),
                                            ),
                                            child: _isLoading
                                                ? const CircularProgressIndicator(
                                                    color: Colors.white,
                                                    strokeWidth: 2.5,
                                                  )
                                                : Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Text(
                                                        TranslationHelper.get(
                                                            'welcome'),
                                                        style: const TextStyle(
                                                          fontSize: 18,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                    ],
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
  }

  Future<void> _startPhoneAuth1() async {
    if (_isLoading || !mounted) return;
    if (!_hasInternetConnection) {
      _showSnack(TranslationHelper.get('no_internet'));
      return;
    }

    final phone = _phoneController1.text.trim();
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showSnack(TranslationHelper.get('nameerror'));
      return;
    }
    if (phone.length != 8) {
      _showSnack(TranslationHelper.get('phoneerror'));
      return;
    }

    setState(() => _isLoading = true);

    try {
      isauthing = false;
      final userQuery = await FirebaseFirestore.instance
          .collection('users')
          .where('phone', isEqualTo: phone)
          .get();

      if (userQuery.docs.isNotEmpty) {
        if (mounted) {
          _showSnack(TranslationHelper.get('userexist'));
          setState(() {
            isauthing = true;
            _isLoading = false;
          });
        }
        return;
      }

      await _sendOtp(phone, "new");
    } catch (e) {
      if (mounted) {
        _showSnack(TranslationHelper.get(
            isConnectivityError(e) ? 'no_internet' : 'error'));
        setState(() {
          isauthing = true;
          _isLoading = false;
        });
      }
    }
  }
}
