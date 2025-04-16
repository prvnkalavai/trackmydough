import 'package:flutter/material.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'), // Change title for each screen
      ),
      body: const Center(
        child: Text('Dashboard Screen - Content Coming Soon!'), // Change text
      ),
    );
  }
}