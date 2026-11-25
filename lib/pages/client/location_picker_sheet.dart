import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/cities_service.dart';
import 'package:flutter_application_1/utils/location_service.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Address picker (lib/note.txt LOCATION SYSTEM) - the header and checkout
/// use the same sheet. Pops:
/// - a [SavedAddress] the user picked,
/// - `"current"` for "Current location" (browsing only, not saved),
/// - `"add"` for "+ Add address",
/// - null when dismissed.
/// Deleting an address happens right here.
class LocationPickerSheet extends StatelessWidget {
  final String language;

  /// Hide "Current location" - checkout needs a saved address.
  final bool allowCurrentLocation;

  const LocationPickerSheet({
    required this.language,
    this.allowCurrentLocation = true,
    super.key,
  });

  bool get _isArabic => language == 'ar';

  Future<void> _confirmDelete(BuildContext context, SavedAddress a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(TranslationHelper.get('delete_address_title')),
        content: Text(a.label),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(TranslationHelper.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              TranslationHelper.get('delete'),
              style: const TextStyle(color: Color(0xFFE74C3C)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await LocationService.instance.deleteAddress(a.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(TranslationHelper.get('error'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeId = LocationService.instance.active?.addressId;
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          // Material (not a decorated Container) so the ListTile ink
          // splashes below aren't painted over.
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: StreamBuilder<List<SavedAddress>>(
              stream: LocationService.instance.watchAddresses(),
              builder: (context, snapshot) {
                final addresses = snapshot.data;
                final canAdd = addresses != null &&
                    addresses.length < LocationService.maxAddresses;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (allowCurrentLocation) ...[
                      ListTile(
                        leading: const Icon(Icons.my_location,
                            color: Color(0xFFFF9800), size: 20),
                        title: Text(
                          TranslationHelper.get('current_location'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: Color(0xFF2E3A59),
                          ),
                        ),
                        trailing: activeId == null &&
                                LocationService.instance.active != null
                            ? const Icon(Icons.check_circle,
                                color: Color(0xFFFF9800), size: 20)
                            : null,
                        onTap: () => Navigator.of(context).pop('current'),
                      ),
                      Divider(height: 1, color: Colors.grey[200]),
                    ],
                    Flexible(child: _buildList(context, addresses, activeId)),
                    if (canAdd)
                      InkWell(
                        onTap: () => Navigator.of(context).pop('add'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 16),
                          child: Row(
                            children: [
                              const Icon(Icons.add_circle,
                                  color: Color(0xFFFF9800), size: 20),
                              const SizedBox(width: 10),
                              Text(
                                TranslationHelper.get('add_address'),
                                style: const TextStyle(
                                  color: Color(0xFFFF9800),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (addresses != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          TranslationHelper.get('max_addresses_reached',
                              {'max': LocationService.maxAddresses}),
                          style: const TextStyle(
                              color: Color(0xFF9AA1AC), fontSize: 13),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(
      BuildContext context, List<SavedAddress>? addresses, String? activeId) {
    if (addresses == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFFFF9800)),
        ),
      );
    }
    if (addresses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Text(
          TranslationHelper.get('no_saved_addresses'),
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: addresses.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey[200]),
      itemBuilder: (context, i) {
        final a = addresses[i];
        final served = a.isServed;
        final isActive = a.id == activeId;
        final cityName = CitiesService.instance.cityName(a.cityId, language);
        return ListTile(
          enabled: served,
          title: Text(
            a.label,
            style: TextStyle(
              fontSize: 15,
              color: served ? const Color(0xFF2E3A59) : const Color(0xFF9AA1AC),
            ),
          ),
          subtitle: Text(
            served ? cityName : TranslationHelper.get('address_out_of_area'),
            style: TextStyle(
              fontSize: 12,
              color: served ? const Color(0xFF9AA1AC) : const Color(0xFFE74C3C),
            ),
          ),
          leading: Icon(
            isActive ? Icons.check_circle : Icons.circle_outlined,
            color: isActive ? const Color(0xFFFF9800) : Colors.grey[350],
            size: 20,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline,
                color: Color(0xFF9AA1AC), size: 20),
            onPressed: () => _confirmDelete(context, a),
          ),
          onTap: served ? () => Navigator.of(context).pop(a) : null,
        );
      },
    );
  }
}
