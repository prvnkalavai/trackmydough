// File: lib/features/home/home_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/scheduler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

// Import placeholder screens and transaction screen
import '../accounts/accounts_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../insights/insights_screen.dart';
import '../transactions/transaction_list_screen.dart';
import '../../core/services/gemini_service.dart';
import '../../core/models/chat_message.dart';
import '../receipts/receipt_capture_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TextEditingController _chatController = TextEditingController();
  User? _currentUser;
  String _userName = "there";
  final GeminiService _geminiService = GeminiService();
  bool _isProcessingMessage = false;
  final List<ChatMessage> _chatMessages = [];
  final ScrollController _scrollController = ScrollController();
  Timer? _thinkingTimer;
  String _todaySpend = "Loading...";
  String _weekSpend = "Loading...";
  String _monthSpend = "Loading...";
  bool _summariesLoading = true;
  String? _summaryError;
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    _currentUser = _auth.currentUser;
    _loadUserData();
    _fetchSpendingSummaries();
    _initSpeech();
  }

  void _loadUserData() {
    if (_currentUser != null) {
      // Use display name if available, otherwise fallback to email part
      setState(() {
        _userName = _currentUser!.displayName?.isNotEmpty ?? false
            ? _currentUser!.displayName!
            : (_currentUser!.email?.split('@')[0] ??
                "User"); // Extract part before @
      });
      // TODO: Later, fetch display name from Firestore if needed
    }
  }

  @override
  void dispose() {
    _chatController.dispose();
    _scrollController.dispose(); // Dispose scroll controller
    _clearThinkingTimer();
    _speechToText.stop();
    super.dispose();
  }

  // --- Sign Out Logic ---
  Future<void> _signOut() async {
    try {
      await _auth.signOut();
      // AuthGate will handle navigation
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: ${e.toString()}')),
        );
      }
    }
  }

  // --- Navigation Helper ---
  void _navigateTo(Widget screen) {
    // Close the drawer first if it's open
    Navigator.pop(context); // Close drawer
    // Push the new screen
    Navigator.push(context, MaterialPageRoute(builder: (context) => screen));
  }

  void _sendMessage() async {
    final messageText = _chatController.text.trim();
    if (messageText.isEmpty || _isProcessingMessage) return;

    final userMessage = ChatMessage(
      text: messageText,
      sender: MessageSender.user,
      timestamp: DateTime.now(),
    );

    _chatController.clear();
    setState(() {
      _isProcessingMessage = true;
      _chatMessages.add(userMessage); // Add user message immediately
      // Add a temporary "Thinking..." message for the AI
      _chatMessages.add(ChatMessage(
          text: "Thinking...",
          sender: MessageSender.ai,
          timestamp: DateTime.now(),
          isThinking: true));
      _scrollToBottom(); // Scroll after adding messages
    });

    // --- Start a timer to remove "Thinking..." if backend takes too long ---
    _clearThinkingTimer(); // Clear any previous timer
    _thinkingTimer = Timer(const Duration(seconds: 20), () {
      // Adjust timeout as needed
      if (mounted && _isProcessingMessage) {
        // Only remove if still processing
        setState(() {
          _chatMessages.removeWhere((m) => m.isThinking);
          _chatMessages.add(ChatMessage(
              text: "Sorry, that took longer than expected. Please try again.",
              sender: MessageSender.ai,
              timestamp: DateTime.now()));
          _isProcessingMessage = false;
          _scrollToBottom();
        });
      }
    });
    // --------------------------------------------------------------------

    String backendResponseText = "Sorry, something went wrong.";

    try {
      // 1. Call Gemini (NLU)
      print("Calling Gemini to extract intent...");
      final nluResult =
          await _geminiService.extractIntentAndEntities(messageText);

      if (nluResult == null ||
          nluResult['intent'] == null ||
          nluResult['intent'] == 'UNKNOWN') {
        print("Gemini NLU failed or intent is UNKNOWN.");
        backendResponseText =
            "Sorry, I couldn't quite understand that. Can you rephrase?";
        // ... (optional error detail handling) ...
      } else {
        // 2. Call Backend Cloud Function
        //final intent = nluResult['intent'];
        //final entities = nluResult['entities'] as Map<String, dynamic>? ?? {};
        print("Calling getFinancialData Cloud Function...");
        final functions = FirebaseFunctions.instance;
        final callable = functions.httpsCallable('getFinancialData');
        final results = await callable.call(<String, dynamic>{
          'intent': nluResult['intent'],
          'entities': nluResult['entities'],
        });
        backendResponseText = results.data['responseText'] ??
            "Sorry, I received an unexpected response.";
        print("Received backend response.");
      }
    } on FirebaseFunctionsException catch (e) {
      print("FirebaseFunctionsException: ${e.code} - ${e.message}");
      backendResponseText =
          "There was a problem reaching the server (${e.code}).";
    } catch (e) {
      print("Error during message processing pipeline: $e");
      backendResponseText = "An unexpected error occurred.";
    } finally {
      // 3. Update UI with final response
      _clearThinkingTimer(); // Stop the timeout timer
      if (mounted) {
        setState(() {
          // Remove the "Thinking..." message
          _chatMessages.removeWhere((m) => m.isThinking);
          // Add the actual AI response
          _chatMessages.add(ChatMessage(
              text: backendResponseText,
              sender: MessageSender.ai,
              timestamp: DateTime.now()));
          _isProcessingMessage = false;
          _scrollToBottom(); // Scroll after final response
        });
      }
    }
  } // End _sendMessage

// Helper to clear the thinking timer
  void _clearThinkingTimer() {
    _thinkingTimer?.cancel();
    _thinkingTimer = null;
  }

// Helper function to scroll ListView to bottom
  void _scrollToBottom() {
    // Use SchedulerBinding to scroll after the frame is built
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- Fetch Spending Summaries ---
  Future<void> _fetchSpendingSummaries() async {
    if (!mounted) return;
    setState(() {
      _summariesLoading = true;
      _summaryError = null;
    });

    if (_currentUser == null) {
      setState(() {
        _summaryError = "Not logged in.";
        _summariesLoading = false;
      });
      return;
    }

    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('getFinancialData');

      // Fetch Today
      final todayResult = await callable.call(<String, dynamic>{
        'intent': 'GET_SPENDING_SUMMARY',
        'entities': {'period': 'today'},
      });
      final todayText = todayResult.data['responseText'] as String? ?? "Error";

      // Fetch This Week
      final weekResult = await callable.call(<String, dynamic>{
        'intent': 'GET_SPENDING_SUMMARY',
        'entities': {'period': 'this_week'},
      });
      final weekText = weekResult.data['responseText'] as String? ?? "Error";

      // Fetch This Month
      final monthResult = await callable.call(<String, dynamic>{
        'intent': 'GET_SPENDING_SUMMARY',
        'entities': {'period': 'this_month'},
      });
      final monthText = monthResult.data['responseText'] as String? ?? "Error";

      // Extract just the amount for cleaner display (improve this extraction later if needed)
      final amountRegex =
          RegExp(r'\$?([\d,]+\.\d{2})'); // Simple regex for $XXX.XX

      setState(() {
        _todaySpend = amountRegex.firstMatch(todayText)?.group(1) ?? todayText;
        _weekSpend = amountRegex.firstMatch(weekText)?.group(1) ?? weekText;
        _monthSpend = amountRegex.firstMatch(monthText)?.group(1) ?? monthText;
        _summariesLoading = false;
      });
    } on FirebaseFunctionsException catch (e) {
      print("Error fetching summaries (Firebase): ${e.code} - ${e.message}");
      if (mounted) {
        setState(() {
          _summaryError = "Could not load summaries (${e.code}).";
          _todaySpend = "Error";
          _weekSpend = "Error";
          _monthSpend = "Error";
          _summariesLoading = false;
        });
      }
    } catch (e) {
      print("Error fetching summaries (General): $e");
      if (mounted) {
        setState(() {
          _summaryError = "Could not load summaries.";
          _todaySpend = "Error";
          _weekSpend = "Error";
          _monthSpend = "Error";
          _summariesLoading = false;
        });
      }
    }
  }

  void _initSpeech() async {
    try {
      // Check if recognition is available
      bool available = await _speechToText.initialize(
        onError: (errorNotification) =>
            print('Speech recognition error: $errorNotification'),
        onStatus: (status) => _onSpeechStatus(status),
        // Optional: debugLog: true,
      );
      if (mounted) {
        setState(() {
          _speechEnabled = available;
        });
      }
      if (available) {
        print("Speech recognition initialized successfully.");
      } else {
        print("Speech recognition not available on this device.");
      }
    } catch (e) {
      print("Error initializing speech recognition: $e");
      if (mounted) {
        setState(() {
          _speechEnabled = false;
        });
      }
    }
  }

  /// Callback for speech recognition status changes.
  void _onSpeechStatus(String status) {
    if (!mounted) return;
    print('Speech recognition status: $status');
    // Update listening state based on status (may vary slightly by platform/package version)
    // Generally, listening stops when status is 'notListening' or 'done'
    bool listening = _speechToText.isListening; // Check the current state
    if (listening != _isListening) {
      // Only update state if it changed
      setState(() {
        _isListening = listening;
      });
      print("Listening state updated to: $_isListening");
    }
    // If status is 'done' and we are still marked as listening, force stop
    if (status == 'done' && _isListening) {
      setState(() => _isListening = false);
      print("Forcing listening state to false due to 'done' status.");
    }
  }

  /// Starts listening for speech input.
  void _startListening() async {
    if (!_speechEnabled) {
      print("Speech recognition not enabled.");
      // Show a message to the user?
      return;
    }
    if (_isListening) {
      print("Already listening.");
      return;
    }
    print("Starting speech recognition...");
    // Clear previous text before starting new recognition? Optional.
    // _chatController.clear();

    await _speechToText.listen(
      onResult: _onSpeechResult,
      listenFor: const Duration(seconds: 30), // Max listen duration
      pauseFor: const Duration(seconds: 3), // Pause after user stops talking
      partialResults: true, // Get results as user speaks
      // localeId: "en_US", // Optional: Specify locale
    );
    // Although onStatus should update _isListening, setting it here provides
    // immediate feedback while initialization might be happening.
    if (mounted) {
      setState(() {
        _isListening = true;
      });
    }
  }

  /// Stops the speech recognition session.
  void _stopListening() async {
    if (!_isListening) {
      print("Not currently listening.");
      return;
    }
    print("Stopping speech recognition...");
    await _speechToText.stop();
    // The onStatus callback should set _isListening to false,
    // but we can set it here too for faster UI feedback if needed.
    if (mounted) {
      setState(() {
        _isListening = false;
      });
    }
  }

  /// Callback when speech recognition provides a result.
  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    String recognizedWords = result.recognizedWords;
    print(
        "Speech result: words='$recognizedWords', final=${result.finalResult}");

    setState(() {
      // Update the text field with the latest recognized words
      _chatController.text = recognizedWords;
      // Move cursor to the end
      _chatController.selection = TextSelection.fromPosition(
          TextPosition(offset: _chatController.text.length));

      // Optional: store words if needed elsewhere
      // _lastWords = recognizedWords;

      // If it's the final result, update listening status
      if (result.finalResult) {
        print("Final result received, setting listening to false.");
        _isListening = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // --- AppBar ---
      appBar: AppBar(
        title: const Text('TrackMyDough',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0, // Flat design
        backgroundColor: Colors.transparent, // Transparent background
        foregroundColor:
            Theme.of(context).textTheme.bodyLarge?.color, // Use theme color
        // Leading menu icon is automatically added when a Drawer is present
      ),
      // --- Drawer (Collapsible Menu) ---
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero, // Remove padding
          children: <Widget>[
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
              ),
              child: Text(
                'Menu',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_outlined),
              title: const Text('Accounts'),
              onTap: () => _navigateTo(const AccountsScreen()), // Placeholder
            ),
            ListTile(
              leading: const Icon(Icons.dashboard_outlined),
              title: const Text('Dashboard'),
              onTap: () => _navigateTo(const DashboardScreen()), // Placeholder
            ),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('Insights'),
              onTap: () => _navigateTo(const InsightsScreen()), // Placeholder
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Scan Receipt'), // Changed title slightly
              // Navigate to the new capture screen
              onTap: () => _navigateTo(const ReceiptCaptureScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.list_alt_outlined),
              title: const Text('Transactions'),
              onTap: () =>
                  _navigateTo(const TransactionListScreen()), // Existing screen
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign Out'),
              onTap: _signOut,
            ),
          ],
        ),
      ),
      // --- Body ---
      body: Column(
        children: [
          // --- Insights Row (Placeholders) ---
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildInsightCard("Today", _todaySpend),
                _buildInsightCard("This Week", _weekSpend),
                _buildInsightCard("This Month", _monthSpend),
              ],
            ),
          ),
          if (_summaryError != null && !_summariesLoading)
            Padding(
              padding: const EdgeInsets.only(bottom: 10.0),
              child: Text(_summaryError!,
                  style: const TextStyle(color: Colors.redAccent)),
            ),

          // --- Welcome Message ---
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20.0),
            child: Text(
              "Hello, $_userName!",
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),

          // --- Chat History Area (Placeholder) ---
          Expanded(
            child: ListView.builder(
              controller: _scrollController, // Attach scroll controller
              padding:
                  const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
              itemCount: _chatMessages.length,
              itemBuilder: (context, index) {
                final message = _chatMessages[index];
                return _buildChatMessageBubble(message); // Use helper widget
              },
            ),
          ),

          // --- Chat Input Bar ---
          IgnorePointer(
            ignoring: _isProcessingMessage,
            child: Opacity(
              // Make it slightly transparent while processing
              opacity: _isProcessingMessage ? 0.7 : 1.0,
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 8.0, right: 8.0, bottom: 10.0, top: 5.0),
                child: Material(
                  // Wrap with Material for elevation shadow
                  elevation: 4.0,
                  borderRadius: BorderRadius.circular(25.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surface, // Use theme surface color
                      borderRadius: BorderRadius.circular(25.0),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            decoration: const InputDecoration(
                                hintText: 'Ask about your spending...',
                                border: InputBorder.none, // Remove underline
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10.0, vertical: 15.0)),
                            onSubmitted: (_) =>
                                _sendMessage(), // Send on keyboard submit
                          ),
                        ),
                        IconButton(
                          // Change icon based on listening state
                          icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
                          tooltip: _isListening
                              ? 'Stop Listening'
                              : (_speechEnabled
                                  ? 'Start Voice Input'
                                  : 'Voice input unavailable'),
                          // Call start or stop based on state, disable if speech not enabled
                          onPressed: !_speechEnabled
                              ? null
                              : (_isListening
                                  ? _stopListening
                                  : _startListening),
                          // Optionally change color while listening
                          color: _isListening
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.send),
                          tooltip: 'Send Message',
                          // Disable send button while listening? Optional.
                          onPressed: _isListening || _isProcessingMessage
                              ? null
                              : _sendMessage,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Helper Widget for Insight Cards ---
  Widget _buildInsightCard(String title, String value) {
    String displayValue =
        _summariesLoading ? "..." : (_summaryError != null ? "!" : "\$$value");
    Color valueColor = _summariesLoading ||
            _summaryError != null ||
            value == "Error" ||
            value == "Loading..."
        ? Colors.grey // Grey out if loading, error, or no valid value
        : Theme.of(context)
            .textTheme
            .bodyLarge!
            .color!; // Default text color for valid value

    return Card(
      elevation: 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4.0),
            Text(
              displayValue,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: valueColor, // Use determined color
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatMessageBubble(ChatMessage message) {
    final bool isUser = message.sender == MessageSender.user;
    final alignment =
        isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isUser
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.secondaryContainer;
    final textColor = isUser
        ? Theme.of(context).colorScheme.onPrimaryContainer
        : Theme.of(context).colorScheme.onSecondaryContainer;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  MediaQuery.of(context).size.width * 0.75, // Max width 75%
            ),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18.0),
                  topRight: const Radius.circular(18.0),
                  bottomLeft: Radius.circular(isUser ? 18.0 : 4.0),
                  bottomRight: Radius.circular(isUser ? 4.0 : 18.0),
                ),
              ),
              child: message.isThinking
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2)) // Show loader if thinking
                  : SelectableText(
                      // Allow text selection
                      message.text,
                      style: TextStyle(color: textColor),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
