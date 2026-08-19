import 'package:flutter/material.dart';

// Stub for the "Chat Page" design.
class ChatPage extends StatefulWidget {
  final String language;
  const ChatPage(this.language, {super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Chat Page')),
    );
  }
}
