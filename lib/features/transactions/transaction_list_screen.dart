// File: lib/features/transactions/transaction_list_screen.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart'; // For formatting

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key});

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Stream<QuerySnapshot>? _transactionStream;
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    _currentUser = _auth.currentUser;
    if (_currentUser != null) {
      _transactionStream = _firestore
          .collection('transactions')
          .where('userId', isEqualTo: _currentUser!.uid) // Filter by user ID
          .orderBy('date', descending: true) // Order by date, newest first
          .limit(100) // Limit initial load (optional, add pagination later)
          .snapshots(); // Get real-time updates
    }
  }

  @override
  Widget build(BuildContext context) {
    // Formatters (initialize once)
    final DateFormat dateFormat = DateFormat('MMM d, yyyy'); // e.g., Apr 11, 2025
    final NumberFormat currencyFormat = NumberFormat.currency(
        locale: 'en_US', // Adjust locale as needed
        symbol: '\$'); // Adjust symbol as needed

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent Transactions'),
      ),
      body: _currentUser == null
          ? const Center(child: Text('Please log in to view transactions.'))
          : StreamBuilder<QuerySnapshot>(
              stream: _transactionStream,
              builder: (BuildContext context, AsyncSnapshot<QuerySnapshot> snapshot) {
                // --- Handle Loading State ---
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                // --- Handle Error State ---
                if (snapshot.hasError) {
                  print('Firestore Stream Error: ${snapshot.error}'); // Log error
                  return Center(child: Text('Error loading transactions: ${snapshot.error}'));
                }

                // --- Handle No Data State ---
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No transactions found.\nTry fetching transactions first.',
                      textAlign: TextAlign.center,
                    ),
                  );
                }

                // --- Display Data ---
                final transactions = snapshot.data!.docs;

                return ListView.builder(
                  itemCount: transactions.length,
                  itemBuilder: (context, index) {
                    // Extract data safely from the document snapshot
                    final doc = transactions[index];
                    final data = doc.data() as Map<String, dynamic>?; // Cast data

                    // Use default values or handle nulls gracefully
                    final String name = data?['merchantName'] ?? data?['name'] ?? 'N/A';
                    final double amount = (data?['amount'] as num?)?.toDouble() ?? 0.0;
                    final Timestamp? dateTimestamp = data?['date'] as Timestamp?;
                    final String dateString = dateTimestamp != null
                        ? dateFormat.format(dateTimestamp.toDate())
                        : 'No date';
                    final bool isPending = data?['pending'] ?? false;

                    // Determine text color based on amount
                    final Color amountColor = amount >= 0 ? Colors.green.shade700 : Colors.black87;

                    return ListTile(
                      leading: Icon(
                        isPending ? Icons.hourglass_empty : Icons.receipt_long,
                        color: isPending ? Colors.orange : Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(name),
                      subtitle: Text(dateString),
                      trailing: Text(
                        currencyFormat.format(amount),
                        style: TextStyle(
                          color: amountColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      // Optional: Add onTap for transaction details later
                      // onTap: () { /* Navigate to detail screen */ },
                    );
                  },
                );
              },
            ),
    );
  }
}