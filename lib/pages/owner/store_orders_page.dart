import 'package:flutter/material.dart';

// Stub for the "Store Orders Page" design (owner accepts/prepares orders).
class StoreOrdersPage extends StatefulWidget {
  final String language;
  const StoreOrdersPage(this.language, {super.key});

  @override
  State<StoreOrdersPage> createState() => _StoreOrdersPageState();
}

class _StoreOrdersPageState extends State<StoreOrdersPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Orders Page')),
    );
  }
}
