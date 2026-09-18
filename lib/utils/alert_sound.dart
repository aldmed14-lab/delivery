import 'package:audioplayers/audioplayers.dart';

/// Plays the bundled "new order/offer" alert tone.
///
/// Replaces `SystemSound.play(SystemSoundType.alert)`, which is silent on
/// Android - there's no matching entry in Android's SoundEffectConstants, so
/// the platform channel call is a no-op there (it only does something on
/// iOS/macOS). A bundled asset played through audioplayers works the same
/// on every platform.
class AlertSound {
  AlertSound._();

  static final AudioPlayer _player = AudioPlayer();

  static Future<void> playOrderAlert() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/order_alert.wav'));
    } catch (_) {
      // Best-effort - a failed alert sound should never crash or block
      // the flow that triggered it.
    }
  }
}
