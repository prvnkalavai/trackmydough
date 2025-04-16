// File: lib/features/auth/auth_gate.dart

import 'package:firebase_auth/firebase_auth.dart'; // Import FirebaseAuth
import 'package:flutter/material.dart';
import 'sign_in_screen.dart'; // Import the SignInScreen
import '../home/home_screen.dart'; // Import the HomeScreen

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      // Listen to the authentication state changes provided by Firebase Auth
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // --- 1. Handle Connection States ---
        // Show a loading indicator while waiting for the initial auth state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Show an error message if the stream encounters an error
        // (This is less common for authStateChanges but good practice)
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(child: Text('Something went wrong!')),
          );
        }

        // --- 2. Handle Authentication State ---
        // If snapshot has data, it means the user object is not null -> User is logged in
        if (snapshot.hasData) {
          // Navigate to the HomeScreen
          return const HomeScreen();
        } else {
          // If snapshot has no data, it means user is null -> User is logged out
          // Navigate to the SignInScreen
          return const SignInScreen();
        }
      },
    );
  }
}