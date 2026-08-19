import 'package:flutter/material.dart';

// Stub for the "Help Page" design.
class HelpPage extends StatefulWidget {
  final String language;
  const HelpPage(this.language, {super.key});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Help Page')),
    );
  }
}
