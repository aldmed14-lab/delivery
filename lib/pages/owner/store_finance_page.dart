import 'package:flutter/material.dart';

// Stub for the "Store Finance Page" design.
class StoreFinancePage extends StatefulWidget {
  final String language;
  const StoreFinancePage(this.language, {super.key});

  @override
  State<StoreFinancePage> createState() => _StoreFinancePageState();
}

class _StoreFinancePageState extends State<StoreFinancePage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Store Finance Page')),
    );
  }
}
