// File: lib/features/insights/insights_screen.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  User? _currentUser;
  bool _isGenerating = false; // Loading state for the button
  String _statusMessage =
      'Generate insights based on your recent transactions.'; // Initial message

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream;

  @override
  void initState() {
    super.initState();
    _currentUser = _auth.currentUser;
    if (_currentUser != null) {
      _userStream = _firestore
          .collection('users')
          .doc(_currentUser!.uid)
          .snapshots(); // Listen for real-time updates to the user doc
    }
  }

  // Function to call the Cloud Function
  Future<void> _triggerGenerateInsights() async {
    // Check login status
    if (FirebaseAuth.instance.currentUser == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: You must be logged in.')),
        );
      }
      return;
    }

    if (_isGenerating) return; // Prevent double calls

    setState(() {
      _isGenerating = true;
      _statusMessage = 'Generating insights, please wait...';
    });

    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture context

    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('generateInsights');
      print("Calling generateInsights function...");
      final results = await callable.call(); // Call the function

      if (results.data['success'] == true) {
        final count = results.data['insightsGenerated'] ?? 0;
        final message = results.data['message'] as String? ??
            (count > 0 ? 'Insights generated!' : 'No new insights found.');
        print(
            'Successfully triggered insight generation. Insights count: $count');
        _statusMessage = message; // Update status message
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(message)),
        );
        // TODO: Later, fetch and display insights here or trigger a refresh
      } else {
        throw Exception(results.data['message'] ??
            'Backend indicated failure during insight generation.');
      }
    } on FirebaseFunctionsException catch (e) {
      print(
          "FirebaseFunctionsException calling generateInsights: ${e.code} - ${e.message}");
      _statusMessage = 'Error generating insights (${e.code}).';
      scaffoldMessenger.showSnackBar(
        SnackBar(
            content: Text(
                'Error generating insights: ${e.message ?? 'Please try again'}')),
      );
    } catch (e) {
      print("Error triggering insight generation: $e");
      _statusMessage = 'An unexpected error occurred.';
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Error generating insights: ${e.toString()}')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateFormat timestampFormat = DateFormat('MMM d, yyyy hh:mm a');
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Insights'),
      ),
      // Use StreamBuilder to listen for user document changes
      body: _currentUser == null
          ? const Center(child: Text('Please log in.'))
          : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _userStream,
              builder: (context, snapshot) {
                // --- Handle Loading ---
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                // --- Handle Error ---
                if (snapshot.hasError) {
                  print(
                      "Error fetching user data for insights: ${snapshot.error}");
                  return Center(
                      child: Text('Error loading insights: ${snapshot.error}'));
                }
                // --- Handle No Data/Doc Doesn't Exist ---
                if (!snapshot.hasData || !snapshot.data!.exists) {
                  return const Center(
                      child: Text('Could not load user profile.'));
                }

                // --- Extract Insights Data ---
                final userData = snapshot.data!.data();
                // Get the insights array (list of strings)
                final List<dynamic> insightsRaw = userData?['aiInsights'] ?? [];
                final List<String> insights =
                    insightsRaw.whereType<String>().toList();
                // Get the last update timestamp
                final Timestamp? lastUpdateTs =
                    userData?['lastInsightUpdate'] as Timestamp?;
                final String lastUpdateString = lastUpdateTs != null
                    ? 'Last updated: ${timestampFormat.format(lastUpdateTs.toDate())}'
                    : 'Insights not generated yet.';
                // ---------------------------
                return Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        _statusMessage, // Display status message
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 30),
                      ElevatedButton.icon(
                        icon: _isGenerating
                            ? Container(
                                width: 20,
                                height: 20,
                                padding: const EdgeInsets.all(2.0),
                                child: CircularProgressIndicator(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome), // Insights icon
                        label: Text(_isGenerating
                            ? 'Generating...'
                            : 'Refresh Insights'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 30, vertical: 15),
                          backgroundColor:
                              _isGenerating ? Colors.grey.shade400 : null,
                          foregroundColor:
                              _isGenerating ? Colors.grey.shade700 : null,
                        ),
                        onPressed: _isGenerating
                            ? null
                            : _triggerGenerateInsights, // Call the function
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _statusMessage, // Show status from last generation attempt
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 10),

                      // --- Display Last Update Time ---
                      Text(
                        lastUpdateString,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.grey),
                      ),
                      const SizedBox(height: 15),

                      // --- Display Insights List ---
                      Expanded(
                        // Make the list scrollable and fill space
                        child: insights.isEmpty
                            ? Center(
                                child: Text(
                                  lastUpdateTs == null
                                      ? 'Click "Refresh Insights" to generate your first insights!'
                                      : 'No insights available at the moment.', // If generated but empty
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.builder(
                                itemCount: insights.length,
                                itemBuilder: (context, index) {
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                        vertical: 6.0),
                                    elevation: 2.0,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12.0),
                                      child: Text(
                                        insights[index],
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium,
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
