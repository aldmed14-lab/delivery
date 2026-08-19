import 'package:flutter/material.dart';

// Stub for the "Store Work Time Page" design (opening hours editor).
class StoreWorkTimePage extends StatefulWidget {
  final String language;
  const StoreWorkTimePage(this.language, {super.key});

  @override
  State<StoreWorkTimePage> createState() => _StoreWorkTimePageState();
}

class _StoreWorkTimePageState extends State<StoreWorkTimePage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Work Time Page')),
    );
  }
}
