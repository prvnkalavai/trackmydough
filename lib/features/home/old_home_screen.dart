// File: lib/features/home/home_screen.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart'; 
import 'package:plaid_flutter/plaid_flutter.dart'; 
import 'package:flutter/foundation.dart';
import '../transactions/transaction_list_screen.dart'; 

class HomeScreen extends StatefulWidget {
  // Changed to StatefulWidget
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isPlaidLoading = false;
  bool _isFetchingTransactions = false;

  // --- Sign Out Logic ---
  Future<void> _signOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
      // AuthGate will automatically navigate back to SignInScreen
      // No need for manual navigation here if AuthGate is structured correctly
    } catch (e) {
      // Show an error message if sign out fails
      if (mounted) {
        // Check if the widget is still mounted
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error signing out: ${e.toString()}')),
        );
      }
    }
  }

  // --- Function to Open Plaid Link ---
  Future<void> _openPlaidLink(BuildContext context) async {
    setState(() {
      _isPlaidLoading = true; // Show loading indicator
    });
    await Future.delayed(const Duration(milliseconds: 500));
    String? linkToken; // Variable to hold the link token

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      print("ERROR: User is NULL on client-side just before calling function!");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Error: Not logged in. Please restart.')),
        );
      }
      setState(() {
        _isPlaidLoading = false;
      });
      return; // Don't proceed
    } else {
      print("User is logged in on client-side: ${currentUser.uid}");
      // Optionally try getting token:
      // try {
      //   final idToken = await currentUser.getIdToken();
      //   print("Client ID token obtained successfully.");
      // } catch (e) {
      //   print("Error getting client ID token: $e");
      // }
    }

    // 1. Call Cloud Function to get link_token
    try {
      //final functions = FirebaseFunctions.instance;
      // Ensure you use the correct region if your function is not in us-central1
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('createLinkToken');
      final results = await callable.call(); // Call the function

      // Check if data and link_token exist
      if (results.data != null && results.data['link_token'] != null) {
        linkToken = results.data['link_token'];
        if (kDebugMode) {
          // Only print in debug mode
          print("Received Link Token: $linkToken");
        }
      } else {
        throw Exception("Link token was null or missing in the response.");
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Error fetching Plaid token: ${e.code} - ${e.message}')),
        );
      }
      // Log detailed error for debugging
      print(
          "FirebaseFunctionsException calling createLinkToken: ${e.code} - ${e.message} - Details: ${e.details}");
      setState(() {
        _isPlaidLoading = false;
      }); // Stop loading on error
      return; // Exit the function
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('An unexpected error occurred: ${e.toString()}')),
        );
      }
      print("Error fetching link token: $e");
      setState(() {
        _isPlaidLoading = false;
      }); // Stop loading on error
      return; // Exit the function
    }

    // --- If linkToken is available, proceed to open Plaid Link ---
    // Note: No finally block needed here because we returned on error above.
    // If code execution reaches here, linkToken is guaranteed to be non-null.

    try {
      // Create LinkConfiguration based on the retrieved token
      final LinkTokenConfiguration linkTokenConfiguration =
          LinkTokenConfiguration(
        token: linkToken!, // Use ! because we checked for null above
      );

      // --- Open Plaid Link ---
      // Setting up listeners BEFORE calling open is generally recommended
      // to ensure no events are missed if 'open' resolves very quickly.
      PlaidLink.onSuccess.listen(_onPlaidLinkSuccess);
      PlaidLink.onEvent.listen(_onPlaidLinkEvent);
      PlaidLink.onExit.listen(_onPlaidLinkExit);

      // --- Step 1 (v4.2.0): Create the Plaid Link handler ---
      await PlaidLink.create(configuration: linkTokenConfiguration);

      // --- Step 2 (v4.2.0): Open Plaid Link (no arguments needed here) ---
      await PlaidLink.open();
    } catch (e) {
      print("Error opening Plaid Link: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error initializing Plaid: ${e.toString()}')),
        );
      }
      setState(() {
        // Ensure loading stops even if PlaidLink.open fails
        _isPlaidLoading = false;
      });
    }
    // Note: Loading indicator (_isPlaidLoading) is turned off within
    // the Plaid Link callbacks (_onPlaidLinkSuccess, _onPlaidLinkExit)
  }

  // --- Plaid Link Callbacks ---

  void _onPlaidLinkSuccess(LinkSuccess event) {
    if (mounted) {
      setState(() {
        _isPlaidLoading = false;
      }); // Hide loading indicator
    }
    if (kDebugMode) {
      print("Plaid Link Success!");
      print("Public Token: ${event.publicToken}");
      print("Metadata: ${event.metadata.description()}");
    }

    // **** NEXT CRITICAL STEP: Exchange Public Token ****
    // You MUST send this public token to your backend IMMEDIATELY
    // to exchange it for an access token.
    final String publicToken = event.publicToken;
    final String? institutionName = event.metadata.institution?.name;
    final String? institutionId = event.metadata.institution?.id;

    // Call the 'exchangePublicToken' Cloud Function here
    _exchangePublicToken(publicToken, institutionName, institutionId);

    if (kDebugMode) {
      print("Public token captured: $publicToken");
      print("Institution Name captured: $institutionName");
      print("Institution ID captured: $institutionId");
    }

    // For now, just show a success message
    // if (mounted) {
    //   ScaffoldMessenger.of(context).showSnackBar(
    //     SnackBar(content: Text('Successfully linked: $institutionName')),
    //   );
    // }
  }

  void _onPlaidLinkEvent(LinkEvent event) {
    // Optional: Handle specific events during the Link flow
    if (kDebugMode) {
      print(
          "Plaid Link Event: ${event.name} - Metadata: ${event.metadata.description()}");
      // Example: Check for specific transition views or errors
      // if (event.name == LinkEventName.ERROR) { ... }
    }
  }

  void _onPlaidLinkExit(LinkExit event) {
    if (mounted) {
      setState(() {
        _isPlaidLoading = false;
      }); // Hide loading indicator
    }
    if (kDebugMode) {
      print("Plaid Link Exited");
      if (event.error != null) {
        print("Exit Error Code: ${event.error?.code}");
        print("Exit Error Message: ${event.error?.message}");
        print("Exit Error Display Message: ${event.error?.displayMessage}");
      } else {
        print("Exit Reason: User exited manually.");
      }
    }

    // Show appropriate message to the user
    if (mounted) {
      if (event.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Plaid Link failed: ${event.error!.displayMessage ?? 'Please try again'}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account linking cancelled.')),
        );
      }
    }
  }

  // Function for exchanging token ---
  Future<void> _exchangePublicToken(String publicToken, String? institutionName,
      String? institutionId) async {
    // Ensure loading indicator stays active or restart it if needed
    if (!_isPlaidLoading && mounted) {
      setState(() {
        _isPlaidLoading = true;
      });
    }

    if (kDebugMode) {
      print(
          'Attempting to exchange public token: ${publicToken.substring(0, 15)}... for $institutionName');
    }

    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('exchangePublicToken');
      final results = await callable.call(<String, dynamic>{
        'publicToken': publicToken,
        'institutionName': institutionName, // Send null if not available
        'institutionId': institutionId, // Send null if not available
      });

      // Check backend response for success
      if (results.data['success'] == true) {
        if (kDebugMode) {
          print(
              'Successfully exchanged public token for item: ${results.data['itemId']}');
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Account "${institutionName ?? 'Account'}" securely saved!')),
          );
        }
        // Maybe trigger a refresh of user data / accounts here
      } else {
        // Handle cases where backend returns success: false (if implemented)
        throw Exception('Backend indicated failure during token exchange.');
      }
    } on FirebaseFunctionsException catch (e) {
      print(
          "FirebaseFunctionsException calling exchangePublicToken: ${e.code} - ${e.message} - Details: ${e.details}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Error saving account: ${e.message ?? 'Please try again'}')),
        );
      }
    } catch (e) {
      print("Error during public token exchange: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving account: ${e.toString()}')),
        );
      }
    } finally {
      // Ensure loading indicator is turned off
      if (mounted) {
        setState(() {
          _isPlaidLoading = false;
        });
      }
    }
  }

  Future<void> _fetchTransactions() async {
    if (_isFetchingTransactions) return; // Prevent double taps

    setState(() {
      _isFetchingTransactions = true;
    });

    if (kDebugMode) {
      print('Attempting to trigger fetchTransactions Cloud Function...');
    }

    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('fetchTransactions');
      final results = await callable.call();

      if (results.data['success'] == true) {
        final count = results.data['transactionsAdded'] ?? 0;
        if (kDebugMode) {
          print(
              'Successfully triggered transaction fetch. New transactions added: $count');
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(count > 0
                    ? 'Fetched $count new transactions!'
                    : 'Accounts synced. No new transactions.')),
          );
        }
        // TODO: Trigger UI refresh if needed to show new transactions
      } else {
        throw Exception(results.data['message'] ??
            'Backend indicated failure during transaction fetch.');
      }
    } on FirebaseFunctionsException catch (e) {
      print(
          "FirebaseFunctionsException calling fetchTransactions: ${e.code} - ${e.message} - Details: ${e.details}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Error fetching transactions: ${e.message ?? 'Please try again'}')),
        );
      }
    } catch (e) {
      print("Error triggering transaction fetch: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error fetching transactions: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingTransactions = false;
        });
      }
    }
  }

  @override
  void dispose() {
    // Although PlaidLink listeners are static, clearing them if using
    // stream subscriptions or complex logic might be necessary.
    // For simple listeners like above, it's often not strictly required.
    super.dispose();
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Finance Home'),
        actions: [
          // Add a Sign Out button to the AppBar
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
            onPressed: () => _signOut(context),
          ),
        ],
      ),
      body: Center(
        // Keep content centered
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Welcome!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              // Display user's email if available
              if (user?.email != null)
                Text(
                  'Logged in as: ${user!.email}',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 40), // Add more space

              // --- Link Bank Account Button (with Loading State) ---
              ElevatedButton.icon(
                icon: _isPlaidLoading
                    ? Container(
                        // Show loading indicator inside button
                        width: 20,
                        height: 20,
                        padding: const EdgeInsets.all(2.0),
                        child: CircularProgressIndicator(
                          // Match button text color if needed
                          color: Theme.of(context).colorScheme.onPrimary,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.account_balance),
                label: Text(
                    _isPlaidLoading ? 'Connecting...' : 'Link Bank Account'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  // Optionally change color when loading/disabled
                  backgroundColor:
                      _isPlaidLoading ? Colors.grey.shade400 : null,
                  foregroundColor:
                      _isPlaidLoading ? Colors.grey.shade700 : null,
                ),
                // Disable onPressed callback when loading
                onPressed: _isPlaidLoading || _isFetchingTransactions
                    ? null
                    : () => _openPlaidLink(context),
              ),
              const SizedBox(height: 15), // Space between buttons

              // --- NEW: Fetch Transactions Button ---
              ElevatedButton.icon(
                icon: _isFetchingTransactions
                    ? Container(
                        width: 20,
                        height: 20,
                        padding: const EdgeInsets.all(2.0),
                        child: CircularProgressIndicator(
                          color: Theme.of(context).colorScheme.onPrimary,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.sync),
                label: Text(_isFetchingTransactions
                    ? 'Fetching...'
                    : 'Fetch Transactions'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  backgroundColor: _isFetchingTransactions
                      ? Colors.grey.shade400
                      : Theme.of(context)
                          .colorScheme
                          .secondary, // Different color?
                  foregroundColor: _isFetchingTransactions
                      ? Colors.grey.shade700
                      : Theme.of(context).colorScheme.onSecondary,
                ),
                onPressed: _isPlaidLoading || _isFetchingTransactions
                    ? null
                    : _fetchTransactions, // Disable if either loading
              ),
              // ----------------------------------------------------
              const SizedBox(height: 15), // Space

            // --- NEW: View Transactions Button ---
            OutlinedButton.icon( // Use OutlinedButton for variety
              icon: const Icon(Icons.list_alt),
              label: const Text('View Transactions'),
              style: OutlinedButton.styleFrom(
                 padding: const EdgeInsets.symmetric(vertical: 15),
                 shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),),
                 // Disable if any loading is happening
                 side: BorderSide(color: _isPlaidLoading || _isFetchingTransactions ? Colors.grey : Theme.of(context).colorScheme.primary),
              ),
              onPressed: _isPlaidLoading || _isFetchingTransactions
                 ? null
                 : () {
                     Navigator.push(
                       context,
                       MaterialPageRoute(builder: (context) => const TransactionListScreen()),
                     );
                   },
            ),
              const SizedBox(height: 30),
              const Text('(Dashboard/Insights will appear here later)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontStyle: FontStyle.italic, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}
