import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';

/// App-wide singleton that tracks real internet reachability (not just
/// "connected to a WiFi/mobile network with no internet behind it").
///
/// Backed by [InternetConnectionChecker], which already handles the
/// multi-address probing, timeouts and connectivity-change monitoring that
/// used to be hand-rolled here. This class only adds a simple `bool` stream
/// on top, since callers care about "online vs offline", not the richer
/// [InternetConnectionStatus] enum.
///
/// This is a true app-lifetime singleton: nothing should ever call
/// `dispose()` on it from a page's `State.dispose()` — doing that used to
/// kill connectivity monitoring for the rest of the app the first time any
/// screen using it was popped.
class InternetConnectionService {
  static final InternetConnectionService _instance =
      InternetConnectionService._internal();
  factory InternetConnectionService() => _instance;

  InternetConnectionService._internal() {
    _checker.onStatusChange.listen((status) {
      _emitStatus(status == InternetConnectionStatus.connected ||
          status == InternetConnectionStatus.slow);
    });
    checkNow();
  }

  final InternetConnectionChecker _checker = InternetConnectionChecker.instance;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  bool _lastStatus = true;
  bool get lastKnownStatus => _lastStatus;

  /// Emits only when the online/offline status actually changes.
  Stream<bool> get connectionStream => _controller.stream.distinct();

  void _emitStatus(bool status) {
    _lastStatus = status;
    if (!_controller.isClosed) {
      _controller.add(status);
    }
  }

  /// Runs an on-demand check and emits the result on [connectionStream].
  Future<bool> checkNow() async {
    final status = await _checker.hasConnection;
    _emitStatus(status);
    return status;
  }
}

/// Whether an error thrown by Firestore/Auth/HTTP calls indicates a
/// connectivity problem (as opposed to a genuine application/server error).
///
/// Centralizing this classification is the whole point of this file: no
/// call site should be guessing at `e.toString().contains('network')`
/// anymore.
bool isConnectivityError(Object error) {
  if (error is SocketException || error is TimeoutException) return true;

  if (error is FirebaseException) {
    const connectivityCodes = {
      'unavailable',
      'deadline-exceeded',
      'network-request-failed',
      'unknown',
    };
    return connectivityCodes.contains(error.code);
  }

  if (error is FirebaseAuthException) {
    const connectivityCodes = {
      'network-request-failed',
      'timeout',
    };
    return connectivityCodes.contains(error.code);
  }

  final message = error.toString().toLowerCase();
  return message.contains('socketexception') ||
      message.contains('network') ||
      message.contains('timeout') ||
      message.contains('failed host lookup');
}
