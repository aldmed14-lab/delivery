import 'package:flutter/material.dart';

// Stub for the "Live Order Page" design (client order tracking).
class LiveOrderPage extends StatefulWidget {
  final String language;
  final String orderId;
  const LiveOrderPage(this.language, this.orderId, {super.key});

  @override
  State<LiveOrderPage> createState() => _LiveOrderPageState();
}

class _LiveOrderPageState extends State<LiveOrderPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Live Order Page')),
    );
  }
}
