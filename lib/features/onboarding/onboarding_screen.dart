// File: lib/features/onboarding/onboarding_screen.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import '../auth/auth_gate.dart'; // To navigate after onboarding
import 'onboarding_pages.dart'; // Import the page content

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  // Use the list of pages defined separately
  final List<Widget> _pages = onboardingPages;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // Function called when onboarding is completed or skipped
  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    // Set the flag indicating onboarding is done
    await prefs.setBool('onboarding_complete', true);

    // Navigate to the AuthGate, replacing the onboarding screen
    if (mounted) { // Check if the widget is still in the widget tree
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const AuthGate()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea( // Ensure content doesn't overlap system UI
        child: Column(
          children: [
            // --- Skip Button ---
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _completeOnboarding, // Skip also completes onboarding
                child: const Text('Skip'),
              ),
            ),

            // --- PageView ---
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                itemBuilder: (_, index) => _pages[index],
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
              ),
            ),

            // --- Indicator ---
            Padding(
              padding: const EdgeInsets.only(bottom: 20.0),
              child: SmoothPageIndicator(
                controller: _pageController,
                count: _pages.length,
                effect: WormEffect( // Choose an effect you like
                  dotHeight: 10,
                  dotWidth: 10,
                  activeDotColor: Theme.of(context).colorScheme.primary,
                ),
                onDotClicked: (index) {
                  _pageController.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeInOut,
                  );
                },
              ),
            ),

            // --- Next / Get Started Button ---
            Padding(
              padding: const EdgeInsets.only(left: 20, right: 20, bottom: 40),
              child: ElevatedButton(
                onPressed: () {
                  if (_currentPage == _pages.length - 1) {
                    // Last page: Complete onboarding
                    _completeOnboarding();
                  } else {
                    // Not the last page: Go to the next page
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeInOut,
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50), // Make button taller
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(
                  _currentPage == _pages.length - 1 ? 'Get Started' : 'Next',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}