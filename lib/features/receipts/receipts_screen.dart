import 'package:flutter/material.dart';

class ReceiptsScreen extends StatelessWidget {
  const ReceiptsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipts'), // Change title for each screen
      ),
      body: const Center(
        child: Text('Receipts Screen - Content Coming Soon!'), // Change text
      ),
    );
  }
}