import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/utils/translation_helper.dart';

/// Bottom sheet listing the user's saved addresses (`users/{uid}/locations`),
/// shown when the header's location label is tapped. Returns to the caller
/// either:
/// - a `Map` with the picked location's `city`/`lat`/`lng`/`name`, or
/// - the string `"add"` if the user tapped "+ Add address", or
/// - `null` if dismissed without a choice.
class LocationPickerSheet extends StatelessWidget {
  final String uid;
  final String language;
  final String? activeCity;
  final String? activeLocationName;

  const LocationPickerSheet({
    required this.uid,
    required this.language,
    required this.activeCity,
    required this.activeLocationName,
    super.key,
  });

  bool get _isArabic => language == 'ar';

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
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
              ListTile(
                leading: const Icon(Icons.my_location,
                    color: Color(0xFFFF9800), size: 20),
                title: Text(
                  TranslationHelper.get('use_current_location'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: Color(0xFF2E3A59),
                  ),
                ),
                onTap: () => Navigator.of(context).pop('current'),
              ),
              Divider(height: 1, color: Colors.grey[200]),
              Flexible(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(uid)
                      .collection('locations')
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFFFF9800),
                          ),
                        ),
                      );
                    }
                    final docs = snapshot.data!.docs;
                    if (docs.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 24),
                        child: Text(
                          TranslationHelper.get('no_saved_addresses'),
                          style: const TextStyle(color: Colors.grey),
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: Colors.grey[200]),
                      itemBuilder: (context, i) {
                        final data = docs[i].data();
                        final city = data['city'] as String? ?? '';
                        final name = data['name'] as String?;
                        final label = (name == null || name.isEmpty)
                            ? '$city, ${TranslationHelper.get('location_now')}'
                            : '$city, $name';
                        final isActive =
                            city == activeCity && name == activeLocationName;

                        return ListTile(
                          title: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFF2E3A59),
                            ),
                          ),
                          trailing: Icon(
                            isActive
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            color: isActive
                                ? const Color(0xFFFF9800)
                                : Colors.grey[350],
                            size: 20,
                          ),
                          onTap: () => Navigator.of(context).pop({
                            'city': city,
                            'lat': data['lat'],
                            'lng': data['lng'],
                            'name': name,
                          }),
                        );
                      },
                    );
                  },
                ),
              ),
              InkWell(
                onTap: () => Navigator.of(context).pop('add'),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
