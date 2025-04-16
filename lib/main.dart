// File: lib/main.dart

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart'; 
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'firebase_options.dart';
import 'features/auth/auth_gate.dart';
import 'features/onboarding/onboarding_screen.dart'; // Import OnboardingScreen

// Global variable to hold the onboarding status
bool showOnboarding = true;

void main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // --- Load Environment Variables ---
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print("Error loading .env file: $e"); // Might fail if file not found
  }
  // --------------------------------

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Check if onboarding is complete
  final prefs = await SharedPreferences.getInstance();
  // Get the flag, default to 'false' if not found (meaning onboarding is NOT complete)
  final bool onboardingComplete = prefs.getBool('onboarding_complete') ?? false;
  showOnboarding = !onboardingComplete; // Show onboarding if it's NOT complete

  // Now run the app
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Finance AI App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
        textTheme: const TextTheme( // Optional: Define text styles if needed
             headlineSmall: TextStyle(fontSize: 24.0, fontWeight: FontWeight.bold),
             bodyLarge: TextStyle(fontSize: 16.0),
           ),
      ),
      debugShowCheckedModeBanner: false,
      // Conditionally set the home screen based on the onboarding status
      home: showOnboarding ? const OnboardingScreen() : const AuthGate(),
    );
  }
}