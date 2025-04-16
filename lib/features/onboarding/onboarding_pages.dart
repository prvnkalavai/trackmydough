// File: lib/features/onboarding/onboarding_pages.dart
import 'package:flutter/material.dart';

// Helper widget for consistent page layout
class OnboardingPageContent extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const OnboardingPageContent({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 100,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 40),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Text(
            description,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// --- Define the actual pages using the helper ---

final List<Widget> onboardingPages = [
  const OnboardingPageContent(
    icon: Icons.wallet_outlined,
    title: 'Welcome to Finance AI!',
    description: 'Take control of your finances with AI-powered insights.',
  ),
  const OnboardingPageContent(
    icon: Icons.chat_bubble_outline,
    title: 'Conversational Finance',
    description: 'Ask questions about your spending in plain language.',
  ),
  const OnboardingPageContent(
    icon: Icons.receipt_long_outlined,
    title: 'Scan Receipts Easily',
    description: 'Get granular spending details by scanning your receipts.',
  ),
   const OnboardingPageContent(
    icon: Icons.security_outlined,
    title: 'Secure & Private',
    description: 'Your financial data is encrypted and protected. We use Plaid for secure bank linking.',
  ),
];