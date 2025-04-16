// File: lib/features/auth/sign_in_screen.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>(); // Key for validating the form
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false; // To show loading indicator on buttons
  String? _errorMessage; // To display authentication errors

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // --- Authentication Logic ---

  Future<void> _handleAuth(bool isLogin) async {
    // Validate the form fields
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null; // Clear previous errors
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();
      final auth = FirebaseAuth.instance;

      if (isLogin) {
        // Sign In
        await auth.signInWithEmailAndPassword(email: email, password: password);
        // AuthGate will handle navigation if successful
      } else {
        // Sign Up (Create User)
        final userCredential = await auth.createUserWithEmailAndPassword(
            email: email, password: password); // Get the UserCredential

        // --- Add Firestore Document Creation ---
        if (userCredential.user != null) {
          // Check if user creation was successful
          final userId = userCredential.user!.uid;
          final userDocRef =
              FirebaseFirestore.instance.collection('users').doc(userId);

          // Create the document with initial data
          await userDocRef.set({
            'email': email, // Store email
            'createdAt': Timestamp.now(), // Store creation time
            'plaidItems': [], // Initialize as empty list
          });
        }
      }
      // If successful, the AuthGate's stream will update and navigate away.
      // No need for manual navigation here.
    } on FirebaseAuthException catch (e) {
      // Handle specific Firebase Auth errors
      setState(() {
        _errorMessage = e.message ?? 'An unknown error occurred.';
      });
    } catch (e) {
      // Handle other potential errors
      setState(() {
        _errorMessage = 'An unexpected error occurred: ${e.toString()}';
      });
    } finally {
      // Ensure loading indicator is turned off even if there's an error
      if (mounted) {
        // Check if the widget is still in the tree
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // --- Build Method ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign In / Sign Up'),
      ),
      body: Center(
        child: SingleChildScrollView(
          // Allows scrolling on smaller screens
          padding: const EdgeInsets.all(20.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment:
                  CrossAxisAlignment.stretch, // Make buttons stretch
              children: [
                const Text(
                  'Welcome!',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),

                // Email Field
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  validator: (value) {
                    if (value == null ||
                        value.trim().isEmpty ||
                        !value.contains('@')) {
                      return 'Please enter a valid email address.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 15),

                // Password Field
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                  obscureText: true, // Hide password characters
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Password cannot be empty.';
                    }
                    if (value.length < 6) {
                      // Firebase requires passwords to be at least 6 characters
                      return 'Password must be at least 6 characters long.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),

                // Error Message Display
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 15.0),
                    child: Text(
                      _errorMessage!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ),

                // Sign In Button
                ElevatedButton(
                  onPressed: _isLoading
                      ? null
                      : () => _handleAuth(true), // Pass true for login
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Sign In'),
                ),
                const SizedBox(height: 10),

                // Sign Up Button
                OutlinedButton(
                  onPressed: _isLoading
                      ? null
                      : () => _handleAuth(false), // Pass false for sign up
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.primary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2) // Use default color
                          )
                      : const Text('Create Account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
