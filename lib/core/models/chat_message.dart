// File: lib/core/models/chat_message.dart
enum MessageSender { user, ai }

class ChatMessage {
  final String text;
  final MessageSender sender;
  final DateTime timestamp;
  final bool isThinking; // Flag for AI "thinking" indicator

  ChatMessage({
    required this.text,
    required this.sender,
    required this.timestamp,
    this.isThinking = false,
  });
}