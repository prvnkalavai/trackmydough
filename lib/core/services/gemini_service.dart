// File: lib/core/services/gemini_service.dart
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

class GeminiService {
  GenerativeModel? _model;
  bool _isInitialized = false;

  GeminiService() {
    _initialize();
  }
  void _initialize() {
    // Access the API key from the loaded environment variables
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      print('Error: GEMINI_API_KEY not found in .env file.');
      // Handle the error appropriately - maybe disable AI features
      _isInitialized = false;
      return;
    }

    // For text-only input, use the gemini-pro model
    _model = GenerativeModel(
      model: 'gemini-2.0-flash', // Or another suitable model like gemini-pro
      apiKey: apiKey,
      // Optional: Add safety settings, generation config etc.
      safetySettings: [
        // Example safety settings
        SafetySetting(HarmCategory.harassment, HarmBlockThreshold.medium),
        SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.medium),
        SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.medium),
        SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.medium),
      ],
      generationConfig: GenerationConfig(
        responseMimeType: "application/json", // Request JSON output
      ),
    );
    _isInitialized = true;

    print("Gemini Service Initialized.");
  }

  // --- Simple Test Function ---
  Future<String?> generateTestContent(String prompt) async {
    if (_model == null) {
      return "Error: Gemini model not initialized.";
    }

    try {
      print("Sending prompt to Gemini: '$prompt'");
      final response = await _model!.generateContent([
        Content.text(prompt) // Create Content object for text
      ]);
      print("Received response from Gemini.");
      // Make sure to check response.text before accessing
      return response.text;
    } catch (e) {
      print('Error generating content: $e');
      // Consider returning specific error messages or null
      return "Error generating content: ${e.toString()}";
    }
  }

  // --- NEW: Function for Intent Recognition ---
  /// Analyzes user query to extract intent and entities using Gemini.
  /// Returns a Map representing the JSON response { "intent": "...", "entities": {...} }
  /// or null if an error occurs or the model is not initialized.
  Future<Map<String, dynamic>?> extractIntentAndEntities(
      String userQuery) async {
    if (!_isInitialized || _model == null) {
      print("Error: Gemini model not initialized for intent extraction.");
      return null; // Return null or throw an error
    }

    // --- Define the prompt ---
    // This prompt needs refinement based on testing!
    // It instructs the model on its role, the expected output format (JSON),
    // and provides examples of intents and entities.
    final prompt = """
        Analyze the following user query about their personal finances. Identify the primary intent and any relevant entities.

        Possible Intents:
        - GET_RECENT_TRANSACTIONS: User wants to see a list of recent transactions.
        - GET_SPENDING_SUMMARY: User wants a total spending figure for a specific period.
        - GET_TRANSACTIONS_BY_CATEGORY: User wants transactions for a specific category.
        - GET_SPENDING_SUMMARY_BY_CATEGORY: User wants total spending for a category in a period. 
        - GET_TRANSACTIONS_BY_MERCHANT: User wants transactions for a specific merchant. 
        - GET_SPENDING_SUMMARY_BY_MERCHANT: User wants total spending for a merchant in a period. 
        - GET_RECEIPT_DETAILS: User wants to know what items were bought from a specific receipt/transaction. 
        - UNKNOWN: The intent is unclear or not finance-related.

        Possible Entities:
        - limit (number): The number of transactions requested.
        - period (string): Time frame like "today", "this week", "last month", "this month", "this year", "last year", "yesterday".
        - category (string): Spending category (e.g., "groceries", "restaurants", "transportation > ride share").
        - merchant (string): Specific merchant name (e.g., "Starbucks", "Costco Wholesale", "Amazon").
        - date (string): Specific date (try to normalize to YYYY-MM-DD) or relative date mentioned alongside merchant/category (e.g., "yesterday", "on Tuesday").

        Respond ONLY with a valid JSON object containing 'intent' and 'entities' keys.
        If no specific entities are found, return an empty 'entities' object {}.
        If no specific intent is recognized, use intent "UNKNOWN".

        Examples:
        Query: "Show my last 5 transactions"
        Response: {"intent": "GET_RECENT_TRANSACTIONS", "entities": {"limit": 5}}

        Query: "How much did I spend on groceries last week?"
        Response: {"intent": "GET_SPENDING_SUMMARY_BY_CATEGORY", "entities": {"category": "groceries", "period": "last_week"}} 

        Query: "What was my spending yesterday?"
        Response: {"intent": "GET_SPENDING_SUMMARY", "entities": {"period": "yesterday"}}

        Query: "starbucks spending this month" 
        Response: {"intent": "GET_SPENDING_SUMMARY_BY_MERCHANT", "entities": {"merchant": "Starbucks", "period": "this_month"}}

        Query: "list coffee shop transactions" 
        Response: {"intent": "GET_TRANSACTIONS_BY_CATEGORY", "entities": {"category": "coffee shop"}}

        Query: "Recent activity"
        Response: {"intent": "GET_RECENT_TRANSACTIONS", "entities": {}}

        Query: "What did I buy at Costco yesterday?" 
        Response: {"intent": "GET_RECEIPT_DETAILS", "entities": {"merchant": "Costco Wholesale", "period": "yesterday"}} 

        Query: "Show the receipt from Target on April 5th" 
        Response: {"intent": "GET_RECEIPT_DETAILS", "entities": {"merchant": "Target", "date": "2025-04-05"}} 

        Query: "What were the items on my last coffee shop transaction?" 
        Response: {"intent": "GET_RECEIPT_DETAILS", "entities": {"category": "coffee shop", "limit": 1}}

        Query: "What's the weather?"
        Response: {"intent": "UNKNOWN", "entities": {}}

        User Query: "$userQuery"
        Response:
      """;
    // --- End of prompt ---

    try {
      print("Sending intent extraction prompt to Gemini...");
      final response = await _model!.generateContent([Content.text(prompt)]);
      print("Received intent extraction response from Gemini.");

      final responseText = response.text;
      if (responseText == null || responseText.isEmpty) {
        print("Error: Gemini returned empty response for intent extraction.");
        return null;
      }

      print("Raw Gemini JSON response: $responseText"); // Log the raw response

      // --- Parse the JSON response ---
      try {
        // Attempt to decode the JSON string
        final jsonResponse = jsonDecode(responseText) as Map<String, dynamic>;

        // Basic validation of the parsed structure
        if (jsonResponse.containsKey('intent') &&
            jsonResponse.containsKey('entities') &&
            jsonResponse['entities'] is Map) {
          print("Successfully parsed JSON response: $jsonResponse");
          return jsonResponse;
        } else {
          print("Error: Parsed JSON has incorrect structure.");
          // Fallback if structure is wrong
          return {
            "intent": "UNKNOWN",
            "entities": {"error": "Invalid JSON structure from AI"}
          };
        }
      } catch (e) {
        print("Error decoding JSON response: $e");
        // Fallback if JSON parsing fails
        return {
          "intent": "UNKNOWN",
          "entities": {
            "error": "Failed to parse AI response as JSON",
            "raw_response": responseText
          }
        };
      }
      // --- End JSON Parsing ---
    } catch (e) {
      print('Error during Gemini intent extraction call: $e');
      // Consider returning a specific error structure or null
      return {
        "intent": "UNKNOWN",
        "entities": {"error": "Gemini API call failed: ${e.toString()}"}
      };
    }
  }
}
