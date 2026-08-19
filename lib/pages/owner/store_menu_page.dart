import 'package:flutter/material.dart';

// Stub for the "Store Menu Page" design (owner manages menu items/categories).
class StoreMenuPage extends StatefulWidget {
  final String language;
  const StoreMenuPage(this.language, {super.key});

  @override
  State<StoreMenuPage> createState() => _StoreMenuPageState();
}

class _StoreMenuPageState extends State<StoreMenuPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Menu Page')),
    );
  }
}
