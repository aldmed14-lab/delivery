import 'package:flutter/material.dart';

// Stub for the "Store Item Edit Page" design (add/edit a single menu item).
class StoreItemEditPage extends StatefulWidget {
  final String language;
  const StoreItemEditPage(this.language, {super.key});

  @override
  State<StoreItemEditPage> createState() => _StoreItemEditPageState();
}

class _StoreItemEditPageState extends State<StoreItemEditPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Item Edit Page')),
    );
  }
}
