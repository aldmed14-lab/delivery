import 'package:url_launcher/url_launcher.dart';

/// Opens [value] in the device's browser. Ad `action_value` URLs aren't
/// guaranteed to include a scheme (advertisers may just type
/// "example.com"), so one is assumed when missing.
Future<void> openExternalUrl(String value) async {
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
