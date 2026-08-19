import 'package:flutter/material.dart';

// Stub for the "Delivery Order Detail Page" design.
class DeliveryOrderDetailPage extends StatefulWidget {
  final String language;
  const DeliveryOrderDetailPage(this.language, {super.key});

  @override
  State<DeliveryOrderDetailPage> createState() =>
      _DeliveryOrderDetailPageState();
}

class _DeliveryOrderDetailPageState extends State<DeliveryOrderDetailPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Delivery Order Detail Page')),
    );
  }
}
