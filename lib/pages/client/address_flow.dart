import 'package:flutter/material.dart';
import 'package:flutter_application_1/pages/client/location_picker_sheet.dart';
import 'package:flutter_application_1/pages/client/select_location_page.dart';
import 'package:flutter_application_1/utils/city_resolver.dart';
import 'package:flutter_application_1/utils/connection_dialog.dart';
import 'package:flutter_application_1/utils/internet_connection_service.dart';
import 'package:flutter_application_1/utils/location_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// The address flows shared by the home header and checkout
/// (lib/note.txt LOCATION SYSTEM): pick on the map -> label -> SAVED, and
/// the address picker sheet.
class AddressFlow {
  AddressFlow._();

  static void _error(BuildContext context, String language, String key) {
    if (!context.mounted) return;
    ConnectionDialog.show(context,
        language: language, message: TranslationHelper.get(key));
  }

  /// Map + pin + label -> a new saved address, made active + default.
  /// Null when the user backs out (or saving failed - already reported).
  static Future<SavedAddress?> addAddress(
    BuildContext context,
    String language, {
    LatLng? initialPoint,
    bool canCancel = true,
  }) async {
    final problem = await CityResolver.locationProblem();
    if (!context.mounted) return null;
    if (problem != null) {
      _error(context, language, problem);
      return null;
    }

    final picked = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SelectMapPage(language,
            canCancel: canCancel, initialPoint: initialPoint),
      ),
    );
    if (!context.mounted || picked is! Map) return null;

    final label = await _promptLabel(context, language);
    if (!context.mounted || label == null) return null;

    try {
      return await LocationService.instance.addAddress(
        label: label,
        lat: (picked['lat'] as num).toDouble(),
        lng: (picked['lng'] as num).toDouble(),
      );
    } on AddressLimitReached {
      _error(context, language, 'max_addresses_reached');
    } on AddressOutsideCities {
      _error(context, language, 'city_not_available');
    } catch (e) {
      _error(context, language,
          isConnectivityError(e) ? 'no_internet' : 'error');
    }
    return null;
  }

  /// Use the device's current position for browsing (the point isn't
  /// saved) and make "current location" the default, so home re-reads the
  /// GPS on every start. Returns false (after telling the user why) when
  /// it couldn't.
  static Future<bool> useCurrentLocation(
      BuildContext context, String language) async {
    final result = await CityResolver.resolveFromDevice();
    if (!context.mounted) return false;
    switch (result.status) {
      case CityResolveStatus.resolved:
        try {
          await LocationService.instance.useCurrentAsDefault(
              lat: result.lat!, lng: result.lng!, cityId: result.cityId!);
        } catch (e) {
          if (context.mounted) {
            _error(context, language,
                isConnectivityError(e) ? 'no_internet' : 'error');
          }
          return false;
        }
        return true;
      case CityResolveStatus.outOfZone:
        _error(context, language, 'not_in_delivery_zone');
        return false;
      case CityResolveStatus.unavailable:
        _error(context, language, 'location_lookup_failed');
        return false;
    }
  }

  /// The address picker sheet; applies whatever the user chose.
  /// [allowCurrentLocation] false at checkout (it needs a saved address).
  static Future<void> openPicker(
    BuildContext context,
    String language, {
    bool allowCurrentLocation = true,
  }) async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LocationPickerSheet(
        language: language,
        allowCurrentLocation: allowCurrentLocation,
      ),
    );
    if (!context.mounted || result == null) return;

    if (result == 'add') {
      final active = LocationService.instance.active;
      await addAddress(context, language,
          initialPoint:
              active == null ? null : LatLng(active.lat, active.lng));
    } else if (result == 'current') {
      await useCurrentLocation(context, language);
    } else if (result is SavedAddress) {
      try {
        await LocationService.instance.select(result);
      } catch (e) {
        if (!context.mounted) return;
        _error(context, language,
            isConnectivityError(e) ? 'no_internet' : 'error');
      }
    }
  }

  static Future<String?> _promptLabel(BuildContext context, String language) {
    final controller = TextEditingController();
    final isArabic = language == 'ar';
    return showDialog<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(TranslationHelper.get('add_address')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final key in const [
                      'address_label_home',
                      'address_label_work'
                    ])
                      ActionChip(
                        label: Text(TranslationHelper.get(key)),
                        onPressed: () => setState(() =>
                            controller.text = TranslationHelper.get(key)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: TranslationHelper.get('address_name_hint'),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(TranslationHelper.get('cancel')),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800),
                  foregroundColor: Colors.white,
                ),
                onPressed: controller.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, controller.text.trim()),
                child: Text(TranslationHelper.get('save')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
