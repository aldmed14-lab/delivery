import 'package:flutter/material.dart';

// Stub for the "Delivery Finance Page" design (driver's earnings).
class DeliveryFinancePage extends StatefulWidget {
  final String language;
  const DeliveryFinancePage(this.language, {super.key});

  @override
  State<DeliveryFinancePage> createState() => _DeliveryFinancePageState();
}

class _DeliveryFinancePageState extends State<DeliveryFinancePage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Delivery Finance Page')),
    );
  }
}
