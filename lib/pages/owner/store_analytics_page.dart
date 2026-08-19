import 'package:flutter/material.dart';

// Stub for the "Store Analytics Page" design.
class StoreAnalyticsPage extends StatefulWidget {
  final String language;
  const StoreAnalyticsPage(this.language, {super.key});

  @override
  State<StoreAnalyticsPage> createState() => _StoreAnalyticsPageState();
}

class _StoreAnalyticsPageState extends State<StoreAnalyticsPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Analytics Page')),
    );
  }
}
