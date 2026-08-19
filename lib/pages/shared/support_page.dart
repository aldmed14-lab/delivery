import 'package:flutter/material.dart';

// Stub for the "Support Page" design.
class SupportPage extends StatefulWidget {
  final String language;
  const SupportPage(this.language, {super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Support Page')),
    );
  }
}
