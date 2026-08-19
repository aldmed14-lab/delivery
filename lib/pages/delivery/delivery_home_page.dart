import 'package:flutter/material.dart';

// Stub for the "Delivery Home Page" design (driver's dashboard).
class DeliveryHomePage extends StatefulWidget {
  final String language;
  const DeliveryHomePage(this.language, {super.key});

  @override
  State<DeliveryHomePage> createState() => _DeliveryHomePageState();
}

class _DeliveryHomePageState extends State<DeliveryHomePage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Delivery Home Page')),
    );
  }
}
