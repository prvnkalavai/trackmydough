import {logger} from "firebase-functions";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {defineString, defineSecret} from "firebase-functions/params";
import {PlaidApi, Configuration, PlaidEnvironments, Products, CountryCode,
  TransactionsSyncRequest, Transaction as PlaidTransaction, InstitutionsGetByIdRequest} from "plaid";
import * as admin from "firebase-admin";
import {Timestamp} from "firebase-admin/firestore";
import {Buffer} from "buffer";
import {GoogleGenerativeAI, HarmCategory, HarmBlockThreshold, Part} from "@google/generative-ai";


interface PlaidItemData {
    itemId: string;
    accessToken: string;
    institutionName: string | null;
    institutionId: string | null;
    syncCursor?: string | null;
    lastSync?: Timestamp | null;
    addedAt?: Timestamp;
    status?: "active" | "error" | "login_required";
    lastSyncError?: string | null;
  }

// --- Firebase Admin SDK Initialization ---
if (!admin.apps.length) {
  admin.initializeApp();
}
const db = admin.firestore(); // Get Firestore instance

// --- Define Configuration Parameters ---
const plaidClientId = defineString("PLAID_CLIENT_ID");
const plaidEnvName = defineString("PLAID_ENV");
const plaidSecret = defineSecret("PLAID_SECRET");
const geminiApiKey = defineString("GEMINI_API_KEY");

// --- Helper function using Parameters ---
/**
 * Initializes and returns a Plaid API client instance
 * based on defined parameters.
 * Reads PLAID_CLIENT_ID, PLAID_ENV, and PLAID_SECRET parameters.
 * Throws an HttpsError if parameters are missing or initialization fails.
 *
 * @param {string} clientId - Plaid Client ID from parameter.
 * @param {string} secret - Plaid Secret from parameter.
 * @param {string} envName - Plaid Environment name from parameter.
 * @return {PlaidApi} An initialized PlaidApi client instance.
 * @throws {HttpsError} If initialization fails.
 */
function getPlaidClientWithParams(clientId: string, secret: string, envName: string): PlaidApi {
  logger.info("Inside getPlaidClientWithParams: Using provided parameters.");

  // Validation (Parameters framework helps, but explicit check is good)
  if (!clientId || !secret || !envName) {
    logger.error(
      "CRITICAL ERROR: Plaid parameters provided are invalid (empty).", {
        hasClientId: !!clientId,
        hasSecret: !!secret,
        hasEnv: !!envName,
      });
    throw new HttpsError(
      "internal", "Server configuration error (invalid params).");
  }

  const plaidEnv = envName === "sandbox" ? PlaidEnvironments.sandbox :
    envName === "development" ? PlaidEnvironments.development :
      PlaidEnvironments.production;

  try {
    logger.info(
      "Attempting to create Plaid Configuration object from params...");
    const configuration = new Configuration({
      basePath: plaidEnv,
      baseOptions: {
        headers: {
          "PLAID-CLIENT-ID": clientId,
          "PLAID-SECRET": secret,
          "Plaid-Version": "2020-09-14",
        },
      },
    });
    logger.info("Plaid Configuration object created from params.");

    logger.info("Attempting to create PlaidApi instance from params...");
    const client = new PlaidApi(configuration);
    logger.info("PlaidApi instance created successfully from params.");
    return client;
  } catch (initError: unknown) {
    let errorMessage = "Unknown error during Plaid client initialization";
    const errorStack = undefined;
    if (initError instanceof Error) {
      errorMessage = initError.message;
      // errorStack = initError.stack;
    }
    logger.error("ERROR initializing Plaid client from params:", {
      error: errorMessage,
      stack: errorStack, // Log stack if available
    });
    // Throw HttpsError with the specific message if available
    throw new HttpsError("internal"
      , `Plaid client initialization failed: ${errorMessage}`);
  }
}

// --- HTTPS Callable Function: createLinkToken (using v2 onCall) ---
export const createLinkToken = onCall(
  {
    // Reference the defined secret parameter for access
    secrets: [plaidSecret],
    // You can set parameter defaults here if needed,or rely on .env files/CLI
  },
  async (request) => { // Use request type from v2/https
    // 1. Auth Check (v2 uses request.auth.uid directly)
    if (!request.auth) {
      logger.error("Authentication Error: User is not authenticated.");
      throw new HttpsError(
        "unauthenticated", "The function must be called while authenticated.");
    }
    const userId = request.auth.uid;
    logger.info(`User authenticated: ${userId}`);

    // Initialize Plaid Client using Parameters
    let _plaidClient: PlaidApi;
    try {
      logger.info("Attempting to initialize Plaid client using parameters...");
      // Get parameter values using .value()
      _plaidClient = getPlaidClientWithParams(
        plaidClientId.value(),
        plaidSecret.value(),
        plaidEnvName.value()
      );
      logger.info(_plaidClient +
                "obtained successfully using parameters inside handler.");
    } catch (error) {
      logger.error(
        "Failed to initialize Plaid client using parameters inside handler."
        , {userId: userId, error: error});
      if (error instanceof HttpsError) {
        throw error;
      } else {
        throw new HttpsError("internal"
          , "Failed to initialize Plaid client using parameters.");
      }
    }

    const linkTokenRequest = {
      user: {client_user_id: userId},
      client_name: "Finance AI App",
      products: [Products.Auth, Products.Transactions],
      country_codes: [CountryCode.Us],
      language: "en",
    };
    logger.info("Link token request prepared.");

    // --- Make the actual Plaid API call ---
    try {
      logger.info("Attempting to call plaidClient.linkTokenCreate...");
      const response = await _plaidClient.linkTokenCreate(linkTokenRequest);
      const linkToken = response.data.link_token;
      logger.info(`Successfully created link token for user: ${userId}`);
      return {link_token: linkToken};
    } catch (error: unknown) { // <-- Catch as unknown
      let errorMessage = "Unknown error during Plaid API call";
      let errorDetails: unknown = null;
      let errorStack: string | undefined = undefined;

      if (error instanceof Error) {
        errorMessage = error.message;
        errorStack = error.stack; // Capture stack from Error instance

        // --- Safer check for Plaid-like error structure ---
        // Check if 'error' is an object and has 'response' property
        if (typeof error === "object" &&
                    error !== null && "response" in error) {
          const errorResponse = (error as { response?: unknown }).response;
          // Check if 'response' is an object and has 'data' property
          if (typeof errorResponse === "object" &&
                        errorResponse !== null && "data" in errorResponse) {
            errorDetails = (errorResponse as { data?: unknown }).data;
          }
        }
        // --- End of safer check ---
      } else {
        // Handle cases where the thrown value isn't an Error object
        try {
          errorMessage = JSON.stringify(error);
        } catch {
          errorMessage =
                        "Failed to stringify non-Error object caught in catch block.";
        }
      }
      logger.error("Plaid API Error: Failed to create link token.", {
        userId: userId,
        error: errorMessage,
        plaidDetails: errorDetails, // Log Plaid-specific details if available
        stack: errorStack,
      });
      throw new HttpsError(
        "internal", `Failed to create Plaid link token: ${errorMessage}`
        , errorDetails);
    }
  });

// --- NEW: exchangePublicToken Function ---
/**
 * Exchanges a Plaid public_token for an access_token and item_id,
 * then securely stores the item details in Firestore for the authenticated user.
 */
export const exchangePublicToken = onCall(
  {secrets: [plaidSecret]},
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("exchangePublicToken: Authentication Error.");
      throw new HttpsError("unauthenticated", "The function must be called while authenticated.");
    }
    const userId = request.auth.uid;
    logger.info(`exchangePublicToken: Authenticated user: ${userId}`);

    // 2. Validate Input Data
    const publicToken = request.data.publicToken;
    let institutionName = request.data.institutionName;
    let institutionId = request.data.institutionId;

    if (!publicToken || typeof publicToken !== "string") {
      logger.error("exchangePublicToken: Invalid argument - publicToken missing or not a string.", {data: request.data});
      throw new HttpsError("invalid-argument", "The function must be called with a valid 'publicToken'.");
    }
    logger.info(`exchangePublicToken: Received public token: ${publicToken.substring(0, 15)}...`);

    // 3. Initialize Plaid Client
    let plaidClient: PlaidApi;
    try {
      plaidClient = getPlaidClientWithParams(
        plaidClientId.value(),
        plaidSecret.value(),
        plaidEnvName.value()
      );
    } catch (error) {
      logger.error("exchangePublicToken: Failed to initialize Plaid client."
        , {userId: userId, error: error});
      if (error instanceof HttpsError) {
        throw error;
      } else {
        throw new HttpsError("internal", "Failed to initialize Plaid client.");
      }
    }

    // 4. Exchange Public Token via Plaid API
    let exchangeResponse;
    try {
      logger.info(`exchangePublicToken: Attempting to exchange public token for user ${userId}...`);
      exchangeResponse = await plaidClient.itemPublicTokenExchange({public_token: publicToken});
      logger.info(`exchangePublicToken: Successfully exchanged public token for user ${userId}.`);
    } catch (error: unknown) {
      // Handle Plaid API error during exchange
      let errorMessage = "Unknown error during Plaid token exchange";
      let errorDetails: unknown = null;
      let errorStack: string | undefined = undefined;
      if (error instanceof Error) {
        errorMessage = error.message;
        errorStack = error.stack;
      }
      // Extract Plaid details if possible (similar to createLinkToken)
      if (typeof error === "object" && error !== null && "response" in error) {
        const errorResponse = (error as { response?: unknown }).response;
        if (typeof errorResponse === "object" && errorResponse !== null && "data" in errorResponse) {
          errorDetails = (errorResponse as { data?: unknown }).data;
          logger.warn("Plaid error response data captured:", {plaidErrorData: errorDetails}); // Log the details
        }
      } else {
        // Handle non-Error throwables
        try {
          errorMessage = JSON.stringify(error);
        } catch {/* ignore */}
      }

      logger.error("exchangePublicToken: Plaid API Error during token exchange.", {
        userId: userId, error: errorMessage, plaidDetails: errorDetails, stack: errorStack,
      });
      throw new HttpsError("internal", `Plaid token exchange failed: ${errorMessage}`, errorDetails);
    }

    // 5. Extract Access Token and Item ID
    const accessToken = exchangeResponse.data.access_token;
    const itemId = exchangeResponse.data.item_id;

    if (!accessToken || !itemId) {
      logger.error("exchangePublicToken: Access token or Item ID missing in Plaid response.", {responseData: exchangeResponse.data});
      throw new HttpsError("internal", "Invalid response received from Plaid after token exchange.");
    }
    logger.info(`exchangePublicToken: Received Plaid Item ID: ${itemId}`); // Don't log access token

    // 6. Fetch Institution Details (including Logo) ---
    let logoBase64: string | null = null;
    try {
      logger.info(`exchangePublicToken: Fetching institution details for item ${itemId}...`);
      // Assuming CountryCode.Us for now, adjust if supporting multiple countries
      const countryCodes = [CountryCode.Us];
      const institutionsRequest: InstitutionsGetByIdRequest = {
        institution_id: institutionId ?? "ins_0", // Requires the institution ID. If not passed from client, this WILL fail reliably.
        // It's better to ensure institutionId IS passed from client metadata.
        // Using a placeholder like 'ins_0' is just to prevent immediate crash if null.
        country_codes: countryCodes,
        options: {include_optional_metadata: true}, // Ensure metadata like logo is included
      };

      // Check if we actually have a valid institution ID before calling
      if (institutionId && institutionId !== "Unknown ID") {
        const institutionResponse = await plaidClient.institutionsGetById(institutionsRequest);

        if (institutionResponse.data.institution) {
          const institution = institutionResponse.data.institution;
          // Update name/id if they were missing/different from client metadata
          institutionName = institution.name;
          institutionId = institution.institution_id; // Use the definitive ID from Plaid

          if (institution.logo) {
            logger.info(`exchangePublicToken: Logo found for institution ${institutionId}. Encoding to base64...`);
            // Plaid logo is typically base64 already, but documentation is ambiguous.
            // Treating it as binary data and encoding ensures correctness.
            // If it IS base64, Buffer.from(..., 'base64').toString('base64') is idempotent.
            // If it's PNG/SVG binary, Buffer.from(..., 'binary').toString('base64') encodes it.
            logoBase64 = Buffer.from(institution.logo, "binary").toString("base64");
            logger.info("exchangePublicToken: Logo encoded successfully.");
          } else {
            logger.info(`exchangePublicToken: No logo found in Plaid response for institution ${institutionId}.`);
          }
        } else {
          logger.warn(`exchangePublicToken: Institution details not found in Plaid response for ID ${institutionId}.`);
        }
      } else {
        logger.warn(`exchangePublicToken: Skipping institution details fetch because institutionId was missing or invalid ('${institutionId}').`);
      }
    } catch (error: unknown) {
      // Log the error but continue without logo if this specific call fails
      let errorMessage = "Unknown error fetching institution details";
      if (error instanceof Error) {
        errorMessage = error.message;
      }
      logger.error(`exchangePublicToken: Failed to fetch institution details for item ${itemId}. Proceeding without logo.`, {
        itemId: itemId, userId: userId, error: errorMessage,
      });
      // Optionally check for Plaid-specific errors here too
    }

    // 7. Store Item Details in Firestore
    const userDocRef = db.collection("users").doc(userId);
    try {
      const nowTimestamp = Timestamp.now();
      logger.info(`exchangePublicToken: Preparing final item data for Firestore for item ${itemId}...`);

      const newItemData = {
        itemId: itemId,
        accessToken: accessToken,
        institutionName: institutionName ?? null, // Use potentially updated name
        institutionId: institutionId ?? null, // Use potentially updated ID
        logoBase64: logoBase64, // Add the base64 logo string (will be null if fetch failed/no logo)
        lastSync: nowTimestamp,
        addedAt: nowTimestamp,
        status: "active",
      };

      // Log structure before saving (excluding sensitive data)
      const loggableData = {...newItemData, accessToken: "[REDACTED]", logoBase64: logoBase64 ? "[BASE64_PRESENT]" : null};
      logger.info("exchangePublicToken: Final newItemData prepared:", {data: loggableData});

      logger.info(`exchangePublicToken: Attempting set/merge with arrayUnion for user ${userId}...`);
      await userDocRef.set({
        email: request.auth.token.email ?? null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        plaidItems: admin.firestore.FieldValue.arrayUnion(newItemData),
      }, {merge: true});

      logger.info(`exchangePublicToken: Successfully saved Plaid item ${itemId} for user ${userId}.`);
    } catch (error: unknown) {
      let errorMessage = "Unknown Firestore error";
      if (error instanceof Error) {
        errorMessage = error.message;
      }
      logger.error(`exchangePublicToken:  Failed to save Plaid item details to Firestore for user ${userId}.`, {
        itemId: itemId, error: errorMessage,
        stack: (error instanceof Error) ? error.stack : undefined,
      });
      // Critical: If storing fails, the access token is lost.
      //  May need manual intervention.
      throw new HttpsError("internal", `Failed to save account details: ${errorMessage}`);
    }

    // 6. Return Success Response to Client
    logger.info(`exchangePublicToken: Process completed successfully for user ${userId}, item ${itemId}.`);
    return {success: true, itemId: itemId};
  }
);

// --- NEW: fetchTransactions Function ---
/**
 * Fetches transactions from Plaid for all linked items for the calling user
 * using the /transactions/sync endpoint and saves them to Firestore.
 */
export const fetchTransactions = onCall(
  {secrets: [plaidSecret]}, // Ensure plaidSecret parameter is defined globally
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("fetchTransactions: Authentication Error.");
      throw new HttpsError("unauthenticated", "Function must be called while authenticated.");
    }
    const userId = request.auth.uid;
    logger.info(`fetchTransactions: Starting for user: ${userId}`);

    // 2. Initialize Plaid Client
    let plaidClient: PlaidApi;
    try {
      // Assumes plaidClientId, plaidSecret, plaidEnvName parameters are defined globally
      // and getPlaidClientWithParams function exists and works correctly
      plaidClient = getPlaidClientWithParams(
        plaidClientId.value(),
        plaidSecret.value(),
        plaidEnvName.value()
      );
    } catch (error) {
      logger.error("fetchTransactions: Failed to initialize Plaid client.", {userId: userId, error: error});
      if (error instanceof HttpsError) {
        throw error;
      } else {
        throw new HttpsError("internal", "Failed to initialize Plaid client.");
      }
    }

    // 3. Get User's Plaid Items from Firestore
    const userDocRef = db.collection("users").doc(userId);
    let userDocSnapshot;
    let plaidItems: PlaidItemData[] = []; // Use the specific type
    try {
      userDocSnapshot = await userDocRef.get();
      if (!userDocSnapshot.exists) {
        logger.warn(`fetchTransactions: User document ${userId} not found.`);
        return {success: false, message: "User profile not found."};
      }
      // Get plaidItems data, ensure it's an array, and cast
      const itemsData = userDocSnapshot.data()?.plaidItems;
      if (Array.isArray(itemsData)) {
        // Could add more validation here later if needed
        plaidItems = itemsData as PlaidItemData[];
        logger.info(`fetchTransactions: Found ${plaidItems.length} Plaid items for user ${userId}.`);
      } else {
        logger.info(`fetchTransactions: plaidItems field is missing or not an array for user ${userId}.`);
      }

      if (plaidItems.length === 0) {
        logger.info(`fetchTransactions: No Plaid items linked for user ${userId}.`);
        return {success: true, message: "No accounts linked."};
      }
    } catch (error: unknown) {
      logger.error(`fetchTransactions: Failed to read user document ${userId}.`, {error});
      throw new HttpsError("internal", "Failed to read user data.");
    }

    // 4. Process Each Plaid Item
    let totalTransactionsAdded = 0;
    const updatedPlaidItems: PlaidItemData[] = []; // Build the updated array here

    // Process items sequentially for simpler logic (can be parallelized later if needed)
    for (const currentItem of plaidItems) {
      // Create a mutable copy for this iteration's updates
      const item: PlaidItemData = {...currentItem};
      const accessToken = item.accessToken;
      const itemId = item.itemId;
      let cursor = item.syncCursor || null;

      if (!accessToken || !itemId) {
        logger.warn(`fetchTransactions: Skipping item ${item.itemId ?? "UNKNOWN"} for user ${userId} due to missing accessToken or itemId.`);
        updatedPlaidItems.push(item); // Add unmodified item back to the results array
        continue;
      }

      logger.info(`fetchTransactions: Processing item ${itemId} for user ${userId}. Cursor: ${cursor ? "Exists" : "None (Initial Sync?)"}`);

      let hasMore = true;
      let transactionsToAdd: PlaidTransaction[] = [];
      let currentItemSucceeded = true; // Flag for this item's sync success

      // Loop to handle pagination from Plaid /transactions/sync
      while (hasMore) {
        try {
          const syncRequest: TransactionsSyncRequest = {
            access_token: accessToken,
            cursor: cursor ?? undefined,
            count: 100, // Adjust count as needed
          };
          logger.info(`fetchTransactions: Calling Plaid /transactions/sync for item ${itemId}...`);
          const response = await plaidClient.transactionsSync(syncRequest);
          const data = response.data;

          // --- Accumulate transactions ---
          transactionsToAdd = transactionsToAdd.concat(data.added);
          // TODO: Handle data.modified and data.removed later

          hasMore = data.has_more;
          cursor = data.next_cursor; // Update cursor for the next page/sync
          logger.info(`fetchTransactions: Sync page processed for item ${itemId}. Has More: ${hasMore}. Added (page): ${data.added.length}`);
        } catch (error: unknown) {
          logger.error(`fetchTransactions: Plaid API Error during /transactions/sync for item ${itemId}.`, {userId, itemId, error});
          // TODO: Handle specific Plaid errors like ITEM_LOGIN_REQUIRED more gracefully
          hasMore = false; // Stop pagination loop on error for this item
          currentItemSucceeded = false; // Mark as failed
          item.status = "error"; // Update status
          item.lastSyncError = error instanceof Error ? error.message : JSON.stringify(error); // Store error
        }
      } // End while(hasMore) loop

      // --- Save Fetched Transactions to Firestore using Batch ---
      if (transactionsToAdd.length > 0) {
        const batch = db.batch();
        logger.info(`fetchTransactions: Saving ${transactionsToAdd.length} transactions to Firestore batch for item ${itemId}...`);

        transactionsToAdd.forEach((tx) => {
          // Use Plaid's transaction_id as the Firestore document ID for idempotency
          const txDocRef = db.collection("transactions").doc(tx.transaction_id);
          batch.set(txDocRef, {
            // --- Map Plaid Transaction to Firestore Schema ---
            userId: userId,
            plaidItemId: itemId,
            plaidAccountId: tx.account_id,
            plaidTransactionId: tx.transaction_id,
            name: tx.name,
            merchantName: tx.merchant_name ?? tx.name, // Prefer merchant_name
            amount: tx.amount * -1, // Invert amount for expense tracking convention
            currencyCode: tx.iso_currency_code,
            date: Timestamp.fromDate(new Date(tx.date)), // Convert date string
            authorizedDate: tx.authorized_date ? Timestamp.fromDate(new Date(tx.authorized_date)) : null,
            pending: tx.pending,
            pendingTransactionId: tx.pending_transaction_id,
            category: tx.category ?? [], // Array of strings from Plaid
            // customCategory: null, // Add later for user/AI categorization
            paymentChannel: tx.payment_channel,
            transactionType: tx.transaction_type,
            // --- End Schema Mapping ---
            fetchedAt: Timestamp.now(), // Record processing time
          });
        });

        try {
          await batch.commit();
          logger.info(`fetchTransactions: Firestore batch commit successful for ${transactionsToAdd.length} transactions.`);
          totalTransactionsAdded += transactionsToAdd.length;
        } catch (error: unknown) {
          logger.error(`fetchTransactions: Firestore batch commit failed for item ${itemId}. Some transactions may be lost.`
            , {userId, itemId, error});
          // Mark item as potentially problematic?
          currentItemSucceeded = false;
          item.status = "error";
          item.lastSyncError = `Firestore batch commit failed: ${error instanceof Error ? error.message : JSON.stringify(error)}`;
        }
      } else {
        logger.info(`fetchTransactions: No new transactions to add for item ${itemId}.`);
      }

      // --- Update the item object with latest sync info ---
      item.syncCursor = cursor; // Update cursor regardless of success/failure
      item.lastSync = Timestamp.now(); // Update sync time regardless
      if (currentItemSucceeded && item.status !== "active") {
        // If sync succeeded this time, clear previous error state
        item.status = "active";
        // Use FieldValue.delete() only when updating, not when building the object
        // We handle this by setting item.lastSyncError = null or simply not including it if clearing
        item.lastSyncError = null; // Clear error message
      }
      // Remove null error field if it exists to keep data clean
      if (item.lastSyncError === null) {
        delete item.lastSyncError;
      }

      // Add the processed item (potentially updated) to our results array
      updatedPlaidItems.push(item);
    } // End for loop processing each item

    // --- Update the plaidItems array in Firestore ---
    // Check if the array content has actually changed before writing
    // Note: Simple JSON.stringify might not detect Timestamp/FieldValue changes reliably.
    // A more robust check might compare cursors/statuses/sync times.
    // For simplicity, we'll update if the length changed or if any item status is now 'error'
    // or if totalTransactionsAdded > 0 (which implies lastSync changed).
    const hasErrors = updatedPlaidItems.some((item) => item.status === "error");
    if (plaidItems.length !== updatedPlaidItems.length || hasErrors || totalTransactionsAdded > 0 /* Simplistic change check */) {
      try {
        logger.info(`fetchTransactions: Updating plaidItems array in Firestore for user ${userId}...`);
        await userDocRef.update({plaidItems: updatedPlaidItems});
        logger.info(`fetchTransactions: Successfully updated plaidItems array for user ${userId}.`);
      } catch (error: unknown) {
        logger.error(`fetchTransactions: Failed to update plaidItems array for user ${userId}. Cursors/status might be stale.`, {userId, error});
        // Decide how critical this is - maybe throw HttpsError?
      }
    } else {
      logger.info("fetchTransactions: No significant changes to plaidItems array detected, skipping Firestore update.");
    }

    // --- Trigger Insight Generation (if new transactions added) ---
    if (totalTransactionsAdded > 0) {
      logger.info(`fetchTransactions: Triggering insight generation for user ${userId} due to new transactions.`);
      try {
        // No need to await if running insights generation in background is acceptable
        // NOTE: For callable functions, direct invocation isn't standard.
        // BETTER APPROACH: Use Pub/Sub or Task Queues to trigger generateInsights
        // For simplicity now, we'll just log a message. Proper triggering needs different architecture.
        // await generateInsights({ auth: request.auth }); // This direct call might not work as expected for callables

        logger.warn("generateInsights triggering needs refactoring (e.g., Pub/Sub). Manual trigger required for now.");
        // In a real app, publish a message to a Pub/Sub topic here
        // const pubSubClient = new PubSub();
        // await pubSubClient.topic('generate-user-insights').publishMessage({ data: Buffer.from(userId) });
      } catch (insightError) {
        logger.error(`fetchTransactions: Error trying to trigger insight generation for user ${userId}`, {insightError});
      }
    }


    // 5. Return Success Response
    logger.info(`fetchTransactions: Completed for user ${userId}. Total new transactions added: ${totalTransactionsAdded}.`);
    return {success: true, transactionsAdded: totalTransactionsAdded};
  }
);

// --- NEW: getFinancialData Function ---
/**
 * Processes financial queries based on intent and entities identified by the client-side NLU.
 * Fetches data from Firestore and returns a formatted text response.
 */
export const getFinancialData = onCall(
  async (request) => {
    // 1. Authentication Check ...
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "...");
    }
    const userId = request.auth.uid;
    logger.info(`getFinancialData: Starting for user: ${userId}`);

    // 2. Extract Intent and Entities ...
    const intent = request.data.intent as string | undefined;
    const rawEntities = request.data.entities as unknown | undefined;
    let entities: Record<string, unknown> = {};
    if (typeof rawEntities === "object" && rawEntities !== null) {
      entities = rawEntities as Record<string, unknown>;
    }
    if (!intent) {
      throw new HttpsError("invalid-argument", "Missing 'intent'.");
    }
    logger.info(`getFinancialData: Intent: ${intent}`, {entities});

    // 3. Process Based on Intent
    const baseTransactionQuery = db.collection("transactions").where("userId", "==", userId);
    const baseReceiptQuery = db.collection("receipts").where("userId", "==", userId);
    let responseText = "Sorry, I couldn't understand that request.";
    // const defaultPeriod = 'this_month';

    try {
      const baseQuery = db.collection("transactions").where("userId", "==", userId);
      let finalQuery: admin.firestore.Query = baseQuery; // Initialize with base query
      const defaultPeriod = "this_month";

      switch (intent) {
      // --- Case: Get Recent Transactions ---
      case "GET_RECENT_TRANSACTIONS": {
        let limit = 5;
        const limitEntity = entities.limit;
        if (typeof limitEntity === "number" && Number.isInteger(limitEntity) && limitEntity > 0) {
          limit = limitEntity;
        }
        logger.info(`Processing GET_RECENT_TRANSACTIONS with limit ${limit}`);

        finalQuery = baseQuery.orderBy("date", "desc").limit(limit);
        const querySnapshot = await finalQuery.get();

        if (querySnapshot.empty) {
          responseText = "You don't have any transactions yet.";
        } else {
          const transactions = querySnapshot.docs.map((doc) => doc.data());
          responseText = `Okay, here are your last ${transactions.length} transactions:\n`;
          transactions.forEach((tx) => {/* ... format transaction line ... */
            const date = (tx.date as Timestamp)?.toDate();
            const dateString = date ? `${date.getMonth() + 1}/${date.getDate()}` : "N/A";
            const amount = tx.amount ?? 0;
            const name = tx.merchantName ?? tx.name ?? "Unknown";
            const amountString = amount.toLocaleString("en-US", {style: "currency", currency: tx.currencyCode ?? "USD"});
            responseText += `- ${dateString}: ${name} ${amountString}\n`;
          });
        }
        break;
      } // End case GET_RECENT_TRANSACTIONS

      // --- Case: Get Spending Summary ---
      case "GET_SPENDING_SUMMARY": {
        const period = entities.period as string | undefined ?? "this_month"; // Default if not provided
        logger.info(`Processing GET_SPENDING_SUMMARY for period '${period}'`);

        const dateRange = getDateRange(period);
        if (!dateRange) {
          responseText = `Sorry, I don't understand the time period "${period}". Try 'today', 'this week', 'last month', etc.`;
          break;
        }

        finalQuery = baseQuery
          .where("date", ">=", dateRange.start)
          .where("date", "<=", dateRange.end)
          .where("amount", "<", 0); // Only sum expenses (negative amounts inverted by fetcher)

        const querySnapshot = await finalQuery.get();
        let totalSpending = 0;
        querySnapshot.forEach((doc) => {
          totalSpending += (doc.data().amount ?? 0);
        });

        const totalString = Math.abs(totalSpending).toLocaleString("en-US", {style: "currency", currency: "USD"}); // Assuming USD for now
        responseText = `You spent ${totalString} ${period.replace(/_/g, " ")}.`;
        break;
      } // End case GET_SPENDING_SUMMARY


      // --- Case: Get Transactions By Category ---
      case "GET_TRANSACTIONS_BY_CATEGORY": {
        let category = entities.category as string | undefined;
        const period = entities.period as string | undefined;
        let limit = 5; // Default limit for category search
        if (typeof entities.limit === "number" && Number.isInteger(entities.limit) && entities.limit > 0) {
          limit = entities.limit;
        }
        if (category) {
          category = category.toLowerCase().split(" ").map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(" ");
        }

        if (!category) {
          responseText = "Please specify a category (e.g., 'show grocery spending').";
          break;
        }
        logger.info(`Processing GET_TRANSACTIONS_BY_CATEGORY for '${category}', period '${period}', limit ${limit}`);

        // Start building query
        let transactionQuery = baseTransactionQuery;
        // let categoryQuery = baseQuery.where("category", "array-contains", category); // Use array-contains
        let periodDescription = "";
        const dateRange = period ? getDateRange(period) : null;

        if (dateRange) {
          transactionQuery = transactionQuery.where("date", ">=", dateRange.start).where("date", "<=", dateRange.end);
          periodDescription = ` ${(period ?? "").replace(/_/g, " ")}`;
        }

        let transactions: admin.firestore.DocumentData[] = [];
        // Check if it looks like a granular category (heuristic)
        if (category.includes(">")) {
          // Granular: Need to check receipts
          logger.info("Granular category detected. Querying receipts first.");
          let receiptQuery = baseReceiptQuery.where("status", "==", "matched"); // Only matched receipts
          if (dateRange) {
            receiptQuery = receiptQuery.where("transactionDate", ">=", dateRange.start).where("transactionDate", "<=", dateRange.end);
          }
          // We might need to fetch more receipts than the limit and filter/sort later
          const receiptSnapshot = await receiptQuery.limit(50).get(); // Limit receipt query for performance
          const relevantTxnIds = new Set<string>();

          receiptSnapshot.docs.forEach((doc) => {
            const receipt = doc.data();
            const lineItems = receipt?.lineItems as { category?: string }[] ?? [];
            if (lineItems.some((item) => item.category?.trim() === category?.trim())) {
              if (receipt.matchedTransactionId) {
                relevantTxnIds.add(receipt.matchedTransactionId);
              }
            }
          });

          if (relevantTxnIds.size === 0) {
            // No receipts had line items matching this granular category
          } else {
            logger.info(`Found ${relevantTxnIds.size} relevant transactions via receipts. Fetching details...`);
            // Firestore 'in' query limited to 30 IDs per query
            const idChunks = Array.from(relevantTxnIds).reduce((acc, cur, i) => {
              const chunkIndex = Math.floor(i / 30);
              if (!acc[chunkIndex]) {
                acc[chunkIndex] = [];
              }
              acc[chunkIndex].push(cur);
              return acc;
            }, [] as string[][]);

            for (const chunk of idChunks) {
              if (chunk.length > 0) {
                const txnSnapshot = await db.collection("transactions")
                  .where(admin.firestore.FieldPath.documentId(), "in", chunk)
                  .get();
                transactions = transactions.concat(txnSnapshot.docs.map((d) => d.data()));
              }
            }
            // Sort by date descending after fetching all chunks
            transactions.sort((a, b) => (b.date as Timestamp).toMillis() - (a.date as Timestamp).toMillis());
            // Apply limit
            transactions = transactions.slice(0, limit);
          }
        } else {
          // Broad Category: Query transactions directly
          logger.info("Broad category detected. Querying transactions directly.");
          transactionQuery = transactionQuery.where("category", "array-contains", category);
          const querySnapshot = await transactionQuery.orderBy("date", "desc").limit(limit).get();
          transactions = querySnapshot.docs.map((doc) => doc.data());
        }

        if (transactions.length === 0) {
          responseText = `No transactions found for category "${category}"${periodDescription}.`;
        } else {
          responseText = `Okay, here are the latest ${transactions.length} transactions for "${category}"${periodDescription}:\n`;
          transactions.forEach((tx) => {/* ... format transaction line (same as GET_RECENT_TRANSACTIONS) ... */
            const date = (tx.date as Timestamp)?.toDate();
            const dateString = date ? `${date.getMonth() + 1}/${date.getDate()}` : "N/A";
            const amount = tx.amount ?? 0;
            const name = tx.merchantName ?? tx.name ?? "Unknown";
            const amountString = amount.toLocaleString("en-US", {style: "currency", currency: tx.currencyCode ?? "USD"});
            responseText += `- ${dateString}: ${name} ${amountString}\n`;
          });
        }
        break;
      } // End case GET_TRANSACTIONS_BY_CATEGORY
      case "GET_TRANSACTIONS_BY_MERCHANT": {
        const merchant = entities.merchant as string | undefined;
        const period = entities.period as string | undefined;
        let limit = 5; // Default limit for category search
        if (typeof entities.limit === "number" && Number.isInteger(entities.limit) && entities.limit > 0) {
          limit = entities.limit;
        }

        if (!merchant) {
          responseText = "Please specify a merchant name (e.g., 'show Starbucks spending').";
          break;
        }
        logger.info(`Processing GET_TRANSACTIONS_BY_MERCHANT for '${merchant}', period '${period}', limit ${limit}`);

        const merchantQuery = baseQuery.where("merchantName", "==", merchant); // Query merchantName field

        // Add date range if period is specified
        if (period) {/* ... add date range similar to category query ... */}

        finalQuery = merchantQuery.orderBy("date", "desc").limit(limit);
        const querySnapshot = await finalQuery.get();

        if (querySnapshot.empty) {
          responseText = `No transactions found for merchant "${merchant}"` + (period ? ` in period "${period}"` : "") + ".";
        } else {
          // ... (format response similar to other transaction lists) ...
          responseText = `Okay, here are the latest transactions for "${merchant}":\n`;
          // ... (loop and format) ...
        }
        break;
      }
      case "GET_SPENDING_SUMMARY_BY_CATEGORY": {
        // --- Normalize the category entity ---
        let category = entities.category as string | undefined;
        if (category) {
          category = category.toLowerCase().split(" ").map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(" ");
        }
        // ------------------------------------
        const period = entities.period as string ?? defaultPeriod; // Use default period if none provided

        if (!category) {
          responseText = "Please specify a category to summarize (e.g., 'how much for groceries this month?').";
          break;
        }
        const dateRange = getDateRange(period);
        if (!dateRange) {
          responseText = `Sorry, I don't understand the time period "${period}".`;
          break;
        }
        logger.info(`Processing GET_SPENDING_SUMMARY_BY_CATEGORY for '${category}', period '${period}'`);

        let totalSpending = 0;
        // Check if granular
        if (category.includes(">")) {
          // Granular: Aggregate from receipts
          logger.info("Granular category summary. Querying receipts...");
          const receiptQuery = baseReceiptQuery
            .where("status", "==", "matched")
            .where("transactionDate", ">=", dateRange.start)
            .where("transactionDate", "<=", dateRange.end);

          // This might read MANY receipts for large date ranges - potential performance issue
          const receiptSnapshot = await receiptQuery.get();
          receiptSnapshot.forEach((doc) => {
            const receipt = doc.data();
            const lineItems = receipt?.lineItems as { category?: string, price?: number }[] ?? [];
            lineItems.forEach((item) => {
              if (item.category?.trim() === category?.trim()) {
                totalSpending += (item.price ?? 0); // Summing receipt line item prices directly
              }
            });
          });
          // NOTE: This sums receipt *line item* prices, which might differ slightly
          // from the corresponding *transaction* amounts if receipt matching/extraction wasn't perfect.
        } else {
          // Broad Category: Aggregate from transactions
          logger.info("Broad category summary. Querying transactions...");
          const transactionQuery = baseTransactionQuery
            .where("category", "array-contains", category)
            .where("date", ">=", dateRange.start)
            .where("date", "<=", dateRange.end)
            .where("amount", "<", 0);

          const querySnapshot = await transactionQuery.get();
          let totalSpending = 0;
          querySnapshot.forEach((doc) => {
            totalSpending += (doc.data().amount ?? 0);
          });
          logger.info(`Total spending for category "${category}": ${totalSpending}`);
        }

        if (totalSpending === 0 && !category.includes(">")) {
          // If broad category sum is 0, maybe check granular? Or just report 0.
          responseText = `No spending found for category "${category}" ${period.replace(/_/g, " ")}.`;
        } else {
          const totalString = Math.abs(totalSpending).toLocaleString("en-US", {style: "currency", currency: "USD"});
          responseText = `You spent ${totalString} on ${category} ${period.replace(/_/g, " ")}.`;
        }
        break;
      }
      case "GET_SPENDING_SUMMARY_BY_MERCHANT": {
        const merchant = entities.merchant as string | undefined;
        const period = entities.period as string ?? defaultPeriod; // Use default period

        if (!merchant) {
          responseText = "Please specify a merchant to summarize (e.g., 'how much did I spend at Starbucks this week?').";
          break;
        }
        const dateRange = getDateRange(period);
        if (!dateRange) {
          responseText = `Sorry, I don't understand the time period "${period}".`;
          break;
        }
        logger.info(`Processing GET_SPENDING_SUMMARY_BY_MERCHANT for '${merchant}', period '${period}'`);

        finalQuery = baseQuery
          .where("merchantName", "==", merchant) // Filter by merchant name
          .where("date", ">=", dateRange.start)
          .where("date", "<=", dateRange.end)
          .where("amount", "<", 0); // Expenses only

        const querySnapshot = await finalQuery.get();
        let totalSpending = 0;
        querySnapshot.forEach((doc) => {
          totalSpending += (doc.data().amount ?? 0);
        });

        if (querySnapshot.empty) {
          responseText = `No spending found for merchant "${merchant}" ${period.replace(/_/g, " ")}.`;
        } else {
          const totalString = Math.abs(totalSpending).toLocaleString("en-US", {style: "currency", currency: "USD"}); // Assume USD
          responseText = `You spent ${totalString} at ${merchant} ${period.replace(/_/g, " ")}.`;
        }
        break;
      }

      case "GET_RECEIPT_DETAILS": {
        const merchant = entities.merchant as string | undefined;
        const category = entities.category as string | undefined; // Handle category lookup later if needed
        const period = entities.period as string | undefined;
        const date = entities.date as string | undefined; // Specific date YYYY-MM-DD
        const limit = 1; // Usually looking for one specific transaction/receipt

        logger.info("Processing GET_RECEIPT_DETAILS", {merchant, category, period, date});

        // --- Determine Query Filters ---
        let targetQuery = baseQuery;

        // Filter by Merchant or Category (Prioritize Merchant if both given?)
        if (merchant) {
          targetQuery = targetQuery.where("merchantName", "==", merchant);
        } else if (category) {
          // TODO: Implement logic to find the *latest* transaction matching a category if only category is given.
          // This requires a separate query first or more complex logic.
          // For now, we'll primarily rely on merchant/date.
          responseText = "Sorry, finding receipts by category only isn't supported yet. Try specifying a merchant or date.";
          break; // Exit this case for now
        } else if (!date && !period) {
          // If no merchant, category, date, or period, we don't know which receipt to get
          responseText = "Please specify a merchant, category, or date for the receipt you want to see.";
          break;
        }

        // Filter by Date/Period
        let dateRange: { start: Timestamp; end: Timestamp } | null = null;
        if (date) { // Specific date takes precedence
          try {
            const specificDate = new Date(date + "T12:00:00Z"); // Assume UTC noon to avoid timezone issues near midnight
            if (!isNaN(specificDate.getTime())) {
              // Create a range for the whole day
              dateRange = {
                start: Timestamp.fromDate(new Date(specificDate.setHours(0, 0, 0, 0))),
                end: Timestamp.fromDate(new Date(specificDate.setHours(23, 59, 59, 999))),
              };
            }
          } catch (e) {
            logger.warn("Invalid date format provided:", {date});
          }
        } else if (period) { // Use period if no specific date
          dateRange = getDateRange(period);
        }

        if (dateRange) {
          targetQuery = targetQuery.where("date", ">=", dateRange.start).where("date", "<=", dateRange.end);
        } else if (!merchant && !category) {
          // Avoid overly broad query if no date/period resolved and no merchant/category given
          responseText = "Please provide a valid date, time period, merchant, or category.";
          break;
        }

        // --- Execute Query ---
        // Find the most recent matching transaction first
        finalQuery = targetQuery.orderBy("date", "desc").limit(limit);
        const transactionSnapshot = await finalQuery.get();

        if (transactionSnapshot.empty) {
          responseText = "Sorry, I couldn't find a matching transaction for that request.";
          break;
        }

        // --- Check for Linked Receipt ---
        const transactionDoc = transactionSnapshot.docs[0]; // Get the first (latest) match
        const transactionData = transactionDoc.data();
        const linkedReceiptId = transactionData.linkedReceiptId as string | undefined;

        if (!linkedReceiptId) {
          responseText = `I found the transaction ${merchant ? `at ${merchant}` : ""}, but there's no receipt linked to it.`;
          break;
        }

        // --- Fetch and Format Receipt ---
        try {
          const receiptRef = db.collection("receipts").doc(linkedReceiptId);
          const receiptSnapshot = await receiptRef.get();
          if (!receiptSnapshot.exists) {
            logger.error(`Receipt ${linkedReceiptId} linked in transaction ${transactionDoc.id} but not found.`);
            responseText = "I found the transaction, but there was an error retrieving the linked receipt details.";
          } else {
            const receipt = receiptSnapshot.data();
            const lineItems = receipt?.lineItems as { description: string, quantity: number, price: number, category?: string }[] ?? [];
            responseText = `Okay, here's what was on the receipt from ${receipt?.vendorName ?? merchant ?? "that transaction"}:\n`;
            if (lineItems.length > 0) {
              lineItems.forEach((item) => {
                const priceString = (item.price ?? 0).toLocaleString("en-US", {style: "currency", currency: transactionData.currencyCode ?? "USD"});
                const categoryString = item.category ? ` (${item.category})` : ""; // Add category if available
                responseText += `- ${item.description ?? "Item"} (Qty: ${item.quantity ?? 1}) ${priceString}${categoryString}\n`;
              });
            } else {
              responseText += "- No line items were extracted from this receipt.\n";
            }
            responseText += `Total: ${(receipt?.totalAmount ?? 0).toLocaleString("en-US"
              , {style: "currency", currency: transactionData.currencyCode ?? "USD"})}`;
          }
        } catch (receiptError) {
          logger.error(`Error fetching linked receipt ${linkedReceiptId}`, {receiptError});
          responseText = "I found the transaction, but couldn't fetch the receipt details.";
        }
        break;
      }

      // --- Default Case ---
      default:
        logger.warn(`getFinancialData: Unhandled intent: ${intent}`);
        responseText = `Sorry, I don't know how to handle the request: ${intent}`;
      }
    } catch (error: unknown) {
      logger.error(`getFinancialData: Error processing intent '${intent}' for user ${userId}`, {error});
      // Consider checking for specific Firestore errors (e.g., index needed)
      if (error instanceof Error && error.message.includes("requires an index")) {
        responseText = "Sorry, I need a moment to optimize for that specific query. Please try again shortly.";
        // Log instructions for creating index?
      } else {
        // Generic error for other issues
        responseText = "Sorry, there was an error processing your request.";
      }
      // Throwing here will override responseText, send HttpsError to client instead
      // throw new HttpsError("internal", `There was an error processing your request.`);
    }

    // 4. Return Formatted Response
    logger.info(`getFinancialData: Sending response for intent '${intent}' to user ${userId}.`);
    return {responseText: responseText};
  }
);

// --- Date Range Helper Function ---
/**
 * Calculates start and end Timestamps based on a period string.
 * NOTE: Uses server time. For accurate user timezone handling, client should pass dates.
 * @param {string} period - e.g., "today", "this_week", "this_month", "yesterday", "last_week", "last_month"
 * @return {{start: Timestamp, end: Timestamp} | null} Object with start/end Timestamps or null if period is invalid.
 */
function getDateRange(period: string): { start: Timestamp; end: Timestamp } | null {
  const now = new Date(); // Server's current time
  let startDate: Date | null = null;
  let endDate: Date | null = null;

  // Set hours/minutes/seconds/ms to ensure start/end of day/week/month
  const startOfDay = (d: Date) => new Date(d.setHours(0, 0, 0, 0));
  const endOfDay = (d: Date) => new Date(d.setHours(23, 59, 59, 999));
  const yesterday = new Date(now);
  const dayOfWeek = now.getDay(); // 0=Sun, 1=Mon, ...
  const diffStart = now.getDate() - dayOfWeek + (dayOfWeek === 0 ? -6 : 1);
  const lastWeekStartDate = new Date(now);
  const lastWeekEndDate = new Date(now);
  const dayOfWeekEnd = now.getDay();

  switch (period.toLowerCase().replace(/ /g, "_")) { // Normalize period string
  case "today":
    startDate = startOfDay(now);
    endDate = endOfDay(now);
    break;
  case "yesterday":
    yesterday.setDate(now.getDate() - 1);
    startDate = startOfDay(yesterday);
    endDate = endOfDay(yesterday);
    break;
  case "this_week":
    // Adjust for Sunday start or Monday start
    startDate = startOfDay(new Date(now.setDate(diffStart)));
    endDate = endOfDay(now); // Week-to-date
    break;
  case "last_week":
    lastWeekEndDate.setDate(now.getDate() - dayOfWeekEnd - (dayOfWeekEnd === 0 ? 0 : 0)); // End of last Sunday (or Sat)
    endDate = endOfDay(lastWeekEndDate);
    lastWeekStartDate.setDate(endDate.getDate() - 6); // Start of last Monday (or Sun)
    startDate = startOfDay(lastWeekStartDate);
    break;
  case "this_month":
    startDate = startOfDay(new Date(now.getFullYear(), now.getMonth(), 1));
    endDate = endOfDay(now); // Month-to-date
    break;
  case "last_month":
    endDate = endOfDay(new Date(now.getFullYear(), now.getMonth(), 0)); // Last day of previous month
    startDate = startOfDay(new Date(endDate.getFullYear(), endDate.getMonth(), 1)); // First day of previous month
    break;
  case "this_year":
    startDate = startOfDay(new Date(now.getFullYear(), 0, 1)); // Jan 1st of current year
    endDate = endOfDay(now); // Year-to-date
    break;
  case "last_year":
    startDate = startOfDay(new Date(now.getFullYear() - 1, 0, 1)); // Jan 1st of last year
    endDate = endOfDay(new Date(now.getFullYear() - 1, 11, 31)); // Dec 31st of last year
    break;
    // Add more periods as needed (e.g., 'year_to_date')
  default:
    return null; // Invalid period
  }

  if (startDate && endDate) {
    return {start: Timestamp.fromDate(startDate), end: Timestamp.fromDate(endDate)};
  }
  return null;
}


// --- NEW: refreshTransactionsForItem Function ---
/**
 * Fetches new transactions from Plaid for a specific item belonging to the calling user
 * using the /transactions/sync endpoint and saves them to Firestore.
 */
export const refreshTransactionsForItem = onCall(
  {secrets: [plaidSecret]}, // Needs secret access
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("refreshTransactionsForItem: Authentication Error.");
      throw new HttpsError("unauthenticated", "Function must be called while authenticated.");
    }
    const userId = request.auth.uid;

    // 2. Validate Input Data
    const itemIdToRefresh = request.data.itemId as string | undefined;
    if (!itemIdToRefresh) {
      logger.error("refreshTransactionsForItem: Invalid argument - itemId missing.", {userId: userId, data: request.data});
      throw new HttpsError("invalid-argument", "Missing 'itemId' in request data.");
    }
    logger.info(`refreshTransactionsForItem: Starting for user: ${userId}, item: ${itemIdToRefresh}`);

    // 3. Initialize Plaid Client
    let plaidClient: PlaidApi;
    try {
      plaidClient = getPlaidClientWithParams(plaidClientId.value(), plaidSecret.value(), plaidEnvName.value());
    } catch (error) {
      logger.error("fetchTransactions: Failed to initialize Plaid client.", {userId: userId, error: error});
      if (error instanceof HttpsError) {
        throw error;
      } else {
        throw new HttpsError("internal", "Failed to initialize Plaid client.");
      }
    }

    // 4. Get Specific Plaid Item from Firestore
    const userDocRef = db.collection("users").doc(userId);
    let itemToProcess: PlaidItemData | undefined;
    let currentPlaidItems: PlaidItemData[] = []; // Keep track of the full array
    try {
      const userDocSnapshot = await userDocRef.get();
      if (!userDocSnapshot.exists) {
        logger.error(`refreshTransactionsForItem: User document ${userId} not found.`);
        throw new HttpsError("not-found", "User profile not found.");
      }
      const itemsData = userDocSnapshot.data()?.plaidItems;
      if (Array.isArray(itemsData)) {
        currentPlaidItems = itemsData as PlaidItemData[];
        itemToProcess = currentPlaidItems.find((item) => item.itemId === itemIdToRefresh);
      }
      if (!itemToProcess) {
        logger.error(`refreshTransactionsForItem: Item ${itemIdToRefresh} not found for user ${userId}.`);
        throw new HttpsError("not-found", `Linked account with ID ${itemIdToRefresh} not found.`);
      }
      if (!itemToProcess.accessToken) {
        logger.error(`refreshTransactionsForItem: Access token missing for item ${itemIdToRefresh}.`, {userId: userId});
        throw new HttpsError("permission-denied", `Access token missing for item ${itemIdToRefresh}.`);
      }
    } catch (error: unknown) {
      // Catch HttpsError from above checks or Firestore read errors
      if (error instanceof HttpsError) {
        throw error;
      }
      logger.error(`refreshTransactionsForItem: Failed to read user document or find item ${itemIdToRefresh}.`, {userId: userId, error});
      throw new HttpsError("internal", "Failed to read user data.");
    }

    // 5. Sync Transactions for the Item
    const accessToken = itemToProcess.accessToken;
    let cursor = itemToProcess.syncCursor || null;
    logger.info(`refreshTransactionsForItem: Processing item ${itemIdToRefresh}. Cursor: ${cursor ? "Exists" : "None"}`);

    let hasMore = true;
    let transactionsToAdd: PlaidTransaction[] = [];
    let currentItemSucceeded = true; // Flag for sync success

    // Loop for pagination
    while (hasMore) {
      try {
        const syncRequest: TransactionsSyncRequest = {access_token: accessToken, cursor: cursor ?? undefined, count: 100};
        logger.info(`refreshTransactionsForItem: Calling Plaid /transactions/sync for item ${itemIdToRefresh}...`);
        const response = await plaidClient.transactionsSync(syncRequest);
        const data = response.data;

        transactionsToAdd = transactionsToAdd.concat(data.added);
        // TODO: Handle data.modified and data.removed later
        hasMore = data.has_more;
        cursor = data.next_cursor; // Update cursor
        logger.info(`refreshTransactionsForItem: Sync page processed for item ${itemIdToRefresh}. Has More: ${hasMore}. Added: ${data.added.length}`);
      } catch (error: unknown) {
        logger.error(`refreshTransactionsForItem: Plaid API Error during sync for item ${itemIdToRefresh}.`, {error});
        hasMore = false; // Stop loop
        currentItemSucceeded = false;
        itemToProcess.status = "error"; // Update status IN MEMORY for now
        itemToProcess.lastSyncError = error instanceof Error ? error.message : JSON.stringify(error);
        // Consider throwing error back to client? Or just log and try to save state?
        // For now, we log and will attempt to save the updated item state (like error status)
      }
    } // End while(hasMore)

    // 6. Save New Transactions (if any)
    let transactionsAddedCount = 0;
    if (transactionsToAdd.length > 0) {
      const batch = db.batch();
      logger.info(`refreshTransactionsForItem: Saving ${transactionsToAdd.length} transactions to Firestore batch for item ${itemIdToRefresh}...`);
      transactionsToAdd.forEach((tx) => {
        const txDocRef = db.collection("transactions").doc(tx.transaction_id);
        batch.set(txDocRef, {
          // --- Map Plaid Transaction to Firestore Schema ---
          userId: userId,
          plaidItemId: itemIdToRefresh,
          plaidAccountId: tx.account_id,
          plaidTransactionId: tx.transaction_id,
          name: tx.name,
          merchantName: tx.merchant_name ?? tx.name, // Prefer merchant_name
          amount: tx.amount * -1, // Invert amount for expense tracking convention
          currencyCode: tx.iso_currency_code,
          date: Timestamp.fromDate(new Date(tx.date)), // Convert date string
          authorizedDate: tx.authorized_date ? Timestamp.fromDate(new Date(tx.authorized_date)) : null,
          pending: tx.pending,
          pendingTransactionId: tx.pending_transaction_id,
          category: tx.category ?? [], // Array of strings from Plaid
          // customCategory: null, // Add later for user/AI categorization
          paymentChannel: tx.payment_channel,
          transactionType: tx.transaction_type,
          // --- End Schema Mapping ---
          fetchedAt: Timestamp.now(), // Record processing time
        });
      });
      try {
        await batch.commit();
        transactionsAddedCount = transactionsToAdd.length;
        logger.info(`refreshTransactionsForItem: Firestore batch commit successful for ${transactionsAddedCount} transactions.`);
      } catch (error: unknown) {
        logger.error(`refreshTransactionsForItem: Firestore batch commit failed for item ${itemIdToRefresh}.`, {error});
        currentItemSucceeded = false; // Mark as failed if save fails
        itemToProcess.status = "error";
        itemToProcess.lastSyncError = `Firestore batch commit failed: ${error instanceof Error ? error.message : JSON.stringify(error)}`;
      }
    } else {
      logger.info(`refreshTransactionsForItem: No new transactions to add for item ${itemIdToRefresh}.`);
    }

    // 7. Update Item State in Firestore Array
    itemToProcess.syncCursor = cursor;
    itemToProcess.lastSync = Timestamp.now();
    if (currentItemSucceeded && itemToProcess.status !== "active") {
      itemToProcess.status = "active";
      itemToProcess.lastSyncError = null; // Clear error
      if (itemToProcess.lastSyncError === null) {
        delete itemToProcess.lastSyncError;
      } // Remove field if null
    }

    // Find the index of the item we processed to update it in the original array
    const itemIndex = currentPlaidItems.findIndex((item) => item.itemId === itemIdToRefresh);
    if (itemIndex !== -1) {
      currentPlaidItems[itemIndex] = itemToProcess; // Replace with updated item object
      try {
        logger.info(`refreshTransactionsForItem: Updating specific item in plaidItems array in Firestore for user ${userId}...`);
        await userDocRef.update({plaidItems: currentPlaidItems}); // Overwrite array with updated one
        logger.info(`refreshTransactionsForItem: Successfully updated plaidItems array for item ${itemIdToRefresh}.`);
      } catch (error: unknown) {
        logger.error(`refreshTransactionsForItem: Failed to update plaidItems array for user ${userId}. Cursor/status might be stale.`, {error});
        throw new HttpsError("internal", "Failed to save updated account sync status.");
      }
    } else {
      logger.error("refreshTransactionsForItem: Could not find item index to update in array after processing. This should not happen.");
      throw new HttpsError("internal", "Failed to update account sync status.");
    }


    // 8. Return Success Response
    logger.info(`refreshTransactionsForItem: Completed for user ${userId}, item ${itemIdToRefresh}. New transactions: ${transactionsAddedCount}.`);
    return {success: true, transactionsAdded: transactionsAddedCount};
  }
);

// --- NEW: unlinkPlaidItem Function ---
/**
 * Removes a Plaid item linkage for the user.
 * Calls Plaid's /item/remove endpoint and removes the item from Firestore.
 */
export const unlinkPlaidItem = onCall(
  {secrets: [plaidSecret]}, // Needs secret access
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("unlinkPlaidItem: Authentication Error.");
      throw new HttpsError("unauthenticated", "Function must be called while authenticated.");
    }
    const userId = request.auth.uid;

    // 2. Validate Input Data
    const itemIdToUnlink = request.data.itemId as string | undefined;
    if (!itemIdToUnlink) {
      logger.error("unlinkPlaidItem: Invalid argument - itemId missing.", {userId: userId, data: request.data});
      throw new HttpsError("invalid-argument", "Missing 'itemId' in request data.");
    }
    logger.info(`unlinkPlaidItem: Starting for user: ${userId}, item: ${itemIdToUnlink}`);

    // 3. Initialize Plaid Client
    let plaidClient: PlaidApi;
    try {
      plaidClient = getPlaidClientWithParams(plaidClientId.value(), plaidSecret.value(), plaidEnvName.value());
    } catch (error) {
      logger.error("fetchTransactions: Failed to initialize Plaid client.", {userId: userId, error: error});
      if (error instanceof HttpsError) {
        throw error;
      } else {
        throw new HttpsError("internal", "Failed to initialize Plaid client.");
      }
    }

    // 4. Get Specific Plaid Item's Access Token from Firestore
    const userDocRef = db.collection("users").doc(userId);
    let accessToken: string | undefined;
    let currentPlaidItems: PlaidItemData[] = [];
    try {
      const userDocSnapshot = await userDocRef.get();
      if (!userDocSnapshot.exists) {
        logger.error(`unlinkPlaidItem: User document ${userId} not found.`);
        throw new HttpsError("not-found", "User profile not found.");
      }
      const itemsData = userDocSnapshot.data()?.plaidItems;
      if (Array.isArray(itemsData)) {
        currentPlaidItems = itemsData as PlaidItemData[];
        const itemToUnlink = currentPlaidItems.find((item) => item.itemId === itemIdToUnlink);
        if (itemToUnlink) {
          accessToken = itemToUnlink.accessToken;
        }
      }
      if (!accessToken) {
        logger.error(`unlinkPlaidItem: Item ${itemIdToUnlink} or its access token not found for user ${userId}. Might have already been unlinked.`);
        // Decide how to handle: return success anyway or throw error?
        // Returning success might be better UX if the goal is just to remove from our list.
        // Throwing error indicates something unexpected. Let's throw for now.
        throw new HttpsError("not-found", `Linked account ${itemIdToUnlink} not found or access token missing.`);
      }
    } catch (error: unknown) {
      if (error instanceof HttpsError) {
        throw error;
      }
      logger.error(`unlinkPlaidItem: Failed to read user document or find item ${itemIdToUnlink}.`, {userId: userId, error});
      throw new HttpsError("internal", "Failed to read user data.");
    }

    // 5. Call Plaid's /item/remove endpoint
    let plaidRemovalSucceeded = false;
    try {
      logger.info(`unlinkPlaidItem: Calling Plaid /item/remove for item ${itemIdToUnlink}...`);
      const removeResponse = await plaidClient.itemRemove({access_token: accessToken});
      // Check response, though Plaid often returns success even if item is already removed
      if (removeResponse.data.request_id) {
        plaidRemovalSucceeded = true;
        logger.info(`unlinkPlaidItem: Plaid /item/remove call successful for item ${itemIdToUnlink}. Request ID: ${removeResponse.data.request_id}`);
      } else {
        // This case might indicate an issue, but we'll still proceed with removal from our DB
        logger.warn(`unlinkPlaidItem: Plaid /item/remove response did not contain expected data for item ${itemIdToUnlink}.`
          , {response: removeResponse.data});
      }
    } catch (error: unknown) {
      // Log the error, but proceed with removing from Firestore anyway,
      // as the access token might be invalid, but we still want it gone from our app.
      let errorMessage = "Unknown error during Plaid /item/remove call";
      if (error instanceof Error) {
        errorMessage = error.message;
      }
      logger.error(`unlinkPlaidItem: Plaid API Error during /item/remove for item ${itemIdToUnlink}. Will still attempt Firestore removal.`
        , {error: errorMessage});
      // Check for specific Plaid error codes if needed (e.g., INVALID_ACCESS_TOKEN)
    }

    // 6. Remove Item from Firestore Array
    try {
      logger.info(`unlinkPlaidItem: Removing item ${itemIdToUnlink} from plaidItems array in Firestore for user ${userId}...`);
      // Filter out the item to be unlinked
      const updatedPlaidItems = currentPlaidItems.filter((item) => item.itemId !== itemIdToUnlink);

      // Overwrite the array with the filtered version
      await userDocRef.update({plaidItems: updatedPlaidItems});
      logger.info(`unlinkPlaidItem: Successfully removed item ${itemIdToUnlink} from Firestore for user ${userId}.`);

      // Optional: Delete associated transactions (can be resource intensive)
      // Consider doing this in a separate scheduled function or background task
      // _deleteTransactionsForItem(userId, itemIdToUnlink); // Example call
    } catch (error: unknown) {
      let errorMessage = "Unknown Firestore error during item removal";
      if (error instanceof Error) {
        errorMessage = error.message;
      }
      logger.error(`unlinkPlaidItem: Failed to remove item ${itemIdToUnlink} from Firestore for user ${userId}.`, {error: errorMessage});
      // Critical: The item is likely removed from Plaid but still in our DB. Manual cleanup might be needed.
      throw new HttpsError("internal", `Failed to update account list after unlinking: ${errorMessage}`);
    }

    // 7. Return Success Response
    logger.info(`unlinkPlaidItem: Process completed successfully for user ${userId}
      , item ${itemIdToUnlink}. Plaid removal status: ${plaidRemovalSucceeded}`);
    return {success: true}; // Indicate success removing from our system
  }
);

// --- NEW: generateInsights Function ---
/**
 * Analyzes recent transactions using Gemini to generate spending insights
 * and saves them to the user's Firestore document.
 */
export const generateInsights = onCall(
  // Doesn't need Plaid secrets, but uses Gemini key via parameter
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("generateInsights: Authentication Error.");
      throw new HttpsError("unauthenticated", "Function must be called while authenticated.");
    }
    const userId = request.auth.uid;
    logger.info(`generateInsights: Starting for user: ${userId}`);

    // 2. Fetch Recent Transactions (e.g., last 30 days)
    let transactions: admin.firestore.DocumentData[] = [];
    try {
      const thirtyDaysAgo = new Date();
      thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
      const startDate = Timestamp.fromDate(thirtyDaysAgo);

      logger.info(`generateInsights: Fetching transactions since ${startDate.toDate().toISOString()} for user ${userId}`);
      const querySnapshot = await db.collection("transactions")
        .where("userId", "==", userId)
        .where("date", ">=", startDate)
        .where("amount", "<", 0) // Focus on expenses for insights
        .orderBy("date", "desc") // Get newest first
        .limit(200) // Limit transactions analyzed to prevent huge prompts/cost
        .get();

      if (querySnapshot.empty) {
        logger.info(`generateInsights: No recent transactions found for user ${userId}.`);
        // Optionally clear old insights if desired
        // await db.collection('users').doc(userId).update({ aiInsights: [] });
        return {success: true, insightsAdded: 0, message: "No recent transactions to analyze."};
      }
      transactions = querySnapshot.docs.map((doc) => doc.data());
      logger.info(`generateInsights: Found ${transactions.length} recent transactions.`);
    } catch (error: unknown) {
      logger.error(`generateInsights: Failed to fetch transactions for user ${userId}.`, {error});
      throw new HttpsError("internal", "Could not retrieve transaction data.");
    }

    // 3. Prepare Data Summary for Gemini Prompt
    // Aggregate spending by primary category
    const categorySpending: Record<string, number> = {};
    let totalSpending = 0;
    transactions.forEach((tx) => {
      const amount = Math.abs(tx.amount ?? 0); // Use absolute value
      totalSpending += amount;
      const primaryCategory = tx.category?.[0] ?? "Uncategorized"; // Use first category or fallback
      categorySpending[primaryCategory] = (categorySpending[primaryCategory] ?? 0) + amount;
    });

    // Convert map to string for the prompt
    let spendingSummary =
     `Total spending over the period: ${totalSpending.toLocaleString("en-US", {style: "currency", currency: "USD"})}\nSpending by category:\n`;
    // Sort categories by spending (desc) and take top N? Or just list all? Let's list top 5 for brevity.
    const sortedCategories = Object.entries(categorySpending)
      .sort(([, a], [, b]) => b - a) // Sort descending by amount
      .slice(0, 5); // Take top 5

    sortedCategories.forEach(([category, amount]) => {
      spendingSummary += `- ${category}: ${amount.toLocaleString("en-US", {style: "currency", currency: "USD"})}\n`;
    });
    if (Object.keys(categorySpending).length > 5) {
      spendingSummary += "- ... (other categories)\n";
    }

    // 4. Initialize Gemini Client
    let genAI: GoogleGenerativeAI;
    let model: ReturnType<GoogleGenerativeAI["getGenerativeModel"]>; // Get type inference
    try {
      const apiKey = geminiApiKey.value(); // Get key from parameter
      if (!apiKey) {
        throw new Error("Gemini API Key parameter is missing.");
      }
      genAI = new GoogleGenerativeAI(apiKey);
      model = genAI.getGenerativeModel({
        model: "gemini-2.0-flash", // Or gemini-pro
        safetySettings: [ // Standard safety settings
          {category: HarmCategory.HARM_CATEGORY_HARASSMENT, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
          {category: HarmCategory.HARM_CATEGORY_HATE_SPEECH, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
          {category: HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
          {category: HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
        ],
      });
      logger.info("generateInsights: Gemini client initialized.");
    } catch (error) {
      logger.error("generateInsights: Failed to initialize Gemini client.", {error});
      throw new HttpsError("internal", "Could not initialize AI service.");
    }


    // 5. Craft Gemini Prompt for Insights
    const prompt = `Analyze the following financial summary for a user based on their last 30 days of spending. 
    Provide 3-4 concise, actionable insights or interesting observations about 
    their spending patterns, significant categories, or potential areas for saving. 

    Respond ONLY with a valid JSON array containing strings, where each string is a single insight. 

    Summary:
    ${spendingSummary}

    Insights:`; // Let Gemini complete starting here


    // 6. Call Gemini API
    let insightsToSave: string[] = [];
    try {
      logger.info("generateInsights: Sending summary to Gemini for analysis (expecting JSON array)...");
      const result = await model.generateContent(prompt);
      const response = result.response;
      let responseText = response.text();

      if (responseText) {
        logger.info("Raw Gemini JSON response for insights:", {text: responseText});
        responseText = responseText.trim(); // Remove leading/trailing whitespace
        if (responseText.startsWith("```json")) {
          responseText = responseText.substring(7); // Remove ```json prefix
        } else if (responseText.startsWith("```")) {
          responseText = responseText.substring(3); // Remove ``` prefix
        }
        if (responseText.endsWith("```")) {
          responseText = responseText.substring(0, responseText.length - 3); // Remove ``` suffix
        }
        responseText = responseText.trim(); // Trim again after stripping fences
        // ---------------------------

        logger.info("Cleaned Gemini response before JSON parse:", {text: responseText});
        try {
          // Attempt to decode the JSON string AS AN ARRAY
          const jsonResponse = JSON.parse(responseText); // Use JSON.parse
          if (Array.isArray(jsonResponse)) {
            // Filter out any non-string elements just in case
            insightsToSave = jsonResponse.filter((item): item is string => typeof item === "string");
            logger.info(`Successfully parsed ${insightsToSave.length} insights from JSON array.`);
          } else {
            logger.warn("Gemini response was not a valid JSON array. Storing raw text.", {responseText});
            insightsToSave = [responseText]; // Fallback to saving raw text
          }
        } catch (error: unknown) {
          logger.error("Error decoding JSON insight array response:", {error: error, responseText});
          insightsToSave = [responseText]; // Fallback to saving raw text on parse error
        }
      } else {
        logger.warn("AI model returned no text for insights.");
        insightsToSave = ["AI model returned no text."]; // Default message
      }
    } catch (error: unknown) {
      logger.error("generateInsights: Gemini API call failed.", {error});
      insightsToSave = ["Could not generate insights at this time."];
    }

    // 7. Save Insights to Firestore
    // For simplicity, store the latest generated insights text as an array of strings
    // (could just be one string, or split by newline)
    // Overwrite previous insights each time for this simple version.
    try {
      logger.info(`generateInsights: Saving ${insightsToSave.length} insights to Firestore for user ${userId}...`);
      const userDocRef = db.collection("users").doc(userId);
      await userDocRef.update({
        aiInsights: insightsToSave, // Overwrite with the latest insights
        lastInsightUpdate: Timestamp.now(), // Track update time
      });
      logger.info("generateInsights: Successfully saved insights to Firestore.");
    } catch (error: unknown) {
      logger.error(`generateInsights: Failed to save insights to Firestore for user ${userId}.`, {error});
      // Don't necessarily fail the whole function, but log it
    }

    // 8. Return Success
    logger.info(`generateInsights: Completed successfully for user ${userId}.`);
    return {success: true, insightsGenerated: insightsToSave.length};
  }
);

// --- NEW: processReceiptImage Function ---
/**
 * Processes a receipt image using Gemini Vision, extracts details,
 * and saves them to the 'receipts' collection in Firestore.
 */
export const processReceiptImage = onCall(
  // Requires Gemini API Key. Increase memory/timeout if processing large images/complex receipts.
  {
    memory: "1GiB",
    timeoutSeconds: 300,
  },
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("processReceiptImage: Authentication Error.");
      throw new HttpsError("unauthenticated", "Function must be called while authenticated.");
    }
    const userId = request.auth.uid;
    logger.info(`processReceiptImage: Starting for user: ${userId}`);

    // 2. Validate Input Data
    const imageDataBase64 = request.data.imageDataBase64 as string | undefined;
    if (!imageDataBase64 || typeof imageDataBase64 !== "string" || imageDataBase64.length === 0) {
      logger.error("processReceiptImage: Invalid argument - imageDataBase64 missing or empty.", {userId: userId});
      throw new HttpsError("invalid-argument", "Missing or invalid 'imageDataBase64' in request data.");
    }
    // Basic check for prefix (though Gemini might handle it) - remove if causing issues
    const base64Data = imageDataBase64.startsWith("data:") ?
      imageDataBase64.substring(imageDataBase64.indexOf(",") + 1) :
      imageDataBase64;

    // 3. Initialize Gemini Client (Vision Model)
    let visionModel: ReturnType<GoogleGenerativeAI["getGenerativeModel"]>;
    let textModel: ReturnType<GoogleGenerativeAI["getGenerativeModel"]>;
    let genAI: GoogleGenerativeAI;
    try {
      const apiKey = geminiApiKey.value();
      if (!apiKey) {
        throw new Error("Gemini API Key parameter is missing.");
      }
      genAI = new GoogleGenerativeAI(apiKey);
      visionModel = genAI.getGenerativeModel({model: "gemini-2.5-flash-preview-04-17" /* or vision model */});

      textModel = genAI.getGenerativeModel({
        // Use a model supporting vision input
        model: "gemini-2.5-flash-preview-04-17", // Or gemini-pro-vision, gemini-1.5-pro-latest
        safetySettings: [ // Standard safety settings
          {category: HarmCategory.HARM_CATEGORY_HARASSMENT, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
          {category: HarmCategory.HARM_CATEGORY_HATE_SPEECH, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
          {category: HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
          {category: HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT, threshold: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE},
        ],
        generationConfig: {
          responseMimeType: "application/json", // Request JSON output
        },
      });
      logger.info("processReceiptImage: Gemini client initialized for vision.");
    } catch (error) {
      logger.error("processReceiptImage: Failed to initialize Gemini client.", {userId: userId, error});
      throw new HttpsError("internal", "Could not initialize AI service.");
    }

    // 4. Craft Multimodal Prompt
    const extractionPromptText = `
      Analyze the provided receipt image. Extract the following information accurately:
      - vendorName (string): The name of the store or vendor.
      - transactionDate (string): The date of the transaction in YYYY-MM-DD format. If time is available, include it. Use null if not found.
      - totalAmount (number): The final total amount paid. Use null if not found.
      - currencyCode (string): The ISO 4217 currency code (e.g., "USD", "CAD"). Use null if not found.
      - lineItems (array of objects): Extract each item listed on the receipt. Each object in the array MUST contain ONLY the following three fields:
          - description (string): Name or description of the item.
          - quantity (number): Quantity purchased. Default to 1 if not specified or unclear. MUST be a number.
          - price (number): The total price paid for that line item (quantity * unit price). MUST be a number.
          Do NOT include any other fields within the line item objects. 
          Ensure correct comma placement between properties within each line item object.

      Respond ONLY with a single, valid JSON object containing these fields. Use null for top-level fields you cannot determine.
      Ensure all monetary values (totalAmount, price) are numbers, not strings.
      Ensure quantity is a number.

      Example JSON structure:
      {
        "vendorName": "Example Cafe",
        "transactionDate": "2025-04-12",
        "totalAmount": 15.75,
        "currencyCode": "USD",
        "lineItems": [
          { "description": "Coffee", "quantity": 1, "price": 3.50 },
          { "description": "Pastry", "quantity": 2, "price": 6.00 }
        ]
      }
      `;

    // Prepare the image part for the multimodal request
    const imagePart: Part = {
      inlineData: {
        mimeType: "image/jpeg", // Or 'image/png' - TODO: Client should ideally send this
        data: base64Data, // The pure base64 data
      },
    };

    const extractionRequestParts = [extractionPromptText, imagePart];

    // 5. Call Gemini API
    let parsedExtractionJson: Record<string, unknown> | null = null;
    let rawExtractionResponse = "";
    try {
      logger.info("Sending receipt image and prompt to Gemini for extraction...");
      const result = await visionModel.generateContent(extractionRequestParts);
      rawExtractionResponse = result.response.text() ?? "";
      if (rawExtractionResponse) {
        // Attempt to clean potential markdown fences (though less common with direct JSON mime type)
        const cleanedResponse = rawExtractionResponse.trim().replace(/^```json|```$/g, "").trim();
        logger.info("Cleaned extraction response:", {cleanedResponse});
        parsedExtractionJson = JSON.parse(cleanedResponse);
        if (typeof parsedExtractionJson !== "object" || parsedExtractionJson === null) throw new Error("Parsed JSON is not an object.");
        logger.info("Successfully parsed JSON response from Gemini extraction.");
      } else {
        logger.warn("processReceiptImage: Gemini returned an empty text response.");
        throw new HttpsError("internal", "AI analysis returned no data.");
      }
    } catch (error: unknown) {
      let errorMessage = "Unknown error during Gemini API call or JSON parsing";
      if (error instanceof Error) errorMessage = error.message;
      logger.error(`processReceiptImage: Gemini API call or parsing failed for user ${userId}.`
        , {error: errorMessage, rawResponse: rawExtractionResponse});
      throw new HttpsError("internal", `AI analysis failed: ${errorMessage}`);
    }
    if (!parsedExtractionJson) {
      throw new HttpsError("internal", "Failed to extract data from receipt image.");
    }


    // 6. Validate and Structure Data for Firestore
    // Perform basic validation on extractedData (add more checks as needed)
    let extractedData: Record<string, unknown> | null = null;
    if (typeof parsedExtractionJson === "object" && parsedExtractionJson !== null) {
      extractedData = parsedExtractionJson as Record<string, unknown>;
    } else if (parsedExtractionJson !== null) {
      // Log if the parsed JSON wasn't an object as expected
      logger.warn("Parsed JSON response from Gemini was not an object.", {parsedExtractionJson});
    }
    const vendorName = parsedExtractionJson.vendorName as string | undefined;
    const dateString = extractedData?.transactionDate as string | undefined;
    const totalAmount = extractedData?.totalAmount as number | undefined;
    const currencyCode = extractedData?.currencyCode as string | undefined;
    let lineItemsRaw = parsedExtractionJson.lineItems;

    // Convert date string to Timestamp, handle potential parsing errors
    let transactionTimestamp: Timestamp | null = null;
    if (dateString) {
      try {
        // Attempt various formats if needed, but start with YYYY-MM-DD
        const date = new Date(dateString);
        if (!isNaN(date.getTime())) { // Check if date is valid
          transactionTimestamp = Timestamp.fromDate(date);
        } else {
          logger.warn("Could not parse transactionDate string:", {dateString});
        }
      } catch (dateError) {
        logger.warn("Error creating Timestamp from transactionDate string:", {dateString, dateError});
      }
    }

    // Validate and sanitize line items
    let lineItems: { description: string; quantity: number; price: number; category?: string }[] = [];
    if (Array.isArray(lineItemsRaw)) {
      lineItems = lineItemsRaw
      // --- Use unknown and type checks inside map ---
        .map((item: unknown) => {
          let description = "N/A";
          let quantity = 1;
          let price = 0.0;

          // Check if item is an object before accessing properties
          if (typeof item === "object" && item !== null) {
            // --- Safely access REQUIRED fields ---
            description = String((item as Record<string, unknown>)?.description ?? "N/A");

            const rawQuantity = (item as Record<string, unknown>)?.quantity;
            quantity = typeof rawQuantity === "number" ? rawQuantity : (Number(rawQuantity ?? 1) || 1);
            // Ensure quantity is an integer if preferred, although number is fine
            quantity = Number.isFinite(quantity) ? Math.round(quantity) : 1; // Round just in case, ensure finite
            if (quantity <= 0) quantity = 1; // Ensure positive quantity

            const rawPrice = (item as Record<string, unknown>)?.price;
            price = typeof rawPrice === "number" ? rawPrice : (Number(rawPrice ?? 0) || 0);
            price = Number.isFinite(price) ? price : 0.0; // Ensure finite price
            // -------------------------------------

            // NOTE: We IGNORE other fields like 'hatchery' here.
            // We only extract what we explicitly look for.
          } else {
            logger.warn("Found non-object item in lineItems array:", {item});
            // Return null or a default object to be filtered out later?
            return null; // Mark for filtering
          }

          return {description, quantity, price};
        })
      // --------------------------------------------
        .filter((item): item is { description: string; quantity: number; price: number; category?: string } =>
          item !== null && typeof item.description === "string" && !isNaN(item.quantity) && !isNaN(item.price)
        );
      logger.info(`Sanitized line items count: ${lineItems.length}`);
    } else {
      logger.warn("Parsed 'lineItems' was not an array or was missing.", {lineItemsRaw});
      lineItemsRaw = []; // Ensure it's an empty array for the categorization step
      lineItems = [];
    }

    // --- 7. Categorize Line Items (NEW STEP) ---
    logger.info(`Attempting to categorize ${lineItems.length} line items...`);
    const categoryPromptTemplate = (itemDesc: string) => `
        Classify the following purchased item into one of these categories.
        Use subcategories where appropriate (e.g., "Groceries > Dairy").
        If unsure, use a general category or "Uncategorized".

        Categories:
        - Groceries > Produce
        - Groceries > Dairy
        - Groceries > Meat
        - Groceries > Pantry
        - Groceries > Bakery
        - Groceries > Deli
        - Groceries > Frozen Foods
        - Groceries > Snacks
        - Groceries > Canned Goods
        - Groceries > Condiments        
        - Groceries > Baby Products
        - Groceries > Pet Supplies
        - Groceries > Health Foods
        - Groceries > Beverages
        - Groceries > Other
        - Restaurants > Fast Food
        - Restaurants > Dine-in
        - Restaurants > Takeout
        - Restaurants > Bar
        - Restaurants > Food Truck
        - Restaurants > Cafeteria
        - Restaurants > Coffee Shop
        - Transportation > Gas
        - Transportation > Ride Share
        - Transportation > Taxi
        - Transportation > Parking Fees
        - Transportation > Tolls
        - Transportation > Car Wash
        - Transportation > EV Charging
        - Transportation > Vehicle Maintenance
        - Transportation > Public Transit
        - Shopping > Clothing
        - Shopping > Electronics
        - Shopping > Home Goods
        - Shopping > Hardware
        - Shopping > Furniture
        - Shopping > Sporting Goods
        - Shopping > Toys
        - Shopping > Gifts
        - Shopping > Office Supplies
        - Shopping > Cleaning Supplies
        - Shopping > Personal Care
        - Shopping > Books
        - Shopping > Beauty
        - Shopping > Jewelry
        - Shopping > Crafts
        - Shopping > Garden
        - Shopping > Automotive
        - Shopping > Travel
        - Shopping > Other
        - Bills & Utilities > Rent/Mortgage
        - Bills & Utilities > Internet
        - Bills & Utilities > Phone
        - Bills & Utilities > Electricity
        - Bills & Utilities > Water
        - Bills & Utilities > Natural Gas
        - Bills & Utilities > Trash
        - Bills & Utilities > Insurance
        - Bills & Utilities > Property Taxes
        - Bills & Utilities > Heating Oil
        - Bills & Utilities > HOA Fees
        - Entertainment > Movies
        - Entertainment > Streaming Services
        - Entertainment > Concerts
        - Entertainment > Sports Events
        - Entertainment > Amusement Parks
        - Entertainment > Museums
        - Entertainment > Video Games
        - Health & Wellness > Pharmacy
        - Health & Wellness > Doctor
        - Health & Wellness > Dentist
        - Health & Wellness > Gym
        - Health & Wellness > Therapy
        - Health & Wellness > Supplements
        - Health & Wellness > Fitness Classes
        - Health & Wellness > Spa
        - Health & Wellness > Other
        - Travel > Car Rental
        - Travel > Train
        - Travel > Bus
        - Travel > Cruise
        - Travel > Flights
        - Travel > Hotels
        - Personal Care
        - Home Services > House Cleaning Service
        - Home Services > Lawn Care
        - Home Services > Home Repairs
        - Home Services > Pest Control Service
        - Home Services > Pool Maintenance
        - Miscellaneous

        Respond ONLY with a valid JSON object like: {"category": "Your Category > Your Subcategory"} or {"category": "Uncategorized"}

        Item Description: "${itemDesc}"
        JSON Response:
        `;

    // Process items sequentially to avoid overwhelming Gemini (can parallelize later)
    for (let i = 0; i < lineItems.length; i++) {
      const item = lineItems[i];
      if (!item.description || item.description === "N/A") {
        item.category = "Uncategorized"; // Assign default if no description
        continue;
      }
      try {
        const categoryPrompt = categoryPromptTemplate(item.description);
        logger.info(`Categorizing item "${item.description}"...`);
        const result = await textModel.generateContent(categoryPrompt); // Use text model
        const response = result.response;
        const responseText = response.text() ?? "";

        if (responseText) {
          const cleanedResponse = responseText.trim().replace(/^```json|```$/g, "").trim();
          try {
            const categoryJson = JSON.parse(cleanedResponse);
            if (typeof categoryJson === "object" && categoryJson !== null && typeof categoryJson.category === "string") {
              item.category = categoryJson.category; // Add category to the item object
              logger.info(` -> Category: ${item.category}`);
            } else {
              logger.warn(`Invalid category JSON structure: ${cleanedResponse}`);
              item.category = "Uncategorized";
            }
          } catch (parseError) {
            logger.warn(`Failed to parse category JSON: ${cleanedResponse}`, {parseError});
            item.category = "Uncategorized"; // Fallback category
          }
        } else {
          logger.warn(`No category text returned for "${item.description}"`);
          item.category = "Uncategorized";
        }
      } catch (catError: unknown) {
        logger.error(`Error categorizing item "${item.description}"`, {catError});
        item.category = "Uncategorized"; // Assign default category on error
      }
      // Optional: Add a small delay between API calls if hitting rate limits
      // await new Promise(resolve => setTimeout(resolve, 200));
    }
    logger.info("Line item categorization complete.");

    // --- 8. Prepare Firestore Document
    const receiptDocData = {
      userId: userId,
      uploadTimestamp: Timestamp.now(), // When it was processed
      vendorName: vendorName ?? null,
      transactionDate: transactionTimestamp, // Store as Timestamp or original string if parsing fails
      transactionDateString: dateString ?? null, // Keep original string for reference
      totalAmount: totalAmount ?? null,
      currencyCode: currencyCode ?? null,
      lineItems: lineItems, // Store the cleaned array
      status: "processed", // Initial status
      // Optional: Store image reference if uploaded to Storage
      // imageStoragePath: "...",
      // Optional: Store raw AI response for debugging
      // rawAiResponse: rawGeminiResponse,
      // Field for matching later
      matchedTransactionId: null,
    };

    // 7. Save to Firestore
    try {
      logger.info(`processReceiptImage: Saving extracted receipt data to Firestore for user ${userId}...`);
      const docRef = await db.collection("receipts").add(receiptDocData);
      logger.info(`processReceiptImage: Successfully saved receipt data with ID: ${docRef.id} for user ${userId}.`);
      // 8. Return Success Response (including new receipt ID)
      return {success: true, receiptId: docRef.id, message: "Receipt processed successfully."};
    } catch (error: unknown) {
      let errorMessage = "Unknown Firestore error saving receipt";
      if (error instanceof Error) {
        errorMessage = error.message;
      }
      logger.error(`processReceiptImage: Failed to save receipt data to Firestore for user ${userId}.`, {error: errorMessage});
      throw new HttpsError("internal", `Failed to save receipt data: ${errorMessage}`);
    }
  }
);

// --- NEW: matchReceipt Function ---
/**
 * Attempts to match a processed receipt in Firestore with a transaction document.
 */
export const matchReceipt = onCall(
  // Doesn't need Plaid/Gemini secrets directly, only Firestore access via Admin SDK
  async (request) => {
    // 1. Authentication Check
    if (!request.auth) {
      logger.error("matchReceipt: Authentication Error.");
      throw new HttpsError("unauthenticated", "Function must be called while authenticated.");
    }
    const userId = request.auth.uid;

    // 2. Validate Input Data
    const receiptId = request.data.receiptId as string | undefined;
    if (!receiptId) {
      logger.error("matchReceipt: Invalid argument - receiptId missing.", {userId: userId, data: request.data});
      throw new HttpsError("invalid-argument", "Missing 'receiptId' in request data.");
    }
    logger.info(`matchReceipt: Starting for user: ${userId}, receipt: ${receiptId}`);

    // 3. Fetch Receipt Document
    const receiptRef = db.collection("receipts").doc(receiptId);
    let receiptData: admin.firestore.DocumentData | undefined;
    try {
      const receiptSnapshot = await receiptRef.get();
      if (!receiptSnapshot.exists) {
        logger.error(`matchReceipt: Receipt document ${receiptId} not found.`);
        throw new HttpsError("not-found", `Receipt ${receiptId} not found.`);
      }
      receiptData = receiptSnapshot.data();
      // Basic validation
      if (!receiptData || receiptData.userId !== userId) {
        logger.error(`matchReceipt: Receipt ${receiptId} does not belong to user ${userId} or data missing.`);
        throw new HttpsError("permission-denied", "Receipt not found or access denied.");
      }
      if (receiptData.matchedTransactionId) {
        logger.info(`matchReceipt: Receipt ${receiptId} is already matched to transaction ${receiptData.matchedTransactionId}. Skipping.`);
        return {success: true, status: "already_matched", transactionId: receiptData.matchedTransactionId};
      }
      if (!receiptData.transactionDate || !(receiptData.transactionDate instanceof Timestamp) || typeof receiptData.totalAmount !== "number") {
        logger.error(`matchReceipt: Receipt ${receiptId} is missing required fields (transactionDate, totalAmount) or has invalid types.`);
        throw new HttpsError("failed-precondition", "Receipt data is incomplete or invalid for matching.");
      }
    } catch (error: unknown) {
      if (error instanceof HttpsError) {
        throw error;
      } // Re-throw specific errors
      logger.error(`matchReceipt: Failed to read receipt document ${receiptId}.`, {userId: userId, error});
      throw new HttpsError("internal", "Failed to read receipt data.");
    }

    // 4. Define Matching Parameters
    const receiptDate = (receiptData.transactionDate as Timestamp).toDate();
    const receiptAmount = Math.abs(receiptData.totalAmount); // Use absolute amount for comparison
    const dateToleranceDays = 2; // Look +/- 2 days around the receipt date
    const amountTolerance = 0.05; // Allow 5% difference in amount (adjust as needed)

    const startDate = Timestamp.fromDate(new Date(receiptDate.setDate(receiptDate.getDate() - dateToleranceDays)));
    // Reset date for endDate calculation
    receiptDate.setDate(receiptDate.getDate() + dateToleranceDays); // Go back to original day
    const endDate = Timestamp.fromDate(new Date(receiptDate.setDate(receiptDate.getDate() + dateToleranceDays)));

    const minAmount = Math.abs(receiptAmount * (1 - amountTolerance));
    const maxAmount = Math.abs(receiptAmount * (1 + amountTolerance));

    logger.info(`matchReceipt: Searching for transactions between ${startDate.toDate().toISOString()} and ${endDate.toDate().toISOString()}`);
    logger.info(`matchReceipt: Amount range: ${minAmount.toFixed(2)} to ${maxAmount.toFixed(2)} (target: ${receiptAmount.toFixed(2)})`);

    // 5. Query Potential Matching Transactions
    let potentialMatches: admin.firestore.QueryDocumentSnapshot[] = [];
    try {
      // Query based on userId, date range, amount range, and ensure not already matched
      const query = db.collection("transactions")
        .where("userId", "==", userId)
        .where("date", ">=", startDate)
        .where("date", "<=", endDate)
        // Firestore doesn't support range filtering on multiple fields directly.
        // We fetch based on date and filter amount/match status in code.
        // Index on userId + date will be needed.
        .orderBy("date", "desc"); // Order to potentially prioritize closer dates

      const querySnapshot = await query.get();

      // Filter results further in code
      potentialMatches = querySnapshot.docs.filter((doc) => {
        const txData = doc.data();
        const txAmount = Math.abs(txData.amount ?? 0);
        const alreadyMatched = !!txData.linkedReceiptId; // Check if linkedReceiptId exists and is truthy

        // Apply amount filter and check if already matched
        return !alreadyMatched && txAmount >= minAmount && txAmount <= maxAmount;
      });

      logger.info(`matchReceipt: Found ${potentialMatches.length} potential transactions within date range and amount tolerance.`);
    } catch (error: unknown) {
      logger.error(`matchReceipt: Firestore query failed for user ${userId}, receipt ${receiptId}.`, {error});
      // Check for index errors specifically
      if (error instanceof Error && error.message.includes("requires an index")) {
        logger.error("Firestore query requires an index (likely on userId and date). Please create it.");
        throw new HttpsError("failed-precondition", "Database query needs optimization. Please try again later.");
      }
      throw new HttpsError("internal", "Failed to query transactions.");
    }

    // 6. Select Best Match (or handle ambiguity)
    let bestMatchId: string | null = null;

    if (potentialMatches.length === 0) {
      logger.info(`matchReceipt: No suitable unmatched transactions found for receipt ${receiptId}.`);
      return {success: true, status: "no_match_found"};
    } else if (potentialMatches.length === 1) {
      // Only one match, assume it's correct
      bestMatchId = potentialMatches[0].id;
      logger.info(`matchReceipt: Found unique potential match: ${bestMatchId} for receipt ${receiptId}.`);
    } else {
      // Multiple potential matches - requires more sophisticated logic or user intervention
      // For V1, we will log and not match automatically.
      const potentialIds = potentialMatches.map((doc) => doc.id);
      logger.warn(`matchReceipt: Found multiple (${potentialMatches.length}) potential matches for receipt ${receiptId}.
         Requires disambiguation.`, {potentialIds});
      // TODO: Future: Implement scoring based on amount difference, merchant name similarity?
      // TODO: Future: Flag receipt for manual matching via UI?
      return {success: true, status: "multiple_matches_found", potentialIds: potentialIds};
    }

    // 7. Link Receipt and Transaction in Firestore (if unique match found)
    if (bestMatchId) {
      const transactionRef = db.collection("transactions").doc(bestMatchId);
      try {
        logger.info(`matchReceipt: Attempting to link receipt ${receiptId} and transaction ${bestMatchId}...`);
        // Use a batch write to update both documents atomically
        const batch = db.batch();
        batch.update(receiptRef, {matchedTransactionId: bestMatchId, status: "matched"});
        batch.update(transactionRef, {linkedReceiptId: receiptId});
        await batch.commit();
        logger.info(`matchReceipt: Successfully linked receipt ${receiptId} and transaction ${bestMatchId}.`);
        return {success: true, status: "matched", transactionId: bestMatchId};
      } catch (error: unknown) {
        logger.error(`matchReceipt: Firestore batch update failed when linking receipt ${receiptId} and transaction ${bestMatchId}.`, {error});
        throw new HttpsError("internal", "Failed to link receipt and transaction.");
      }
    }

    // Should not be reached if logic is correct, but included as fallback
    logger.warn("matchReceipt: Reached end of function unexpectedly.");
    return {success: false, status: "unexpected_state"};
  }
);

// Helper function for date range calculation
function getDateRangeForSankey(
  period: string,
  offset: number = 0,
  nowOverride?: Date
): { startDate: admin.firestore.Timestamp; endDate: admin.firestore.Timestamp } | null {
  const now = nowOverride ? new Date(nowOverride.getTime()) : new Date();
  let CDate = new Date(now.getTime()); // Clone 'now' to avoid modifying it directly initially

  let year: number;
  let month: number; // 0-11 for month

  switch (period.toLowerCase()) {
    case "monthly":
      CDate = new Date(now.getFullYear(), now.getMonth(), 1); // Start with the 1st of the current month
      CDate.setMonth(CDate.getMonth() + offset);
      year = CDate.getFullYear();
      month = CDate.getMonth();
      break;
    case "yearly":
      CDate = new Date(now.getFullYear(), 0, 1); // Start with Jan 1st of the current year
      CDate.setFullYear(CDate.getFullYear() + offset);
      year = CDate.getFullYear();
      month = 0; // Not directly used for yearly start/end but consistent
      break;
    case "yeartodate": // Changed from "yeartodate" to "yearToDate" to match frontend
      if (offset !== 0) {
        logger.warn("getDateRangeForSankey: offset is ignored for 'yearToDate'", { period, offset });
      }
      year = now.getFullYear();
      month = 0;
      break;
    default:
      logger.error("getDateRangeForSankey: Invalid period provided.", { period });
      return null;
  }

  let startDateBoundary: Date;
  let endDateBoundary: Date;

  switch (period.toLowerCase()) {
    case "monthly":
      startDateBoundary = new Date(year, month, 1, 0, 0, 0, 0);
      endDateBoundary = new Date(year, month + 1, 0, 23, 59, 59, 999); // Day 0 of next month is last day of current
      break;
    case "yearly":
      startDateBoundary = new Date(year, 0, 1, 0, 0, 0, 0);
      endDateBoundary = new Date(year, 11, 31, 23, 59, 59, 999);
      break;
    case "yeartodate": // Changed from "yeartodate" to "yearToDate"
      startDateBoundary = new Date(year, 0, 1, 0, 0, 0, 0);
      // endDate for YTD is the 'now' at the moment function is called, up to end of that day
      const ytdEndDate = nowOverride ? new Date(nowOverride.getTime()) : new Date();
      endDateBoundary = new Date(ytdEndDate.getFullYear(), ytdEndDate.getMonth(), ytdEndDate.getDate(), 23, 59, 59, 999);
      break;
    default:
      return null; // Should be caught by first switch
  }

  return {
    startDate: admin.firestore.Timestamp.fromDate(startDateBoundary),
    endDate: admin.firestore.Timestamp.fromDate(endDateBoundary),
  };
}

export const getSankeyData = onCall(async (request) => {
  logger.info("getSankeyData function invoked.", { uid: request.auth?.uid, data: request.data });

  if (!request.auth) {
    logger.error("Authentication error: User is not authenticated.", { functionName: "getSankeyData" });
    throw new HttpsError("unauthenticated", "The function must be called while authenticated.");
  }
  const userId = request.auth.uid;

  const { period, dateOffset = 0 } = request.data as { period: string; dateOffset?: number };

  if (!period || !["monthly", "yearToDate", "yearly"].includes(period)) {
    logger.error("Invalid 'period' parameter.", { userId, requestData: request.data });
    throw new HttpsError("invalid-argument", "Invalid 'period' specified. Must be 'monthly', 'yearToDate', or 'yearly'.");
  }
  if (typeof dateOffset !== 'number' || isNaN(dateOffset)) {
      logger.error("Invalid 'dateOffset' parameter. Must be a number.", { userId, requestData: request.data });
      throw new HttpsError("invalid-argument", "Invalid 'dateOffset' specified. Must be a number.");
  }

  try {
    const dateRange = getDateRangeForSankey(period, dateOffset);
    if (!dateRange) {
      logger.error("Failed to calculate date range, likely invalid period.", { userId, period, dateOffset });
      throw new HttpsError("invalid-argument", "Invalid period or dateOffset resulting in date range calculation failure.");
    }

    logger.info(`Calculated date range for user ${userId}: ${dateRange.startDate.toDate().toISOString()} to ${dateRange.endDate.toDate().toISOString()}`, { period, dateOffset });

    const db = admin.firestore(); // Ensure db is initialized
    let transactionsSnapshot;
    try {
      transactionsSnapshot = await db.collection("transactions")
        .where("userId", "==", userId)
        .where("date", ">=", dateRange.startDate)
        .where("date", "<=", dateRange.endDate)
        .get();
    } catch (error) {
      logger.error("Firestore error while fetching transactions:", { userId, period, dateOffset, error });
      throw new HttpsError("internal", "An error occurred while fetching your financial data.");
    }

    const fetchedTransactions: FirebaseFirestore.DocumentData[] = [];
    transactionsSnapshot.forEach(doc => {
      fetchedTransactions.push(doc.data());
    });
    logger.info(`Fetched ${fetchedTransactions.length} transactions for user ${userId}.`);

    let totalIncome = 0;
    let totalExpenses = 0;
    const incomeSources: { [key: string]: number } = {};
    const expenseCategories: { [key: string]: number } = {};

    if (fetchedTransactions.length > 0) {
      for (const tx of fetchedTransactions) {
        const amount = tx.amount as number;
        const categories = tx.category as string[] || [];

        if (typeof amount !== 'number' || isNaN(amount)) {
          logger.warn("Skipping transaction with invalid amount:", { userId, transactionId: tx.plaidTransactionId || 'N/A', amount });
          continue;
        }

        if (amount < 0) { // Income
          const incomeAmount = Math.abs(amount);
          totalIncome += incomeAmount;
          const incomeSourceName = "Income"; // V1: Single income source
          incomeSources[incomeSourceName] = (incomeSources[incomeSourceName] || 0) + incomeAmount;
        } else if (amount > 0) { // Expense
          const expenseAmount = amount;
          totalExpenses += expenseAmount;
          const primaryCategory = categories[0] || "Uncategorized";
          expenseCategories[primaryCategory] = (expenseCategories[primaryCategory] || 0) + expenseAmount;
        }
      }
    }
     const savingsBuffer = totalIncome - totalExpenses;
    logger.info("Data aggregation complete.", { userId, totalIncome, totalExpenses, savingsBuffer });

    const sankeyLinks: Array<{ from: string; to: string; value: number }> = [];

    if (totalIncome > 0) {
      for (const sourceName in incomeSources) {
        if (incomeSources.hasOwnProperty(sourceName) && incomeSources[sourceName] > 0) {
          sankeyLinks.push({ from: sourceName, to: "Total Income", value: incomeSources[sourceName] });
        }
      }
    } else if (Object.keys(incomeSources).length > 0 && totalIncome === 0) {
        for (const sourceName in incomeSources) {
            if (incomeSources.hasOwnProperty(sourceName)) {
                 sankeyLinks.push({ from: sourceName, to: "Total Income", value: 0 });
            }
        }
    }
    
    if (totalIncome > 0 || totalExpenses > 0) { // Links from "Total Income" to expense categories
        for (const categoryName in expenseCategories) {
            if (expenseCategories.hasOwnProperty(categoryName) && expenseCategories[categoryName] > 0) {
                sankeyLinks.push({ from: "Total Income", to: categoryName, value: expenseCategories[categoryName] });
            }
        }
    }

    if (savingsBuffer > 0 && totalIncome > 0) {
      sankeyLinks.push({ from: "Total Income", to: "Savings/Buffer", value: savingsBuffer });
    }

    logger.info("Formatted Sankey links.", { userId, linksCount: sankeyLinks.length });

    return {
      links: sankeyLinks,
      totalIncome: totalIncome,
      totalExpenses: totalExpenses,
      savingsBuffer: savingsBuffer,
    };

  } catch (error: any) { // Changed from 'any' to 'unknown' for stricter typing, then cast
    if (error instanceof HttpsError) {
      logger.warn(`Caught HttpsError in getSankeyData: ${error.code} - ${error.message}`, { userId: request.auth?.uid, details: error.details });
      throw error;
    }
    logger.error("Unexpected error in getSankeyData:", {
      userId: request.auth?.uid,
      requestData: request.data, // Be cautious if data can be very large or sensitive
      errorObject: error, // Log the actual error object
      errorMessage: error.message, // error.message might not exist if 'error' is not Error instance
      errorStack: error.stack // error.stack might not exist
    });
    // Provide a generic error message to the client
    throw new HttpsError("internal", "An unexpected error occurred while processing your Sankey data.");
  }
});

