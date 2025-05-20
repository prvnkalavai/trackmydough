// File: lib/features/accounts/accounts_screen.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:plaid_flutter/plaid_flutter.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:flutter_slidable/flutter_slidable.dart';

// TODO: Import PlaidItemData model/interface if defined separately
// For now, we'll use Map<String, dynamic>

// TODO: Import Plaid Link logic (or refactor it to be callable from here)
// import '../home/home_screen.dart'; // Temporary, not ideal

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  User? _currentUser;
  bool _isPlaidLoading = false;
  bool _isFetchingTransactions = false;

  // --- Stream for user data containing plaidItems ---
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream;

  @override
  void initState() {
    super.initState();
    _currentUser = _auth.currentUser;
    if (_currentUser != null) {
      _userStream = _firestore
          .collection('users')
          .doc(_currentUser!.uid)
          .snapshots(); // Listen for real-time updates
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
          print(
              "Account linked successfully, triggering initial transaction fetch...");
          // Use Future.microtask to ensure state updates from linking finish first
          Future.microtask(() => _fetchTransactions());
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

  Future<void> _handleRefreshAccount(
      String itemId, String? institutionName) async {
    print("Refresh triggered for Item ID: $itemId ($institutionName)");

    // Optional: Show a specific loading indicator for this item?
    // This is harder with Slidable as the item doesn't stay visually "busy".
    // A simple SnackBar might be best for now.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Refreshing "${institutionName ?? itemId}"...')),
    );

    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('refreshTransactionsForItem');
      final results = await callable.call(<String, dynamic>{
        'itemId': itemId, // Pass the specific item ID
      });

      if (results.data['success'] == true) {
        final count = results.data['transactionsAdded'] ?? 0;
        if (mounted) {
          ScaffoldMessenger.of(context)
              .hideCurrentSnackBar(); // Hide "Refreshing..."
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(count > 0
                    ? '"${institutionName ?? itemId}" synced. $count new transactions.'
                    : '"${institutionName ?? itemId}" synced. No new transactions.')),
          );
        }
      } else {
        throw Exception(results.data['message'] ??
            'Backend indicated failure during item refresh.');
      }
    } on FirebaseFunctionsException catch (e) {
      print(
          "FirebaseFunctionsException calling refreshTransactionsForItem: ${e.code} - ${e.message}");
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Error refreshing "${institutionName ?? itemId}": ${e.message ?? 'Please try again'}')),
        );
      }
    } catch (e) {
      print("Error triggering item refresh: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Error refreshing "${institutionName ?? itemId}": ${e.toString()}')),
        );
      }
    }
    // No need for setState here, StreamBuilder listening to the user doc
    // will pick up the 'lastSync' time change and redraw the list.
  }

  Future<void> _handleUnlinkAccount(
      String itemId, String? institutionName) async {
    print("Unlink confirmed for Item ID: $itemId ($institutionName)");

    // Optional: Show persistent loading indicator if needed
    // For now, rely on SnackBar and StreamBuilder update

    final scaffoldMessenger = ScaffoldMessenger.of(context); // Capture context
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text('Unlinking "${institutionName ?? itemId}"...')),
    );

    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('unlinkPlaidItem');
      final results = await callable.call(<String, dynamic>{
        'itemId': itemId, // Pass the specific item ID to unlink
      });

      if (results.data['success'] == true) {
        print('Successfully unlinked item: $itemId');
        // SnackBar might be dismissed quickly by UI rebuild, but show anyway
        scaffoldMessenger.hideCurrentSnackBar();
        scaffoldMessenger.showSnackBar(
          SnackBar(
              content:
                  Text('Account "${institutionName ?? itemId}" unlinked.')),
        );
        // No need for setState - StreamBuilder will detect the Firestore change
        // and remove the item from the list automatically.
      } else {
        throw Exception(results.data['message'] ??
            'Backend indicated failure during unlink.');
      }
    } on FirebaseFunctionsException catch (e) {
      print(
          "FirebaseFunctionsException calling unlinkPlaidItem: ${e.code} - ${e.message}");
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
            content: Text(
                'Error unlinking "${institutionName ?? itemId}": ${e.message ?? 'Please try again'}')),
      );
      // Manually trigger a rebuild if item wasn't removed due to error? Less ideal.
      // if (mounted) setState((){});
    } catch (e) {
      print("Error triggering item unlink: $e");
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
            content: Text(
                'Error unlinking "${institutionName ?? itemId}": ${e.toString()}')),
      );
    }
    // No finally/setState needed here as StreamBuilder handles UI update on success
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Linked Accounts'),
      ),
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
                  print("Error fetching user data: ${snapshot.error}");
                  return Center(
                      child: Text('Error loading accounts: ${snapshot.error}'));
                }
                // --- Handle No Data/Doc Doesn't Exist ---
                if (!snapshot.hasData || !snapshot.data!.exists) {
                  return const Center(child: Text('User profile not found.'));
                }

                // --- Extract Data ---
                // Use Map<String, dynamic> for now, replace with PlaidItemData if available
                final List<dynamic> plaidItemsRaw =
                    snapshot.data!.data()?['plaidItems'] ?? [];
                // Filter out any potentially malformed items if needed, though casting is simple
                final Map<String, Map<String, dynamic>> uniqueInstitutions = {};
                for (var itemRaw in plaidItemsRaw) {
                  // Ensure item is a map and has necessary keys
                  if (itemRaw is Map<String, dynamic> &&
                      itemRaw.containsKey('institutionId')) {
                    final String instId = itemRaw['institutionId'] ??
                        itemRaw['institutionName'] ??
                        itemRaw['itemId'] ??
                        DateTime.now()
                            .toString(); // Use best available unique ID

                    // Only add if this institution isn't already processed
                    if (!uniqueInstitutions.containsKey(instId)) {
                      uniqueInstitutions[instId] =
                          itemRaw; // Store the first item found for this institution
                    }
                  }
                }
                // Convert map values back to a list for the ListView
                final List<Map<String, dynamic>> displayItems =
                    uniqueInstitutions.values.toList();

                return Column(
                  // Use Column to add button above list
                  children: [
                    // --- Link New Account Button ---
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: ElevatedButton.icon(
                        icon: _isPlaidLoading
                            ? Container(
                                // Show loading indicator inside button
                                width: 18, height: 18, // Slightly smaller
                                child: CircularProgressIndicator(
                                  color:
                                      Theme.of(context).colorScheme.onPrimary,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_circle_outline),
                        label: Text(_isPlaidLoading
                            ? 'Connecting...'
                            : 'Link New Account'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          backgroundColor: _isPlaidLoading
                              ? Colors.grey.shade400
                              : null, // Indicate disabled state
                          foregroundColor:
                              _isPlaidLoading ? Colors.grey.shade700 : null,
                        ),
                        // Call the local _openPlaidLink and disable if loading
                        onPressed: _isPlaidLoading
                            ? null
                            : () => _openPlaidLink(context),
                      ),
                    ),

                    const Divider(),

                    // --- TEMPORARY MATCH TEST BUTTON ---
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: OutlinedButton(
                        child: const Text("DEBUG: Test Match Receipt"),
                        onPressed: () async {
                          const receiptIdToTest = "6KVF5hk34Q52k3nrY6qc"; // <-- PASTE A REAL RECEIPT ID FROM FIRESTORE
                          if (receiptIdToTest == "YOUR_RECEIPT_ID_HERE") {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please paste a real receipt ID in accounts_screen.dart!')));
                            return;
                          }
                          // Prevent running if Plaid link is happening
                          if (_isPlaidLoading) return;

                          print("Calling matchReceipt for ID: $receiptIdToTest");
                          final scaffoldMessenger = ScaffoldMessenger.of(context);
                          scaffoldMessenger.showSnackBar(const SnackBar(content: Text('Attempting receipt match...')));

                          try {
                            final functions = FirebaseFunctions.instance;
                            final callable = functions.httpsCallable('matchReceipt');
                            final results = await callable.call({'receiptId': receiptIdToTest});
                            print("matchReceipt Result: ${results.data}");
                            scaffoldMessenger.hideCurrentSnackBar();
                            scaffoldMessenger.showSnackBar(
                                SnackBar(content: Text('Match result: ${results.data['status'] ?? 'Unknown'}'))
                            );
                          } on FirebaseFunctionsException catch (e) {
                            print("Error calling matchReceipt (Firebase): ${e.code} - ${e.message}");
                            scaffoldMessenger.hideCurrentSnackBar();
                            scaffoldMessenger.showSnackBar(
                              SnackBar(content: Text('Error matching receipt: ${e.message ?? e.code}'))
                            );
                          } catch (e) {
                            print("Error calling matchReceipt (General): $e");
                            scaffoldMessenger.hideCurrentSnackBar();
                            scaffoldMessenger.showSnackBar(
                              SnackBar(content: Text('Error matching receipt: ${e.toString()}'))
                            );
                          }
                        },
                      ),
                    ),

                    const Divider(), // Separator

                    // --- List of Accounts ---
                    if (displayItems.isEmpty)
                      const Expanded(
                          child: Center(child: Text('No accounts linked yet.')))
                    else
                      Expanded(
                        // Make ListView fill remaining space
                        child: ListView.builder(
                          itemCount: displayItems.length,
                          itemBuilder: (context, index) {
                            final item = displayItems[index];
                            final String itemId =
                                item['itemId'] ?? 'Unknown ID';
                            final String institutionName =
                                item['institutionName'] ??
                                    'Unknown Institution';
                            final String? logoBase64 =
                                item['logoBase64'] as String?;
                            final Timestamp? lastSyncTs =
                                item['lastSync'] as Timestamp?;
                            final String lastSync = lastSyncTs != null
                                ? 'Synced: ${DateFormat.yMd().add_jm().format(lastSyncTs.toDate())}' // Format timestamp
                                : 'Never synced';
                            Widget leadingWidget = const Icon(
                                Icons.account_balance,
                                size: 40); // Default Icon
                            if (logoBase64 != null && logoBase64.isNotEmpty) {
                              try {
                                String base64Data = logoBase64;
                                base64Data = base64.normalize(base64Data);

                                final decodedBytes = base64Decode(base64Data);
                                // ------------------------------

                                // --- Display using Image.memory ---
                                // NOTE: This will FAIL if the decodedBytes represent an SVG image.
                                // If logos are SVG, you MUST use the 'flutter_svg' package instead.
                                // See comments below for SVG handling.
                                leadingWidget = Image.memory(
                                  decodedBytes,
                                  height: 40,
                                  width: 40,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) {
                                    // This errorBuilder catches issues during Image widget rendering
                                    print(
                                        "Error rendering decoded image bytes for $institutionName: $error");
                                    return const Icon(Icons.broken_image,
                                        size: 40, color: Colors.grey);
                                  },
                                );
                                // --- End Image.memory ---
                              } catch (e) {
                                print(
                                    "Exception processing logo string for $institutionName: $e");
                                // Fallback to default icon if decoding fails
                                leadingWidget = const Icon(
                                    Icons.account_balance,
                                    size: 40,
                                    color: Colors.grey);
                              }
                            }

                            return Slidable(
                              key: ValueKey(itemId), // Still need a unique key

                              // --- Define Start Action Pane (Right Swipe - Refresh) ---
                              startActionPane: ActionPane(
                                motion:
                                    const ScrollMotion(), // Or DrawerMotion(), BehindMotion(), etc.
                                // Extent ratio (how much of the item width the actions take)
                                extentRatio: 0.25,
                                // No dismissible needed here, just the actions
                                children: [
                                  SlidableAction(
                                    onPressed: (context) {
                                      _handleRefreshAccount(
                                          itemId, institutionName);
                                    },
                                    backgroundColor: Colors.blueAccent,
                                    foregroundColor: Colors.white,
                                    icon: Icons.refresh,
                                    label: 'Refresh',
                                  ),
                                ],
                              ),

                              // --- Define End Action Pane (Left Swipe - Unlink) ---
                              endActionPane: ActionPane(
                                motion: const ScrollMotion(),
                                extentRatio: 0.25,
                                // Make this one dismissible for the unlink action
                                dismissible: DismissiblePane(
                                  onDismissed: () {
                                    // This is called *after* dismiss animation completes
                                    _handleUnlinkAccount(
                                        itemId, institutionName);
                                  },
                                  // Optional: Add confirmation before dismissal starts
                                  confirmDismiss: () async {
                                    return await showDialog<bool>(
                                          context: context,
                                          builder: (BuildContext context) {
                                            return AlertDialog(
                                              title:
                                                  const Text('Confirm Unlink'),
                                              content: Text(
                                                  'Are you sure you want to unlink "$institutionName"? This will remove access to its data.'),
                                              actions: <Widget>[
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.of(context).pop(
                                                          false), // Don't dismiss
                                                  child: const Text('Cancel'),
                                                ),
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.of(context).pop(
                                                          true), // Confirm dismiss
                                                  child: const Text('Unlink',
                                                      style: TextStyle(
                                                          color: Colors
                                                              .redAccent)),
                                                ),
                                              ],
                                            );
                                          },
                                        ) ??
                                        false;
                                  },
                                ),
                                children: [
                                  SlidableAction(
                                    // Provide onPressed even with dismissible pane for accessibility/alternative tap
                                    onPressed: (context) async {
                                      bool? confirm = await showDialog<bool>(
                                            context: context,
                                            builder: (BuildContext context) {
                                              return AlertDialog(
                                                title: const Text(
                                                    'Confirm Unlink'),
                                                content: Text(
                                                    'Are you sure you want to unlink "$institutionName"? This will remove access to its data.'),
                                                actions: <Widget>[
                                                  TextButton(
                                                    onPressed: () => Navigator
                                                            .of(context)
                                                        .pop(
                                                            false), // Don't dismiss
                                                    child: const Text('Cancel'),
                                                  ),
                                                  TextButton(
                                                    onPressed: () => Navigator
                                                            .of(context)
                                                        .pop(
                                                            true), // Confirm dismiss
                                                    child: const Text('Unlink',
                                                        style: TextStyle(
                                                            color: Colors
                                                                .redAccent)),
                                                  ),
                                                ],
                                              );
                                            },
                                          ) ??
                                          false;
                                      if (confirm) {
                                        _handleUnlinkAccount(
                                            itemId, institutionName);
                                        // Optionally manually trigger dismiss if needed via SlidableController
                                      }
                                    },
                                    backgroundColor: Colors.redAccent,
                                    foregroundColor: Colors.white,
                                    icon: Icons.link_off,
                                    label: 'Unlink',
                                  ),
                                ],
                              ),

                              // --- The actual account item ---
                              child: ListTile(
                                leading: leadingWidget,
                                title: Text(institutionName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w500)),
                                subtitle: Text(lastSync),
                                // No swipe icon needed now
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
