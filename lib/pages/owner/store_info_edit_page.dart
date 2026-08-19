import 'package:flutter/material.dart';

// Stub for the "Store Info Edit Page" design (edit store profile info).
class StoreInfoEditPage extends StatefulWidget {
  final String language;
  const StoreInfoEditPage(this.language, {super.key});

  @override
  State<StoreInfoEditPage> createState() => _StoreInfoEditPageState();
}

class _StoreInfoEditPageState extends State<StoreInfoEditPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Info Edit Page')),
    );
  }
}
