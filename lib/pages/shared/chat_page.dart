import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_1/utils/translation_helper.dart';

/// Chat between exactly two participants of one order (the customer and the
/// assigned driver - see startOrderConversation, a Cloud Function). Messages
/// are a plain client read/write (`conversations/{id}/messages`, allowed by
/// the security rules for any signed-in participant) - there's no money or
/// state transition riding on chat text, unlike everything else this session
/// moved server-side.
class ChatPage extends StatefulWidget {
  final String language;
  final String conversationId;
  final String otherName;
  const ChatPage(this.language, this.conversationId, this.otherName,
      {super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _firestore = FirebaseFirestore.instance;
  final _uid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  bool get _isArabic => widget.language == 'ar';

  late final DocumentReference<Map<String, dynamic>> _conversationRef =
      _firestore.collection('conversations').doc(widget.conversationId);

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream =
      _conversationRef.collection('messages').orderBy('created_at').snapshots();

  // Resolved once from `participant_types` (lib/map.txt) - which of "user"
  // or "delivery" this signed-in account is on THIS conversation, so every
  // message it sends is correctly attributed regardless of which role
  // opened the page.
  String? _senderType;

  @override
  void initState() {
    super.initState();
    _conversationRef.get().then((snap) {
      if (!mounted) return;
      final types =
          (snap.data()?['participant_types'] as Map?)?.cast<String, dynamic>();
      setState(() => _senderType = types?[_uid] as String? ?? 'user');
    });
    _markRead();
  }

  // `conversations.last_read` (lib/map.txt) was already in the schema but
  // nothing ever wrote to it - stamp our own entry on open and whenever a
  // new message comes in while this page is up, so an unread-badge list
  // elsewhere has real data to compare against.
  void _markRead() {
    _conversationRef.set({
      'last_read': {_uid: FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await _conversationRef.collection('messages').add({
      'sender_id': _uid,
      'sender_type': _senderType ?? 'user',
      'message_type': 'text',
      'message': text,
      'created_at': FieldValue.serverTimestamp(),
    });
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  bool _isSameDay(Timestamp a, Timestamp? b) {
    if (b == null) return false;
    final da = a.toDate();
    final db = b.toDate();
    return da.year == db.year && da.month == db.month && da.day == db.day;
  }

  @override
  Widget build(BuildContext context) {
    final displayName = widget.otherName.isNotEmpty
        ? widget.otherName
        : TranslationHelper.get('chat_page_title');
    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0.5,
          foregroundColor: const Color(0xFF2E3A59),
          titleSpacing: 0,
          title: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFFFFF1DE),
                child: Text(
                  displayName.trim().isNotEmpty
                      ? displayName.trim()[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFF9800),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2E3A59),
                  ),
                ),
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _messagesStream,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snapshot.data!.docs;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollController.hasClients) {
                      _scrollController
                          .jumpTo(_scrollController.position.maxScrollExtent);
                    }
                  });
                  if (docs.isNotEmpty) _markRead();
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final data = docs[index].data();
                      final isMine = data['sender_id'] == _uid;
                      final timestamp = data['created_at'] as Timestamp?;
                      final previousTimestamp = index == 0
                          ? null
                          : docs[index - 1].data()['created_at'] as Timestamp?;
                      final showDateDivider = timestamp != null &&
                          !_isSameDay(timestamp, previousTimestamp);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showDateDivider)
                            _DateDivider(timestamp: timestamp),
                          _MessageBubble(
                            text: data['message'] as String? ?? '',
                            isMine: isMine,
                            timestamp: timestamp,
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFE9ECF2)),
                ),
                child: TextField(
                  controller: _controller,
                  textDirection:
                      _isArabic ? TextDirection.rtl : TextDirection.ltr,
                  decoration: InputDecoration(
                    hintText: TranslationHelper.get('chat_input_hint'),
                    hintStyle:
                        const TextStyle(color: Color(0xFF9AA1AC), fontSize: 14),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  onSubmitted: (_) => _send(),
                  textInputAction: TextInputAction.send,
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: _send,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    color: Color(0xFFFF9800), shape: BoxShape.circle),
                child: Icon(
                  _isArabic ? Icons.send_rounded : Icons.send_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Centered "Aujourd'hui" / date pill inserted before the first message of
// each new calendar day, same pattern as most chat apps (and the reference
// design this page was matched to).
class _DateDivider extends StatelessWidget {
  final Timestamp timestamp;
  const _DateDivider({required this.timestamp});

  String _label() {
    final date = timestamp.toDate();
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return TranslationHelper.get('chat_today');
    }
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFFEDEFF3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _label(),
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8A90A0),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String text;
  final bool isMine;
  final Timestamp? timestamp;

  const _MessageBubble(
      {required this.text, required this.isMine, required this.timestamp});

  String _timeLabel() {
    final date = timestamp?.toDate();
    if (date == null) return '';
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    // A small "tail" corner (the side nearest the sender's edge of the
    // screen) keeps each bubble visually anchored to who sent it, matching
    // the reference design instead of the fully-symmetric rounding before.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMine ? 16 : 4),
      bottomRight: Radius.circular(isMine ? 4 : 16),
    );
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMine ? const Color(0xFFFF9800) : Colors.white,
                borderRadius: radius,
                boxShadow: isMine
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  color: isMine ? Colors.white : const Color(0xFF2E3A59),
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _timeLabel(),
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF9AA1AC)),
            ),
          ],
        ),
      ),
    );
  }
}
