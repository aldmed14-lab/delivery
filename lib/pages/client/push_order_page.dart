import 'package:flutter/material.dart';

// Stub for the "Push Order Page" design (checkout / order confirmation).
class PushOrderPage extends StatefulWidget {
  final String language;
  final String uid;
  final String storeId;
  const PushOrderPage(this.language, this.uid, this.storeId, {super.key});

  @override
  State<PushOrderPage> createState() => _PushOrderPageState();
}

class _PushOrderPageState extends State<PushOrderPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Push Order Page')),
    );
  }
}
