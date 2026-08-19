import 'package:flutter/material.dart';

// Stub for the "Owner Store Detail Page" design.
class OwnerStoreDetailPage extends StatefulWidget {
  final String language;
  final String storeId;
  const OwnerStoreDetailPage(this.language, this.storeId, {super.key});

  @override
  State<OwnerStoreDetailPage> createState() => _OwnerStoreDetailPageState();
}

class _OwnerStoreDetailPageState extends State<OwnerStoreDetailPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Owner Store Detail Page')),
    );
  }
}
