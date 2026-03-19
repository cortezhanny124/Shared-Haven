// ignore_for_file: unused_local_variable

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:bdk_dart/bdk.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_wallet/exceptions/validation_result.dart';
import 'package:flutter_wallet/hive/wallet_data.dart';
import 'package:flutter_wallet/languages/app_localizations.dart';
import 'package:flutter_wallet/services/wallet_storage_service.dart';
import 'package:flutter_wallet/settings/settings_provider.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:english_words/english_words.dart';
import 'package:convert/convert.dart';
import 'package:collection/collection.dart';

/// WalletService Class
///
/// A comprehensive service class for managing Bitcoin wallets using the BDK (Bitcoin Dev Kit)
/// library. This service handles both single-signature and multi-signature wallet operations,
/// descriptor-based wallet management, transaction creation, blockchain synchronization,
/// and interaction with various blockchain APIs (Electrum, Esplora, Mempool.space).
///
/// The class supports multiple Bitcoin networks (testnet/mainnet) and provides extensive
/// functionality for wallet creation, transaction building, signing, broadcasting, and
/// UTXO management. It also includes utilities for multi-signature wallets with timelock
/// conditions and policy-based spending paths.
///
/// Key Features:
/// - Single and multi-signature wallet creation/restoration
/// - Descriptor-based wallet management with BIP84 support
/// - Transaction building with custom fee rates and change addresses
/// - PSBT (Partially Signed Bitcoin Transaction) creation and signing
/// - Multi-signature support with timelock conditions (CLTV/CSV)
/// - Blockchain synchronization via Electrum servers
/// - UTXO management and balance tracking
/// - Fee rate estimation from multiple sources
/// - Transaction history and status tracking
/// - Offline transaction creation support
///
/// **INDEX**
///
/// **Initialization & Connection**
/// - `getWorkingEndpoint`: Finds a working blockchain API endpoint
/// - `get baseUrl`: Returns the base URL for blockchain API calls
/// - `get electrumServers`: Returns Electrum servers based on network
/// - `blockchainInit`: Initializes connection to blockchain via Electrum
/// - `syncWallet`: Synchronizes wallet with the blockchain
///
/// **Wallet Creation & Management**
/// - `createOrRestoreWallet`: Creates or restores a single-signature wallet
/// - `createSharedWallet`: Creates a multi-signature wallet from descriptor
/// - `loadSavedWallet`: Loads a previously saved wallet from storage
/// - `checkMnemonic`: Validates if a mnemonic can create a valid wallet
/// - `getDescriptors`: Generates BIP84 descriptors from mnemonic
/// - `isValidDescriptor`: Validates a wallet descriptor against a public key
/// - `saveLocalData`: Persists wallet data to local storage
///
/// **Balance & Address Operations**
/// - `getBalance`: Retrieves total wallet balance
/// - `getBitcoinBalance`: Fetches confirmed and pending balances
/// - `getAddress`: Gets current receiving address
/// - `getAddressFromScriptOutput`: Extracts address from transaction output
/// - `getAddressFromScriptInput`: Extracts address from transaction input
/// - `validateAddress`: Validates a Bitcoin address format
/// - `areEqualAddresses`: Checks if all outputs have same address
///
/// **Transaction Operations**
/// - `sendSingleTx`: Creates, signs, and broadcasts single-signature transaction
/// - `createPartialTx`: Creates a PSBT for multi-signature transaction
/// - `signBroadcastTx`: Signs a PSBT and broadcasts to network
/// - `createBackupTx`: Creates backup transaction (similar to createPartialTx)
/// - `calculateSendAllBalance`: Calculates maximum spendable amount after fees
/// - `getUtxos`: Fetches UTXOs with confirmation status
/// - `checkCondition`: Checks if UTXOs meet spending conditions
///
/// **Fee Management**
/// - `getFeeRate`: Gets current recommended fee rate
/// - `fetchRecommendedFees`: Fetches complete fee estimates (fastest, half-hour, hour)
///
/// **Blockchain Data**
/// - `fetchCurrentBlockHeight`: Gets current blockchain height
/// - `fetchBlockTimestamp`: Gets timestamp for a specific block
/// - `getTransactions`: Fetches wallet transaction history
/// - `calculateRemainingTimeInSeconds`: Calculates time for block confirmations
/// - `formatTime`: Formats duration in human-readable form
/// - `sortTransactionsByConfirmations`: Sorts transactions by confirmation count
///
/// **Multi-signature Utilities**
/// - `replacePubKeyWithPrivKeyMultiSig`: Replaces public keys with private in multisig descriptor
/// - `replacePubKeyWithPrivKeyOlder`: Replaces public keys with private in timelocked descriptors
/// - `extractOlderWithPrivateKey`: Extracts "older" value with private keys
/// - `deriveDescriptorKeys`: Derives secret and public keys from mnemonic
/// - `makeChangeDescriptor`: Creates change descriptor from receive descriptor
/// - `extractPublicKeysWithAliases`: Extracts public keys with their aliases
/// - `getAliasesFromFingerprint`: Gets aliases from fingerprints
///
/// **Policy & Path Extraction**
/// - `extractAllPathsToFingerprint`: Extracts all policy paths for a fingerprint
/// - `extractDataByFingerprint`: Extracts data related to a specific fingerprint
/// - `extractAllPaths`: Extracts all policy paths from wallet descriptor
/// - `extractSpendingPathFromPsbt`: Determines spending path used in PSBT
/// - `extractSignersFromPsbt`: Identifies signers from PSBT
///
/// **Utilities & Helpers**
/// - `printInChunks`: Prints long strings in manageable chunks
/// - `printPrettyJson`: Pretty-prints JSON for debugging
/// - `printPsbtJson`: Pretty-prints PSBT JSON structure
/// - `generateRandomName`: Generates random wallet name
/// - `formatDuration`: Formats duration for display
/// - `convertSatoshisToCurrency`: Converts satoshis to fiat currency
/// - `stripChecksum`: Removes checksum from descriptor
/// - `_isImmediateMultisig`: Checks if path is immediate multisig
/// - `_pathAt`: Safely gets path at index

const int avgBlockTime = 600;
bool oldCase = false;

class WalletService extends ChangeNotifier {
  final WalletStorageService _walletStorageService = WalletStorageService();
  final SettingsProvider settingsProvider;

  WalletService(this.settingsProvider);

  late Wallet wallet;
  late Persister persister;
  // late Blockchain blockchain;

  final List<String> testnetEndpoints = [
    // 'https://mempool.space/testnet4/api',
    'https://blockstream.info/testnet/api/',
    'https://mempool.space/testnet/api/',
  ];

  final List<String> mainnetEndpoints = [
    'https://mempool.space/api/',
    // Add another if you want
  ];

  Future<String> getWorkingEndpoint(Network network) async {
    final endpoints =
        network == Network.testnet ? testnetEndpoints : mainnetEndpoints;

    for (final endpoint in endpoints) {
      try {
        // Quick health check(HEAD or simple GET)
        final response = await http
            .get(Uri.parse('${endpoint}blocks/tip/height'))
            .timeout(const Duration(seconds: 3));

        if (response.statusCode == 200) {
          // print("✅ Using endpoint: $endpoint");
          return endpoint;
        }
      } catch (e) {
        print("⚠️ Failed endpoint: $endpoint → $e");
      }
    }

    throw Exception("No available endpoint for $network");
  }

  Future<String> get baseUrl async {
    return await getWorkingEndpoint(settingsProvider.network);
  }

  // TESTNET3
  List<String> get electrumServers {
    switch (settingsProvider.network) {
      case Network.testnet:
        return ["ssl://electrum.blockstream.info:60002"];
      case Network.bitcoin:
        return ["ssl://electrum.blockstream.info:50002"];
      default:
        return [""];
    }
  }

  // TESTNET4
  // List<String> get electrumServers {
  //   switch (settingsProvider.network) {
  //     case Network.testnet:
  //       return ["ssl://mempool.space:40002"];
  //     case Network.bitcoin:
  //       return ["ssl://electrum.blockstream.info:50002"];
  //     default:
  //       return [""];
  //   }
  // }

  ///
  ///
  ///
  ///
  ///
  ///
  ///
  /// Common Methods
  ///
  ///
  ///
  ///
  ///
  ///

  Future<ValidationResult> isValidDescriptor(
    String descriptorStr,
    String? publicKey,
    BuildContext context,
  ) async {
    try {
      // print('🔐 Validating descriptor...');
      // print('📬 Public Key: $publicKey');
      // print('🧾 Descriptor (full):');
      // printInChunks(descriptorStr);

      if (publicKey != null) {
        final last3 = publicKey.substring(0, publicKey.length - 3);
        // print('🔍 Checking if descriptor contains pubkey: "$last3"');

        if (descriptorStr.contains(last3)) {
          // print('💾 Attempting to create wallet in memory...');
          await createSharedWallet(descriptorStr);
          // print('🎉 Wallet creation successful.');

          return ValidationResult(isValid: true);
        } else {
          // print('❌ Descriptor does NOT contain expected public key fragment.');
          return ValidationResult(
            isValid: false,
            errorMessage: AppLocalizations.of(
              context,
            )!
                .translate('error_public_key_not_contained'),
          );
        }
      }

      print('ciao');

      await createSharedWallet(descriptorStr);
      // print('🎉 Wallet creation successful.');

      return ValidationResult(isValid: true);
    } catch (e) {
      print('💥 Error during descriptor/wallet creation: $e');
      return ValidationResult(
        isValid: false,
        errorMessage: AppLocalizations.of(
          context,
        )!
            .translate('error_wallet_descriptor'),
      );
    }
  }

  BigInt getBalance(Wallet wallet) {
    Balance balance = wallet.balance();

    // print(balance.total.toSat());

    return BigInt.from(balance.total.toSat());
  }

  Future<bool> checkMnemonic(String mnemonic) async {
    try {
      final descriptors = getDescriptors(mnemonic);

      persister = Persister.newInMemory();

      wallet = Wallet(
        descriptors[0],
        descriptors[1],
        settingsProvider.network,
        persister,
        100,
      );

      wallet.persist(persister);

      return true;
    } catch (e) {
      // print("Error: ${e.toString()}");
      return false;
    }
  }

  Future<Wallet> loadSavedWallet({String? mnemonic}) async {
    var walletBox = Hive.box('walletBox');
    String? savedMnemonic = walletBox.get('walletMnemonic');

    // print(savedMnemonic);

    if (savedMnemonic != null) {
      // Restore the wallet using the saved mnemonic
      wallet = await createOrRestoreWallet(savedMnemonic);
      // print(wallet);
      return wallet;
    } else {
      wallet = await createOrRestoreWallet(mnemonic!);
    }
    return wallet;
  }

  Future<void> syncWallet(Wallet wallet) async {
    try {
      await blockchainInit(
        wallet: wallet,
        persister: persister,
      ); // Ensure blockchain is initialized before usage

      // print('Blockchain initialized');
    } catch (e) {
      throw Exception("Blockchain initialization failed: ${e.toString()}");
    }
  }

  String getAddress(Wallet wallet) {
    // await syncWallet(wallet);

    var addressInfo = wallet.revealNextAddress(KeychainKind.external_);

    // print('New Address generated: ${addressInfo.address.asString()}');

    return addressInfo.address.toString();
  }

  /// Fetches and calculates confirmed & pending balance
  Future<Map<String, int>> getBitcoinBalance(String address) async {
    try {
      final int confirmedBalance = wallet.balance().trustedSpendable.toSat();

      // print('confirmedBalance: $confirmedBalance');

      final int pendingBalance = wallet.balance().untrustedPending.toSat();

      // print('pendingBalance: $pendingBalance');

      return {
        "confirmedBalance": confirmedBalance,
        "pendingBalance": pendingBalance,
      };
    } catch (e) {
      print("Error fetching balance: $e");
      return {"confirmedBalance": 0, "pendingBalance": 0};
    }
  }

  Future<int> calculateSendAllBalance({
    required String recipientAddress,
    required Wallet wallet,
    required Amount availableBalance,
    required WalletService walletService,
    double? customFeeRate,
  }) async {
    try {
      final feeRate = customFeeRate ?? await getFeeRate();

      // print(customFeeRate);
      // print(feeRate);
      // print(availableBalance);

      final recipient = Address(
        recipientAddress,
        settingsProvider.network,
      );
      final recipientScript = recipient.scriptPubkey();

      final txBuilder = TxBuilder();

      txBuilder
          .addRecipient(recipientScript, availableBalance)
          .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
          .finish(wallet);

      return availableBalance.toSat();
    } catch (e) {
      print(e);
      // Handle insufficient funds

      if (e.toString().contains("Insufficient funds:")) {
        // More flexible regex that extracts both BTC amounts
        final RegExp regex =
            RegExp(r'([\d.]+)\s*BTC\s+available.*?([\d.]+)\s*BTC\s+needed');
        final match = regex.firstMatch(e.toString());

        if (match != null) {
          final double availableBTC = double.parse(match.group(1)!);
          final double neededBTC = double.parse(match.group(2)!);

          final int availableAmount = (availableBTC * 100000000).round();
          final int neededAmount = (neededBTC * 100000000).round();

          final int fee = neededAmount - availableAmount;
          final int sendAllBalance = availableBalance.toSat() - fee;

          if (sendAllBalance > 0) {
            return sendAllBalance;
          } else {
            throw Exception('No balance available after fee deduction');
          }
        } else {
          throw Exception(
              'Failed to extract amounts from exception: ${e.toString()}');
        }
      } else {
        rethrow;
      }
    }
  }

  Future<void> blockchainInit({
    required Wallet wallet,
    required Persister persister,
  }) async {
    // print('[SYNC] Starting blockchainInit...');
    // print('[SYNC] Electrum servers list: $electrumServers');

    for (final server in electrumServers) {
      // print('[SYNC] Trying Electrum server: $server');

      try {
        // print('[SYNC] Creating ElectrumClient...');
        // print('[SYNC] ElectrumClient created');

        /**
         * startFullScan() makes synchronous FFI calls into rust,
         * so they block whatever dart thread they run on.
         * If that's the main/UI isolate, your app freezes until the call returns.
         * 
         * Isolate.run() moves the heavy network + chain-scan work to a background isolate so the UI stays responsive.
         */

        final update = await Isolate.run(
          () {
            final client = ElectrumClient(server, null);
            try {
              // print('[SYNC] Trying Electrum server: $server');

              final syncRequest = wallet.startFullScan().build();

              final Update result = client.fullScan(
                syncRequest,
                50,
                100,
                true,
              );

              return result;
            } finally {
              client.dispose();
            }
          },
        );

        wallet.applyUpdate(update);

        wallet.persist(persister);

        return;
      } catch (e, st) {
        print('[SYNC][ERROR] Failed Electrum server $server');
        print('[SYNC][ERROR] $e');
        print('[SYNC][STACKTRACE]\n$st');
      }
    }

    // print('[SYNC][FATAL] All Electrum servers failed');
    throw Exception("Failed to connect to any Electrum server.");
  }

  Future<List<Map<String, dynamic>>> getTransactions() async {
    // print('[TX] Starting getTransactions()');

    try {
      final results = <Map<String, dynamic>>[];

      // print('[TX] Fetching canonical transactions from wallet...');
      final canonical = wallet.transactions();

      for (final c in canonical) {
        // print('[TX] Processing canonical tx...');

        final transaction = c.transaction;
        final chainPosition = c.chainPosition;

        final txid = transaction.computeTxid();
        // print('[TX] Computed txid: $txid');

        // Get transaction details including sent, received, and fee
        final txDetails = wallet.txDetails(txid);

        // Build transaction details map from the available data
        final Map<String, dynamic> txMap = {
          'txid': txid.toString(),
          // 'transaction': transaction,
          'confirmationTime':
              _getConfirmationTimeFromChainPosition(chainPosition),
          'sent': txDetails!.sent.toSat(),
          'received': txDetails.received.toSat(),
          'fee': txDetails.fee?.toSat(),
          'feeRate': txDetails.feeRate,
        };

        results.add(txMap);
        // print('[TX] Added tx $txid to results');
      }

      // print('[TX] getTransactions() completed. Total: ${results.length}');
      return results;
    } catch (e, st) {
      print('[TX][ERROR] Failed to fetch transactions');
      print('[TX][ERROR] $e');
      print('[TX][STACKTRACE]\n$st');
      throw Exception('Failed to fetch transactions: $e');
    }
  }

  Map<String, dynamic>? _getConfirmationTimeFromChainPosition(
      ChainPosition chainPosition) {
    // Check the actual runtime type
    if (chainPosition is ConfirmedChainPosition) {
      // print('[TX] Transaction is CONFIRMED');

      final confirmationBlockTime = chainPosition.confirmationBlockTime;

      return {
        'height': confirmationBlockTime.blockId.height,
        'timestamp': confirmationBlockTime.confirmationTime,
        'transitively': chainPosition.transitively?.toString(),
      };
    } else if (chainPosition is UnconfirmedChainPosition) {
      // print('[TX] Transaction is UNCONFIRMED');

      return {
        'height': null,
        'timestamp': chainPosition.timestamp,
        'unconfirmed': true,
      };
    } else {
      // print(
      //     '[TX][WARN] Unknown chain position type: ${chainPosition.runtimeType}');
      return null;
    }
  }

  List<Map<String, dynamic>> sortTransactionsByConfirmations(
    List<Map<String, dynamic>> transactions,
    int currentHeight,
  ) {
    // print('=== Sorting Transactions by Confirmations ===');
    // print('Current blockchain height: $currentHeight');
    // print('Number of transactions to sort: ${transactions.length}');

    // Create a copy to avoid modifying the original list
    final sortedTransactions = List<Map<String, dynamic>>.from(transactions);

    sortedTransactions.sort((a, b) {
      // Extract block heights from transaction data
      final blockHeightA = a['confirmationTime']?['height'];
      final blockHeightB = b['confirmationTime']?['height'];

      // Compute confirmations
      final confirmationsA = (blockHeightA != null && blockHeightA is int)
          ? currentHeight - blockHeightA
          : -1;

      final confirmationsB = (blockHeightB != null && blockHeightB is int)
          ? currentHeight - blockHeightB
          : -1;

      // print('  Comparing:');
      // print('    TX A - Height: $blockHeightA, Confirmations: $confirmationsA');
      // print('    TX B - Height: $blockHeightB, Confirmations: $confirmationsB');

      // Lower confirmations should come FIRST (unconfirmed at the top)
      return confirmationsA.compareTo(confirmationsB);
    });

    // Log the final sorted order
    // print('\nSorted transaction order (lower confirmations first):');
    for (var i = 0; i < sortedTransactions.length; i++) {
      final tx = sortedTransactions[i];
      final blockHeight = tx['confirmationTime']?['height'];
      final confirmations = (blockHeight != null && blockHeight is int)
          ? currentHeight - blockHeight
          : -1;
      final isUnconfirmed = tx['confirmationTime']?['unconfirmed'] == true;
      final txid = tx['txid']?.toString();
      final shortTxid = txid != null ? '${txid.substring(0, 8)}...' : 'unknown';

      String status;
      if (isUnconfirmed) {
        status = 'UNCONFIRMED';
      } else if (blockHeight != null) {
        status = '$confirmations confirmations';
      } else {
        status = 'unknown';
      }

      // print('  [$i] $shortTxid - $status (Block: $blockHeight)');
    }
    // print('=== End of sorting ===\n');

    return sortedTransactions;
  }

  Future<int> fetchCurrentBlockHeight() async {
    final client = EsploraClient(await baseUrl, null);
    try {
      return client.getHeight();
    } finally {
      client.dispose();
    }
  }

  Future<String> fetchBlockTimestamp(int height) async {
    try {
      String currentHash = "";

      final client = EsploraClient(await baseUrl, null);
      try {
        currentHash = client.getBlockHash(client.getHeight()).toString();
      } finally {
        client.dispose();
      }

      // print('currentHash: $currentHash');

      // API endpoint to fetch block details
      final String blockApiUrl = '${await baseUrl}/block/$currentHash';

      // print(blockApiUrl);

      // Make GET request to fetch block details
      final response = await http.get(Uri.parse(blockApiUrl));

      if (response.statusCode == 200) {
        // Decode JSON response
        final Map<String, dynamic> jsonData = json.decode(response.body);

        // Check if data contains the `time` field
        if (jsonData.containsKey('timestamp')) {
          int timestamp = jsonData['timestamp']; // Extract timestamp

          // print('timestamp from method: $timestamp');

          DateTime formattedTime =
              DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
          if (settingsProvider.isTestnet) {
            formattedTime = formattedTime.subtract(const Duration(hours: 2));
          }

          return formattedTime
              .toString()
              .substring(0, formattedTime.toString().length - 7);
        } else {
          print('Error: "timestamp" field not found in response.');
          throw Exception('Block API response missing timestamp field.');
        }
      } else {
        // Handle HTTP errors for block details API
        print('HTTP Error (Block API): ${response.statusCode}');
        throw Exception('HTTP Error (Block API): ${response.statusCode}');
      }
    } catch (e) {
      // Handle any unexpected exceptions
      print('Exception occurred: $e');
      throw Exception('Failed to fetch block timestamp: $e');
    }
  }

  Future<int> calculateRemainingTimeInSeconds(int remainingBlocks) async {
    if (avgBlockTime > 0) {
      // Calculate remaining time in seconds
      return remainingBlocks * avgBlockTime;
    } else {
      throw Exception('Invalid average block time.');
    }
  }

  String formatTime(int totalSeconds, BuildContext context) {
    if (totalSeconds <= 0) {
      return AppLocalizations.of(context)!.translate('zero_seconds');
    }

    const secondsInYear = 31536000;
    const secondsInMonth = 2592000;
    const secondsInDay = 86400;
    const secondsInHour = 3600;
    const secondsInMinute = 60;

    final years = totalSeconds ~/ secondsInYear;
    totalSeconds %= secondsInYear;

    final months = totalSeconds ~/ secondsInMonth;
    totalSeconds %= secondsInMonth;

    final days = totalSeconds ~/ secondsInDay;
    totalSeconds %= secondsInDay;

    final hours = totalSeconds ~/ secondsInHour;
    totalSeconds %= secondsInHour;

    final minutes = totalSeconds ~/ secondsInMinute;
    final seconds = totalSeconds % secondsInMinute;

    final loc = AppLocalizations.of(context)!;

    String formatUnit(int value, String singularKey, String pluralKey) {
      if (value == 0) return '';
      final label = loc.translate(value == 1 ? singularKey : pluralKey);
      return '$value $label';
    }

    List<String> parts = [];

    parts.addAll([
      formatUnit(years, 'year', 'years'),
      formatUnit(months, 'month', 'months'),
      formatUnit(days, 'day', 'days'),
      formatUnit(hours, 'hour', 'hours'),
      formatUnit(minutes, 'minute', 'minutes'),
      formatUnit(seconds, 'second', 'seconds'),
    ]);

    // Filter out empty parts and join with commas
    return parts.where((p) => p.isNotEmpty).join(', ');
  }

  Future<List<dynamic>> getUtxos() async {
    // print('[DEBUG] Starting getUtxos()');
    List<dynamic> finalUtxos = [];

    // print('[DEBUG] Fetching wallet UTXOs...');
    final walletUtxos = wallet.listUnspent();
    // print('[DEBUG] Found ${walletUtxos.length} UTXOs in wallet');

    for (var i = 0; i < walletUtxos.length; i++) {
      final utxo = walletUtxos[i];
      final txid = utxo.outpoint.txid.toString();
      final vout = utxo.outpoint.vout;
      final value = utxo.txout.value;
      final keychain = utxo.keychain;
      final isSpent = utxo.isSpent;
      final derivationIndex = utxo.derivationIndex;
      final chainPosition = utxo.chainPosition;

      // print(
      //     '[DEBUG] Processing UTXO ${i + 1}/${walletUtxos.length}: $txid:$vout');
      // print('[DEBUG]   - Value: $value sats');
      // print('[DEBUG]   - Keychain: $keychain');
      // print('[DEBUG]   - Is spent: $isSpent');
      // print('[DEBUG]   - Derivation index: $derivationIndex');

      // Build status from chain position (reusing our existing method)
      final confirmationInfo =
          _getConfirmationTimeFromChainPosition(chainPosition);

      final status = {
        'confirmed':
            confirmationInfo != null && confirmationInfo['height'] != null,
        'block_height': confirmationInfo?['height'],
        'block_time': confirmationInfo?['timestamp'],
        'unconfirmed': confirmationInfo?['unconfirmed'] == true,
      };

      // print(
      //     '[DEBUG] UTXO status - confirmed: ${status['confirmed']}, height: ${status['block_height']}');

      // You can optionally still fetch additional data from the API if needed
      // But the chainPosition already has confirmation info
      if (status['confirmed'] == true) {
        // print('[DEBUG] UTXO is confirmed - using chain position data');
        finalUtxos.add({
          'txid': txid,
          'vout': vout,
          'status': status,
          'value': value.toSat(), // Convert Amount to int if needed
          'keychain': keychain.toString(),
          'derivationIndex': derivationIndex,
          'isSpent': isSpent,
        });
      } else {
        // print('[DEBUG] UTXO is unconfirmed - using chain position data');
        finalUtxos.add({
          'txid': txid,
          'vout': vout,
          'status': status,
          'value': value.toSat(), // Convert Amount to int if needed
          'keychain': keychain.toString(),
          'derivationIndex': derivationIndex,
          'isSpent': isSpent,
        });
      }

      // print(
      //     '[DEBUG] Added UTXO to final list. Current count: ${finalUtxos.length}');
    }

    // print('[DEBUG] Completed getUtxos(). Returning ${finalUtxos.length} UTXOs');
    return finalUtxos;
  }

  bool checkCondition(
    Map<String, dynamic> data,
    List<dynamic> utxos,
    String amount,
    int currentHeight,
  ) {
    final type = (data['type'] ?? '').toString();
    final rawTimelock = data['timelock'];
    final int timelock = (rawTimelock is int) ? rawTimelock : 0;

    final requiredAmount = double.tryParse(amount) ?? 0.0;

    // print(
    //     "[WalletService.checkCondition] → type=$type, timelock=$rawTimelock (norm=$timelock), "
    //     "amount='$amount' ($requiredAmount), height=$currentHeight, utxos=${utxos.length}");

    // MULTISIG with no timelock: keep your original short-circuit
    final isMultisigNoTimelock =
        type.contains('MULTISIG') && rawTimelock == null;
    if (isMultisigNoTimelock) {
      // print("[WalletService.checkCondition] MULTISIG (no timelock) → TRUE");
      return true;
    }

    final isAbsolute =
        type.contains('ABSOLUTETIMELOCK'); // CLTV / AFTER <height>
    final isRelative =
        type.contains('RELATIVETIMELOCK'); // CSV / OLDER <blocks>

    double totalSpendable = 0.0;

    if (isAbsolute) {
      // CLTV: path is unlocked iff chain height reached/passed absolute height
      final pathUnlocked = (timelock == 0) || (currentHeight >= timelock);
      // print(
      //     "[WalletService.checkCondition] ABSOLUTE (AFTER height=$timelock) → "
      //     "currentHeight($currentHeight) >= timelock($timelock)? $pathUnlocked");

      if (!pathUnlocked) {
        // print(
        //     "[WalletService.checkCondition] REASON: absolute height not reached.");
        return false;
      }

      // If unlocked, all UTXOs are eligible (no per-UTXO CSV needed)
      for (var i = 0; i < utxos.length; i++) {
        final utxoValueRaw = utxos[i]['value'] ?? 0.0;
        final v = double.tryParse(utxoValueRaw.toString()) ?? 0.0;
        totalSpendable += v;
        // print(
        //     "[WalletService.checkCondition]   ABS add UTXO[$i] value=$v → total=$totalSpendable");
      }
    } else if (isRelative) {
      // CSV: per-UTXO confirmations must reach 'timelock'
      for (var i = 0; i < utxos.length; i++) {
        final status =
            (utxos[i]['status'] is Map) ? utxos[i]['status'] as Map : const {};
        final blockHeight = status['block_height'] ?? 0; // 0 → unconfirmed
        final utxoValueRaw = utxos[i]['value'] ?? 0.0;
        final v = double.tryParse(utxoValueRaw.toString()) ?? 0.0;

        final hasHeight = blockHeight is int && blockHeight > 0;
        final confirmations = hasHeight ? (currentHeight - blockHeight) : 0;
        final spendable =
            (timelock == 0) ? true : (hasHeight && confirmations >= timelock);

        // print("[WalletService.checkCondition] RELATIVE UTXO[$i] "
        //     "bh=$blockHeight, conf=$confirmations, need=$timelock → spendable=$spendable, value=$v");

        if (spendable) {
          totalSpendable += v;
          // print(
          //     "[WalletService.checkCondition]   CSV add → total=$totalSpendable");
        }
      }
    } else {
      // Fallback (unknown type): keep old conservative per-UTXO rule
      // print(
      //     "[WalletService.checkCondition] Unknown type → fallback CSV-style per-UTXO check");
      for (var i = 0; i < utxos.length; i++) {
        final status =
            (utxos[i]['status'] is Map) ? utxos[i]['status'] as Map : const {};
        final blockHeight = status['block_height'] ?? 0;
        final utxoValueRaw = utxos[i]['value'] ?? 0.0;
        final v = double.tryParse(utxoValueRaw.toString()) ?? 0.0;

        final spendable =
            (timelock == 0) || (blockHeight + timelock <= currentHeight);
        // print(
        //     "[WalletService.checkCondition] FALLBACK UTXO[$i] bh=$blockHeight, "
        //     "bh+timelock=${blockHeight + timelock} <= $currentHeight ? $spendable, value=$v");
        if (spendable) {
          totalSpendable += v;
        }
      }
    }

    final decision = totalSpendable >= requiredAmount;
    // print("[WalletService.checkCondition] totalSpendable=$totalSpendable "
    //     "vs required=$requiredAmount → DECISION=$decision");
    // if (!decision) {
    //   print(
    //       "[WalletService.checkCondition] REASON: insufficient spendable for chosen path.");
    // }
    return decision;
  }

  Future<bool> areEqualAddresses(List<TxOut> outputs) async {
    Address? firstAddress;

    for (final output in outputs) {
      final testAddress = Address.fromScript(
        Script(output.scriptPubkey.toBytes()),
        settingsProvider.network,
      );

      if (firstAddress == null) {
        // Store the first address for comparison
        firstAddress = testAddress;
      } else if (testAddress.toString() != firstAddress.toString()) {
        // If an address does not match the first one, set the flag to false
        return false;
      }
    }
    return true;
  }

  Address getAddressFromScriptOutput(TxOut output) {
    // print('Output: ${output.scriptPubkey.asString()}');

    return Address.fromScript(
      Script(output.scriptPubkey.toBytes()),
      settingsProvider.network,
    );
  }

  Address getAddressFromScriptInput(TxIn input) {
    // print(input.previousOutput);

    // print("         script: ${input.scriptSig}");
    // print("         previousOutout Txid: ${input.previousOutput.txid}");
    // print("         previousOutout vout: ${input.previousOutput.vout}");
    // print("         witness: ${input.witness}");
    return Address.fromScript(
      Script(input.scriptSig.toBytes()),
      settingsProvider.network,
    );
  }

  void validateAddress(String address) async {
    try {
      Address(
        address,
        settingsProvider.network,
      );
    } on Exception catch (e) {
      throw Exception('Invalid address format: $e');
    } catch (e) {
      throw Exception('Unknown error while validating address: $e');
    }
  }

  List<Map<String, String>> extractPublicKeysWithAliases(String descriptor) {
    // Regular expression to extract public keys (tpub) and their fingerprints with paths
    final publicKeyRegex = RegExp(r"\[([^\]]+)\]([tvxyz]pub[A-Za-z0-9]+)");

    // Extract matches
    final matches = publicKeyRegex.allMatches(descriptor);

    // Use a Set to ensure uniqueness
    final Set<String> seenKeys = {};
    List<Map<String, String>> result = [];

    for (var match in matches) {
      // Extract alias (fingerprint) and full public key
      final fingerprint = match.group(1)!.split('/')[0]; // Extract fingerprint
      final publicKey =
          "[${match.group(1)!}]${match.group(2)!}"; // Full public key with path

      // Avoid duplicates
      if (!seenKeys.contains(fingerprint)) {
        seenKeys.add(fingerprint);
        result.add({'publicKey': publicKey, 'alias': fingerprint});
      }
    }

    return result;
  }

  Future<double> convertSatoshisToCurrency(
    int satoshis,
    String currency,
  ) async {
    final url = 'https://blockchain.info/ticker';
    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 200) {
      // print(response.body);
      final data = json.decode(response.body);
      final btcToCurrency = data[currency]['buy'];
      final satoshiToCurrency = (btcToCurrency / 100000000) * satoshis;

      return double.parse(satoshiToCurrency.toStringAsFixed(2));
    } else {
      throw Exception('Failed to fetch conversion rate');
    }
  }

  Future<DescriptorPublicKey?> getPubKey(
    Map<String, Future<DescriptorPublicKey?>> pubKeyFutures,
    String? mnemonic,
  ) {
    // Always return a Future, never null
    if (mnemonic == null || mnemonic.isEmpty) {
      return Future.value(null); // Return a Future that completes with null
    }

    if (!pubKeyFutures.containsKey(mnemonic)) {
      pubKeyFutures[mnemonic] = fetchPubKey(mnemonic).catchError((error) {
        // Remove from cache on error to allow retry
        pubKeyFutures.remove(mnemonic);
        throw error; // Re-throw to be caught by FutureBuilder
      });
    }

    return pubKeyFutures[mnemonic]!;
  }

  Future<DescriptorPublicKey?> fetchPubKey(String mnemonic) async {
    final trueMnemonic = Mnemonic.fromString(mnemonic);

    DerivationPath hardenedDerivationPath;

    if (settingsProvider.network == Network.bitcoin) {
      hardenedDerivationPath = DerivationPath("m/84h/0h/0h");
    } else {
      hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
    }
    final receivingDerivationPath = DerivationPath("m/0");

    final (receivingSecretKey, receivingPublicKey) = deriveDescriptorKeys(
      hardenedDerivationPath,
      receivingDerivationPath,
      trueMnemonic,
    );

    return receivingPublicKey;
  }

  Future<Map<String, double>?> fetchRecommendedFees() async {
    final client = EsploraClient(await baseUrl, null);

    try {
      final feeEstimates = client.getFeeEstimates();

      if (feeEstimates.isEmpty) {
        return null;
      }

      // Get all available block targets and sort them
      final blockTargets = feeEstimates.keys.toList()..sort();

      if (blockTargets.isEmpty) {
        return null;
      }

      final lowestTarget = blockTargets.last;
      final highestTarget = blockTargets.first;

      final middleIndex = blockTargets.length ~/ 2;
      final middleTarget = blockTargets[middleIndex];

      final lowestFee = (feeEstimates[lowestTarget]! * 10).ceilToDouble() / 10;
      final middleFee = (feeEstimates[middleTarget]! * 10).ceilToDouble() / 10;
      final highestFee =
          (feeEstimates[highestTarget]! * 10).ceilToDouble() / 10;

      return {
        'fastestFee': highestFee,
        'halfHourFee': middleFee,
        'hourFee': lowestFee,
      };
    } catch (e) {
      print('Errore fetching recommende fess: $e');
      return null;
    } finally {
      client.dispose();
    }
  }

  Future<double> getFeeRate() async {
    final client = EsploraClient(await baseUrl, null);

    try {
      final feeEstimates = client.getFeeEstimates();

      if (feeEstimates.isEmpty) {
        throw Exception('No fee estimates available');
      }

      final blockTargets = feeEstimates.keys.toList()..sort();

      if (blockTargets.isEmpty) {
        throw Exception('No block targets available');
      }

      final middleIndex = blockTargets.length ~/ 2;
      final middleTarget = blockTargets[middleIndex];

      final feeRate = feeEstimates[middleTarget]!;

      return feeRate.ceilToDouble();
    } catch (e) {
      print('Errore fetching fee rate: $e');
      rethrow;
    } finally {
      client.dispose();
    }
  }

  ///
  ///
  ///
  ///
  ///
  ///
  ///
  /// Single Wallet
  ///
  ///
  ///
  ///
  ///
  ///
  ///

  Future<Wallet> createOrRestoreWallet(String mnemonic) async {
    // print('[WALLET] Starting createOrRestoreWallet');
    // print('[WALLET] Network: ${settingsProvider.network}');
    // print('[WALLET] Mnemonic word count: ${mnemonic.split(" ").length}');

    try {
      // print('[WALLET] Generating descriptors...');
      final descriptors = getDescriptors(mnemonic);
      // print('[WALLET] Descriptors generated: ${descriptors.length}');

      // print('[WALLET] Checking connectivity...');
      final List<ConnectivityResult> connectivityResult =
          await Connectivity().checkConnectivity();
      // print('[WALLET] Connectivity result: $connectivityResult');

      // print('[WALLET] Constructing wallet (lookahead=100)...');
      persister = Persister.newInMemory();
      wallet = Wallet(
        descriptors[0],
        descriptors[1],
        settingsProvider.network,
        persister,
        100,
      );
      final persisted = wallet.persist(persister);
      // print('[WALLET] Wallet constructed successfully $persisted');

      // print('[WALLET] Wallet ready');
      return wallet;
    } catch (e, st) {
      print('[WALLET][ERROR] Wallet creation/restoration failed');
      print('[WALLET][ERROR] $e');
      print('[WALLET][STACKTRACE]\n$st');
      throw Exception('Failed to create wallet (Error: $e)');
    }
  }

  List<Descriptor> getDescriptors(String mnemonic) {
    final descriptors = <Descriptor>[];
    try {
      for (var e in [KeychainKind.external_, KeychainKind.internal]) {
        final mnemonicObj = Mnemonic.fromString(mnemonic);

        final descriptorSecretKey = DescriptorSecretKey(
          settingsProvider.network,
          mnemonicObj,
          null,
        );

        final descriptor = Descriptor.newBip84(
          descriptorSecretKey,
          e,
          settingsProvider.network,
        );

        descriptors.add(descriptor);
      }
      return descriptors;
    } on Exception catch (e) {
      // print("Error: ${e.toString()}");
      throw ("Error: ${e.toString()}");
    }
  }

  String generateDonationAddress() {
    String address = "";

    final publicKey = settingsProvider.network == Network.bitcoin
        ? DescriptorPublicKey.fromString(
            "[98a2af72/84'/0'/0']xpub6DMymVxGHgvA6yMn9CcMFXAJfWremKeogbF2uoxCiCazHa5XT3vTPeZirsPsgoxTRZxES1nAVZ9fjJUMB2N4afU3WWAwc4Qe6Ry5c5UbTLc/0/*")
        : DescriptorPublicKey.fromString(
            "[f31c4a3b/84'/1'/0']tpubDDeWSeMbdTfhgWkR5WfXNXtgfrWDNh7CtEojp7rp7Jq3Rxc641XE9gaZEyfzmnCadaLu5VXdxRiFucSF4j25GeaASmw6ZbXgecqokn5jPPN/0/*");

    final fingerPrint =
        settingsProvider.network == Network.bitcoin ? "98a2af72" : "f31c4a3b";

    final descriptor = Descriptor.newBip84Public(publicKey, fingerPrint,
        KeychainKind.external_, settingsProvider.network);
    final changeDescriptor = Descriptor.newBip84Public(publicKey, fingerPrint,
        KeychainKind.internal, settingsProvider.network);

    persister = Persister.newInMemory();

    final donationWallet = Wallet(
      descriptor,
      changeDescriptor,
      settingsProvider.network,
      persister,
      100,
    );

    final persisted = donationWallet.persist(persister);

    address = donationWallet
        .nextUnusedAddress(KeychainKind.external_)
        .address
        .toString();

    return address;
  }

  // Method to create, sign and broadcast a single user transaction
  Future<void> sendSingleTx(
    String recipientAddressStr,
    Amount amount,
    Wallet wallet,
    String changeAddressStr,
    double? customFeeRate,
  ) async {
    await syncWallet(wallet);

    // final utxos = wallet.getBalance();
    // print("Available UTXOs: ${utxos.total.toInt()}");
    // print(wallet.getAddress(addressIndex: AddressIndex.peek(index: 0)));

    try {
      // Build the transaction
      final txBuilder = TxBuilder();

      final recipientAddress = Address(
        recipientAddressStr,
        wallet.network(),
      );
      final recipientScript = recipientAddress.scriptPubkey();

      final changeAddress = Address(
        changeAddressStr,
        wallet.network(),
      );
      final changeScript = changeAddress.scriptPubkey();

      final feeRate = customFeeRate ?? await getFeeRate();

      // Build the transaction:
      // - Send `amount` to the recipient
      // - Any remaining funds (change) will be sent to the change address
      final txBuilderResult = txBuilder
          // .enableRbf()
          .addRecipient(recipientScript, amount) // Send to recipient
          .drainWallet() // Drain all wallet UTXOs, sending change to a custom address
          .feeRate(FeeRate.fromSatPerVb(
              feeRate.toInt())) // Set the fee rate (in satoshis per byte)
          .drainTo(
            changeScript,
          ) // Specify the custom address to send the change
          .finish(wallet); // Finalize the transaction with wallet's UTXOs

      // Sign the transaction
      final isFinalized = wallet.sign(
        txBuilderResult,
        SignOptions(
          true,
          null,
          false,
          true,
          false,
          false,
        ),
      );

      // Broadcast the transaction only if it is finalized
      if (isFinalized) {
        // Broadcast the transaction to the network only if it is finalized

        ElectrumClient? client;
        final tx = txBuilderResult.extractTx();

        for (final server in electrumServers) {
          try {
            // Pick the right server for the network you're on
            client = ElectrumClient(server, null);

            final txid = client.transactionBroadcast(tx);

            // print("Broadcasted! txid: $txid");
          } catch (e) {
            print("Broadcast failed: $e");
            rethrow;
          } finally {
            client?.dispose();
          }
        }
      }
    } on Exception catch (e) {
      print("Error: ${e.toString()}");
      throw Exception('Failed to send Transaction (Error: ${e.toString()})');
    }
  }

  ///
  ///
  ///
  ///
  ///
  ///
  ///
  /// Shared Wallet
  ///
  ///
  ///
  ///
  ///
  ///
  ///

  String stripChecksum(String d) => d.split('#').first;

  String makeChangeDescriptor(String receiveDescriptor) {
    final d = stripChecksum(receiveDescriptor);

    // Shift chains to avoid overlap:
    // 0->10, 1->11, 2->12
    // Use a careful replacement order so we don't double-replace.
    return d
        .replaceAll('/2/*', '/__TMP2__/*')
        .replaceAll('/1/*', '/__TMP1__/*')
        .replaceAll('/0/*', '/__TMP0__/*')
        .replaceAll('/__TMP0__/*', '/10/*')
        .replaceAll('/__TMP1__/*', '/11/*')
        .replaceAll('/__TMP2__/*', '/12/*');
  }

  Future<Wallet> createSharedWallet(String descriptor) async {
    // print('========== CREATE SHARED WALLET ==========');
    // print('Network: ${settingsProvider.network}');
    // print('Original descriptor:');
    // printInChunks(descriptor);

    // print('\n--- Creating receive descriptor ---');
    final receiveDesc = Descriptor(descriptor, settingsProvider.network);
    // print('Receive descriptor created:');
    // printInChunks(receiveDesc.toString());

    // print('\n--- Creating change descriptor ---');
    final changeDescStr = makeChangeDescriptor(descriptor);
    // print('Change descriptor string:');
    // printInChunks(changeDescStr);

    final changeDesc = Descriptor(changeDescStr, settingsProvider.network);
    // print('Change descriptor created:');
    // printInChunks(changeDesc.toString());
    // printInChunks(changeDesc.toStringWithSecret());

    // print('\n--- Initializing persister ---');
    persister = Persister.newInMemory();
    // print('Persister created: in-memory');

    // print('\n--- Creating wallet ---');
    // print('Sync params: lookahead = 100');

    // bdk-dart
    wallet = Wallet(
      receiveDesc,
      changeDesc,
      settingsProvider.network,
      persister,
      100,
    );

    // print('✓ Wallet created successfully');
    // print('==========================================\n');

    return wallet;
  }

  Future<void> saveLocalData({
    required Wallet wallet,
    required String address,
    required int currentHeight,
    required String timestamp,
    required int availableBalance,
    required int ledgerBalance,
    required List<Map<String, dynamic>> transactions,
    List<dynamic>? utxos,
    required DateTime lastRefreshed,
    required Set<String> myAddresses,
  }) async {
    final methodStart = DateTime.now();
    // print("💾 [saveLocalData] START (pure save)");

    final walletId =
        wallet.peekAddress(KeychainKind.external_, 0).address.toString();

    final totalWalletBalance = int.parse(getBalance(wallet).toString());

    final walletData = WalletData(
      address: address,
      balance: totalWalletBalance,
      ledgerBalance: ledgerBalance,
      availableBalance: availableBalance,
      transactions: transactions,
      currentHeight: currentHeight,
      timeStamp: timestamp,
      utxos: utxos,
      lastRefreshed: lastRefreshed,
      myAddresses: myAddresses,
    );

    await _walletStorageService.saveWalletData(walletId, walletData);

    final totalMs = DateTime.now().difference(methodStart).inMilliseconds;
    // print("✅ [saveLocalData] DONE in ${totalMs}ms");
    // print("=======================================");
  }

  String replacePubKeyWithPrivKeyMultiSig(
    String descriptor,
    String pubKey,
    String privKey,
  ) {
    // Extract the derivation path and pubkey portion for dynamic matching
    final regexPathPub = RegExp(
      RegExp.escape('${pubKey.split(']')[0]}]') +
          r'[tvxyz]pub[A-Za-z0-9]+\/\d+\/\*',
    ); // tpub for testnet and xpub for mainnet

    // Replace only the matching public key with the private key
    return descriptor.replaceFirstMapped(regexPathPub, (match) {
      return privKey;
    });
  }

  String replacePubKeyWithPrivKeyOlder(
    int? chosenPath, // The specific index to target
    String descriptor,
    String pubKey,
    String privKey,
  ) {
    // print('------------Replacing------------');
    // printInChunks('Descriptor Before Replacement:\n$descriptor');
    // print('Chosen Path Index: $chosenPath');
    // print('Public Key: $pubKey');
    // print('Private Key: ${privKey.substring(0, privKey.length - 4)}');

    // Extract the derivation path prefix and ensure we match tpub/xpub keys with trailing paths
    final regexPathPub = RegExp(
      RegExp.escape('${pubKey.split(']')[0]}]') +
          r'[tvxyz]pub[A-Za-z0-9]+\/(\d+)\/\*',
    ); // Matches tpub for testnet and xpub for mainnet

    int currentIndex = 0; // Tracks the current match index

    // Replace only the match at the specified `chosenPath` index
    final result = descriptor.replaceAllMapped(regexPathPub, (match) {
      final trailingPath = match.group(
        1,
      ); // Extract the trailing path (e.g., "0", "1", "2")

      // Debugging info for each match
      // print('Match Found: ${match.group(0)}');
      // print('Trailing Path Extracted: $trailingPath');
      // print('Current Match Index: $currentIndex');

      if (currentIndex == chosenPath) {
        // print(
        //     'Replacing with Private Key: ${privKey.substring(0, privKey.length - 4)}/$trailingPath/*');
        currentIndex++; // Increment the index for the next match
        return '${privKey.substring(0, privKey.length - 4)}/$trailingPath/*';
      } else {
        // print('Keeping Original Public Key: ${match.group(0)}');
        currentIndex++; // Increment the index for the next match
        return match.group(
          0,
        )!; // Keep the original matched string for other paths
      }
    });

    // printInChunks('Descriptor After Replacement:\n$result');
    // print('------------Replacement Complete------------');

    return result;
  }

  (DescriptorSecretKey, DescriptorPublicKey) deriveDescriptorKeys(
    DerivationPath hardenedPath,
    DerivationPath unHardenedPath,
    Mnemonic mnemonic,
  ) {
    // print("🔐 Starting key derivation process...");
    // print("🧠 Mnemonic: $mnemonic");
    // print("📌 Network: ${settingsProvider.network}");
    // print("📍 Hardened path: $hardenedPath");
    // print("📍 Unhardened path: $unHardenedPath");

    // Create the root secret key from the mnemonic
    final secretKey = DescriptorSecretKey(
      settingsProvider.network,
      mnemonic,
      null,
    );
    // print("✅ Root secret key created: ${secretKey.asString()}");

    // Derive the key at the hardened path
    final derivedSecretKey = secretKey.derive(hardenedPath);
    // print("📍 Derived hardened secret key: ${derivedSecretKey.asString()}");

    // Extend the derived secret key further using the unhardened path
    final derivedExtendedSecretKey = derivedSecretKey.extend(unHardenedPath);
    // print("🔁 Extended secret key: ${derivedExtendedSecretKey.asString()}");

    // Convert the derived secret key to its public counterpart
    final publicKey = derivedSecretKey.asPublic();
    // print("🔓 Public key from hardened key: ${publicKey.asString()}");

    // Extend the public key using the same unhardened path
    final derivedExtendedPublicKey = publicKey.extend(unHardenedPath);
    // print("🔁 Extended public key: ${derivedExtendedPublicKey.asString()}");

    // print("✅ Key derivation complete");

    return (derivedExtendedSecretKey, derivedExtendedPublicKey);
  }

  // Function to traverse and extract both the id and the path to the fingerprint
  List<Map<String, dynamic>> extractAllPathsToFingerprint(
    Map<String, dynamic> policy,
    String targetFingerprint,
  ) {
    List<Map<String, dynamic>> result = [];

    void traverse(dynamic node, List<int> currentPath, List<String> idPath) {
      if (node == null) return;

      // // Debugging: Print the current node and paths being processed
      // print('Traversing Node: ${node['id'] ?? 'No ID'}');
      // print('Current Path: $currentPath');
      // print('ID Path: $idPath');

      // Check if the node itself has a matching fingerprint
      if (node['fingerprint'] == targetFingerprint) {
        // print('Match Found in Node: ${node['id']}');
        result.add({
          'ids': [...idPath, node['id']],
          'indexes': currentPath,
        });
      }

      // Check if the node contains `keys` with matching fingerprints
      if (node['keys'] != null) {
        for (var key in node['keys']) {
          // print('Checking Key Fingerprint: ${key['fingerprint']}');
          if (key['fingerprint'] == targetFingerprint) {
            // print('Match Found in Keys: Adding Path');
            result.add({
              'ids': [...idPath, node['id']],
              'indexes': currentPath,
            });
          }
        }
      }

      // Recursively traverse children if the node has `items`
      if (node['items'] != null) {
        for (int i = 0; i < node['items'].length; i++) {
          // print('Traversing Child at Index: $i');
          traverse(
            node['items'][i],
            [...currentPath, i],
            [...idPath, node['id']],
          );
        }
      }
    }

    // Start traversing from the root policy
    traverse(policy, [], []);

    // print('Final Result: $result');
    return result;
  }

  List<Map<String, dynamic>> extractDataByFingerprint(
    Map<String, dynamic> json,
    String fingerprint,
  ) {
    List<Map<String, dynamic>> result = [];

    // print("Fingerprint: $fingerprint");

    void traverse(
      Map<String, dynamic> node,
      List<String> path,
      List<dynamic>? parentItems,
    ) {
      // print("\n🔍 Traversing node: ${node['id'] ?? 'Unknown ID'}");
      // print("📍 Current path: ${path.join(' > ')}");
      // print(
      //     "📦 Node type: ${node['type']}, Keys: ${node['keys']?.length ?? 0}, Items: ${node['items']?.length ?? 0}");

      // === Check for keys ===
      if (node['keys'] != null) {
        // print("🔑 Node has keys. Checking for fingerprint matches...");
        List<dynamic> keys = node['keys'];
        final matchingKeys =
            keys.where((key) => key['fingerprint'] == fingerprint).toList();

        if (matchingKeys.isNotEmpty) {
          // print("✅ Fingerprint match found in keys!");

          String type = node['type'];
          int? timelockValue;

          if (node['threshold'] != null) {
            type = "THRESH > $type";
            // print("🔢 Threshold detected. Adjusted type: $type");
          }

          // === Check sibling constraints ===
          if (parentItems != null) {
            for (var sibling in parentItems) {
              if (sibling['type'] == 'RELATIVETIMELOCK') {
                type = "RELATIVETIMELOCK > $type";

                timelockValue = sibling['value']['Blocks'];

                // print(
                //     "⏱️ RELATIVETIMELOCK detected. Updated type: $type | Timelock: $timelockValue");
              } else if (sibling['type'] == 'ABSOLUTETIMELOCK') {
                type = "ABSOLUTETIMELOCK > $type";
                timelockValue = sibling['value'];

                // print(
                // "🕰️ ABSOLUTETIMELOCK detected. Updated type: $type | Timelock: $timelockValue");
              }
            }
          }

          final entry = {
            'type': type,
            'threshold': node['threshold'],
            'fingerprints': keys.map((key) => key['fingerprint']).toList(),
            'path': path.join(' > '),
            'timelock': timelockValue,
          };

          result.add(entry);
          // print("📥 Added to result: $entry");
        }
        // else {
        //   print("❌ No fingerprint match in keys.");
        // }
      }

      // === Check for direct fingerprint match in ECDSASIGNATURE ===
      if (node['type'] == 'ECDSASIGNATURE' &&
          node['fingerprint'] == fingerprint) {
        // print("🖊️ Direct fingerprint match in ECDSASIGNATURE node.");

        String type = node['type'];
        int? timelockValue;

        if (parentItems != null) {
          for (var sibling in parentItems) {
            if (sibling['type'] == 'RELATIVETIMELOCK') {
              type = "RELATIVETIMELOCK > $type";

              timelockValue = sibling['value']['Blocks'];

              // print(
              //     "⏱️ RELATIVETIMELOCK affects ECDSASIGNATURE. Timelock: $timelockValue");
            } else if (sibling['type'] == 'ABSOLUTETIMELOCK') {
              type = "ABSOLUTETIMELOCK > $type";
              timelockValue = sibling['value'];

              // print(
              //     "🕰️ ABSOLUTETIMELOCK affects ECDSASIGNATURE. Timelock: $timelockValue");
            }
          }
        }

        final entry = {
          'type': type,
          'threshold': null,
          'fingerprints': [fingerprint],
          'path': path.join(' > '),
          'timelock': timelockValue,
        };

        result.add(entry);
        // print("📥 Added ECDSASIGNATURE to result: $entry");
      }

      // === Traverse child nodes ===
      if (node['items'] != null) {
        // print("🔁 Traversing ${node['items'].length} child items...");
        List<dynamic> items = node['items'];
        for (int i = 0; i < items.length; i++) {
          traverse(
            items[i],
            [...path, '${node['type']}[$i]'],
            items,
          );
        }
      }
      // else {
      //   print("🚫 No child items.");
      // }
    }

    // print("🚀 Starting fingerprint extraction for: $fingerprint\n");
    traverse(json, [], null);
    // print("\n✅ Traversal complete. Total matches: ${result.length}");
    return result;
  }

  List<Map<String, dynamic>> extractAllPaths(Map<String, dynamic> json) {
    // print('--- extractAllPaths START ---');

    List<Map<String, dynamic>> result = [];

    void traverse(
      Map<String, dynamic> node,
      List<String> path,
      List<dynamic>? parentItems,
    ) {
      // print(
      //     '[TRAVERSE] Node type: ${node['type']} | Path: ${path.join(' > ')}');

      // Check if this node has keys
      if (node['keys'] != null) {
        // print('[KEYS] Found keys in node type: ${node['type']}');

        List<dynamic> keys = node['keys'];
        List<String> fingerprints =
            keys.map((key) => key['fingerprint'] as String).toList();

        // print('[KEYS] Fingerprints: $fingerprints');

        // Determine the type and additional constraints
        String type = node['type'];
        int? timelockValue;

        if (node['threshold'] != null) {
          type = "THRESH > $type";
          // print('[INFO] Threshold detected: ${node['threshold']}');
        }

        // Look for sibling constraints (e.g., RELATIVETIMELOCK)
        if (parentItems != null) {
          for (var sibling in parentItems) {
            if (sibling['type'] == 'RELATIVETIMELOCK') {
              // print('[DEBUG] sibling type: ${sibling['type']}');
              // print(
              //     '[DEBUG] sibling value runtimeType: ${sibling['value']?.runtimeType}');
              // print('[DEBUG] sibling value: ${sibling['value']}');

              type = "RELATIVETIMELOCK > $type";
              timelockValue = sibling['value']['Blocks'];

              // print('[INFO] Relative timelock detected: $timelockValue');
            } else if (sibling['type'] == 'ABSOLUTETIMELOCK') {
              type = "ABSOLUTETIMELOCK > $type";

              timelockValue = sibling['value'];

              // print('[INFO] Absolute timelock detected: $timelockValue');
            }
          }
        }

        result.add({
          'type': type,
          'threshold': node['threshold'],
          'fingerprints': fingerprints,
          'path': path.join(' > '),
          'timelock': timelockValue,
        });

        // print('[ADD] Result entry added: ${result.last}');
      }

      // Check if this node has a direct fingerprint reference (e.g., ECDSASIGNATURE)
      if (node['type'] == 'ECDSASIGNATURE') {
        // print('[ECDSA] Found ECDSASIGNATURE node');

        String type = "ECDSASIGNATURE";
        int? timelockValue;

        // Look for sibling constraints (e.g., RELATIVETIMELOCK)
        if (parentItems != null) {
          for (var sibling in parentItems) {
            if (sibling['type'] == 'RELATIVETIMELOCK') {
              type = "RELATIVETIMELOCK > $type";

              timelockValue = sibling['value']['Blocks'];

              // print('[INFO] Relative timelock detected: $timelockValue');
            } else if (sibling['type'] == 'ABSOLUTETIMELOCK') {
              type = "ABSOLUTETIMELOCK > $type";

              timelockValue = sibling['value'];

              // print('[INFO] Absolute timelock detected: $timelockValue');
            }
          }
        }

        result.add({
          'type': type,
          'threshold': null,
          'fingerprints': [node['fingerprint']],
          'path': path.join(' > '),
          'timelock': timelockValue,
        });

        // print('[ADD] ECDSASIGNATURE entry added: ${result.last}');
      }

      // Recursively traverse child nodes in "items"
      if (node['items'] != null) {
        List<dynamic> items = node['items'];
        // print('[CHILDREN] ${items.length} children found');

        for (int i = 0; i < items.length; i++) {
          // print('[DESCEND] -> ${node['type']}[$i]');
          traverse(
            {
              ...items[i],
              'parentItems': items,
            },
            [...path, '${node['type']}[$i]'],
            items,
          );
        }
      }
      // else {
      //   print('[LEAF] No child items for node type: ${node['type']}');
      // }
    }

    // print('[START] Traversing JSON tree');
    traverse(json, [], null);

    // print('--- extractAllPaths END ---');
    // print('[RESULT COUNT] ${result.length}');
    // print('[RESULT DATA]');
    // print(result);

    return result;
  }

  List<String> extractSignersFromPsbt(Psbt psbt) {
    final serializedPsbt = psbt.jsonSerialize();

    // printPrettyJson(serializedPsbt);
    // printInChunks(psbt.asString());

    // Parse JSON
    Map<String, dynamic> psbtDecoded = jsonDecode(serializedPsbt);

    // Map to store public key -> fingerprint
    Map<String, String> pubKeyToFingerprint = {};

    // Extract fingerprints from bip32_derivation
    if (psbtDecoded.containsKey('inputs')) {
      for (var input in psbtDecoded['inputs']) {
        if (input.containsKey('bip32_derivation')) {
          List<dynamic> bip32Derivations = input['bip32_derivation'];

          for (var derivation in bip32Derivations) {
            if (derivation.length >= 2) {
              String pubKey = derivation[0]; // Public Key
              String fingerprint =
                  derivation[1][0]; // First 4 bytes (fingerprint)

              // Store mapping
              pubKeyToFingerprint[pubKey] = fingerprint;
            }
          }
        }
      }
    }

    // List to store fingerprints of signing keys
    List<String> signingFingerprints = [];

    // Extract public keys from partial_sigs
    if (psbtDecoded.containsKey('inputs')) {
      for (var input in psbtDecoded['inputs']) {
        if (input.containsKey('partial_sigs')) {
          Map<String, dynamic> partialSigs = input['partial_sigs'];

          partialSigs.forEach((pubKey, sigData) {
            if (pubKeyToFingerprint.containsKey(pubKey)) {
              // Store fingerprint if the pubKey has signed
              signingFingerprints.add(pubKeyToFingerprint[pubKey]!);
            }
          });
        }
      }
    }

    // print("Fingerprints of signing public keys: $signingFingerprints");

    return signingFingerprints.toSet().toList();
  }

  Map<String, dynamic> extractSpendingPathFromPsbt(
    Psbt psbt,
    List<Map<String, dynamic>> spendingPaths,
  ) {
    final serializedPsbt = psbt.jsonSerialize();
    // print("Serialized PSBT: $serializedPsbt");

    // Parse JSON
    final Map<String, dynamic> psbtDecoded = jsonDecode(serializedPsbt);
    // printInChunks("Decoded PSBT: $psbtDecoded");

    if (!psbtDecoded.containsKey("unsigned_tx") ||
        !psbtDecoded["unsigned_tx"].containsKey("input")) {
      throw Exception("Invalid PSBT format or missing inputs.");
    }

    final inputs = (psbtDecoded["unsigned_tx"]["input"] as List).cast<Map>();
    // print("Inputs: $inputs");

    final sequenceValues = inputs.map((i) => i["sequence"] as int).toSet();
    // print("Sequence values: $sequenceValues");

    if (sequenceValues.length != 1) {
      throw Exception("Mismatched sequence values in inputs.");
    }

    final sequence = sequenceValues.first;
    // print("Final sequence: $sequence");

    // --- NEW: Inspect partial_sigs and map to derivation paths (for debug) ---
    final inputObjs = (psbtDecoded["inputs"] as List?) ?? const [];
    for (var idx = 0; idx < inputObjs.length; idx++) {
      final inp = inputObjs[idx] as Map;
      final derivs = (inp["bip32_derivation"] as List?) ?? const [];
      final derivMap = <String, String>{}; // pubkey -> path
      for (final d in derivs) {
        // d is like ["<pubkey>", ["<fingerprint>", "m/84'/1'/0'/0/0"]]
        try {
          final pub = d[0] as String;
          final path = (d[1] as List)[1] as String;
          derivMap[pub] = path;
        } catch (_) {}
      }

      // final sigs =
      //     (inp["partial_sigs"] as Map?)?.cast<String, dynamic>() ?? const {};
      // if (sigs.isNotEmpty) {
      //   // print("Input[$idx] partial_sigs count: ${sigs.length}");
      //   sigs.forEach((pubkey, sigInfo) {
      //     final path = derivMap[pubkey];
      //     final fp = path == null
      //         ? null
      //         : (derivs.firstWhere(
      //             (d) => d[0] == pubkey,
      //             orElse: () => null,
      //           ) as List?)?[1]?[0];
      //     // print("  ↳ signer pubkey: $pubkey");
      //     if (path != null) {
      //       // Try to infer the BIP84 'change' (…/change/index)
      //       String branchHint = "";
      //       try {
      //         final segs = path.split('/');
      //         // m / 84' / coin' / acct' / change / index
      //         if (segs.length >= 6) {
      //           final change = segs[4].replaceAll("'", "");
      //           final index = segs[5].replaceAll("'", "");
      //           branchHint = " (change=$change, index=$index)";
      //         }
      //       } catch (_) {}
      //       print(
      //           "     derivation: $path$branchHint${fp != null ? " (fp $fp)" : ""}");
      //     } else {
      //       print("     derivation: <not found in bip32_derivation>");
      //     }
      //     final sigHex = (sigInfo is Map && sigInfo["sig"] != null)
      //         ? sigInfo["sig"]
      //         : "<no sig>";
      //     final hashTy = (sigInfo is Map && sigInfo["hash_ty"] != null)
      //         ? sigInfo["hash_ty"]
      //         : "<none>";
      //     print("     sig hash_ty: $hashTy");
      //     print(
      //         "     sig (truncated): ${sigHex.toString().substring(0, sigHex.toString().length.clamp(0, 32))}...");
      //   });
      // }
    }

    // --- Your original logic (unchanged) ---
    if (sequence == 4294967294) {
      // print(
      //     "Sequence is 0xFFFFFFFE → could be MULTISIG or AFTER. Disambiguating via signer derivation index...");

      // 1) Collect signer derivation 'change' values from partial_sigs ↔ bip32_derivation
      final inputObjs = (psbtDecoded["inputs"] as List?) ?? const [];
      final signerChanges = <int>{};

      for (var inIdx = 0; inIdx < inputObjs.length; inIdx++) {
        final inp = inputObjs[inIdx] as Map;
        final derivs = (inp["bip32_derivation"] as List?) ?? const [];
        final derivMap =
            <String, String>{}; // pubkey -> "m/.../<change>/<index>"
        for (final d in derivs) {
          try {
            final pub = d[0] as String;
            final path = (d[1] as List)[1] as String;
            derivMap[pub] = path;
          } catch (_) {}
        }

        final sigs =
            (inp["partial_sigs"] as Map?)?.cast<String, dynamic>() ?? const {};
        sigs.forEach((pubkey, _) {
          final path = derivMap[pubkey];
          if (path != null) {
            try {
              final segs = path.split('/');
              // BIP84: m / 84' / coin' / acct' / change / index
              if (segs.length >= 6) {
                final changeStr = segs[4].replaceAll("'", "");
                final change = int.parse(changeStr);
                signerChanges.add(change);
              }
            } catch (_) {}
          }
        });
      }

      // print("Derivation-based change(s) from partial_sigs: $signerChanges");

      // 2) If exactly one change value, try to use it as spendingPaths index
      if (signerChanges.length == 1) {
        final changeVal = signerChanges.first;
        if (changeVal >= 0 && changeVal < spendingPaths.length) {
          // print(signerChanges);
          // print(spendingPaths);
          final candidate = spendingPaths[changeVal];
          // print("Index-based match → spendingPaths[$changeVal]: "
          //     "type=${candidate["type"]}, timelock=${candidate["timelock"]}");
          return candidate;
        }
        //  else {
        //   print(
        //       "No spendingPaths[$changeVal] exists (len=${spendingPaths.length}). Falling back to MULTISIG heuristic.");
        // }
      }
      //  else if (signerChanges.isEmpty) {
      //   print(
      //       "No signer derivation change inferred; falling back to MULTISIG heuristic.");
      // } else {
      //   print(
      //       "Multiple signer changes observed ($signerChanges); falling back to MULTISIG heuristic.");
      // }

      // 3) Fallback: original MULTISIG heuristic
      // print("Fallback → MULTISIG heuristic");
      return spendingPaths.firstWhere(
        (path) {
          // print("Checking path for MULTISIG: $path");
          return path["type"].toString().toUpperCase().contains("MULTISIG");
        },
        orElse: () =>
            throw Exception("No matching multisig spending path found."),
      );
    } else {
      // print("Detected TIMELOCK case");
      return spendingPaths.firstWhere(
        (path) {
          // print("Checking path for timelock: $path");
          return path["timelock"] != null && path["timelock"] == sequence;
        },
        orElse: () {
          throw Exception("No matching timelock spending path found.");
        },
      );
    }
  }

  List<String> getAliasesFromFingerprint(
    List<Map<String, String>> pubKeysAlias,
    List<String> signers,
  ) {
    // Initialize an empty map for public key aliases
    Map<String, String> pubKeysAliasMap = {};

    // Print the original pubKeysAlias list
    // print("widget.pubKeysAlias (List of Maps): $pubKeysAlias");

    // Flatten the list of maps into a single map
    for (var map in pubKeysAlias) {
      // print("Processing map: $map");

      if (map.containsKey("publicKey") && map.containsKey("alias")) {
        String publicKeyRaw =
            map["publicKey"].toString(); // e.g. "[42e5d2a0/84'/1'/0']tpubDC..."
        String alias = map["alias"].toString();

        // Extract fingerprint (inside brackets)
        RegExp regex = RegExp(r"\[(.*?)\]");
        Match? match = regex.firstMatch(publicKeyRaw);

        if (match != null) {
          String fingerprint =
              match.group(1)!.split("/")[0]; // Extract first part (fingerprint)
          // print("Extracted Fingerprint: $fingerprint -> Alias: $alias");

          pubKeysAliasMap[fingerprint] = alias; // Store the mapping
        }
      }
    }

    // Print the final fingerprint-to-alias mapping
    // print("Final pubKeysAliasMap (Flattened): $pubKeysAliasMap");

    // Initialize list for signer aliases
    List<String> signersAliases = [];

    // Match fingerprints to aliases
    for (String fingerprint in signers) {
      // print("Checking fingerprint: $fingerprint");

      if (pubKeysAliasMap.containsKey(fingerprint)) {
        String alias = pubKeysAliasMap[fingerprint]!;
        // print("Match found! Fingerprint: $fingerprint -> Alias: $alias");
        signersAliases.add(alias);
      } else {
        // print("No match found for fingerprint: $fingerprint");
        signersAliases.add("Unknown ($fingerprint)");
      }
    }

    // Print final mapping of signers to aliases
    // print("Final Signers with Aliases: $signersAliases");

    return signersAliases;
  }

  bool _isImmediateMultisig(Map<String, dynamic>? p) {
    // print("🔎 Checking path: $p");

    if (p == null) {
      // print("❌ Path is null → returning false");
      return false;
    }

    final type = (p['type'] as String?) ?? '';
    final hasTimelock = p['timelock'] != null;
    final threshold = p['threshold'] is int ? p['threshold'] as int : null;

    final looksMulti =
        type.contains('MULTISIG') || (threshold != null && threshold > 1);

    // print("➡️ type=$type");
    // print("➡️ hasTimelock=$hasTimelock");
    // print("➡️ threshold=$threshold");
    // print("➡️ looksMulti=$looksMulti");

    final result = looksMulti && !hasTimelock;
    // print("✅ Result (isImmediateMultisig) = $result");

    return result;
  }

  Map<String, dynamic>? _pathAt(List paths, int i) {
    if (i < 0 || i >= paths.length) return null;
    final v = paths[i];
    return (v is Map<String, dynamic>) ? v : null;
  }

  Future<String?> createPartialTx(
    String descriptor,
    String mnemonic,
    String recipientAddressStr,
    int amount,
    int? chosenPath,
    int avBalance, {
    bool isSendAllBalance = false,
    List<Map<String, dynamic>>? spendingPaths,
    double? customFeeRate,
    List<dynamic>? localUtxos,
  }) async {
    // print("🏁 ===== ENTERING createPartialTx =====");
    // print("📥 INPUT PARAMETERS:");
    // printInChunks("   - descriptor: $descriptor");
    // print("   - mnemonic: [PROVIDED] (length: ${mnemonic.length})");
    // print("   - recipientAddressStr: $recipientAddressStr");
    // print("   - amount: $amount sats");
    // print("   - chosenPath: $chosenPath");
    // print("   - avBalance: $avBalance sats");
    // print("   - isSendAllBalance: $isSendAllBalance");
    // print("   - customFeeRate: $customFeeRate");
    // print("   - spendingPaths exists: ${spendingPaths != null}");
    // print(
    //     "   - localUtxos exists: ${localUtxos != null} (length: ${localUtxos?.length ?? 0})");
    // print("=====================================");

    Map<String, Uint32List>? multiSigPath;
    Map<String, Uint32List>? timeLockPath;

    // print("🔑 Creating Mnemonic from string...");
    Mnemonic trueMnemonic = Mnemonic.fromString(mnemonic);
    // print("   ✓ Mnemonic created successfully");

    DerivationPath hardenedDerivationPath;

    if (settingsProvider.network == Network.bitcoin) {
      if (oldCase) {
        hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
      } else {
        hardenedDerivationPath = DerivationPath("m/84h/0h/0h");
      }
    } else {
      hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
    } // print("   Hardened derivation path: m/84h/1h/0h");

    final receivingDerivationPath = DerivationPath("m/0");
    // print("   Receiving derivation path: m/0");

    // print("🔐 Deriving descriptor keys...");
    final (receivingSecretKey, receivingPublicKey) = deriveDescriptorKeys(
      hardenedDerivationPath,
      receivingDerivationPath,
      trueMnemonic,
    );
    // print("   ✓ Keys derived");
    // print("   - Receiving Public Key: $receivingPublicKey");

    // Extract the content inside square brackets
    // print("🔍 Extracting fingerprint from public key...");
    final RegExp regex = RegExp(r'\[([^\]]+)\]');
    final Match? match = regex.firstMatch(receivingPublicKey.toString());
    // if (match == null) {
    //   print("❌ ERROR: Could not extract fingerprint - regex match failed");
    // } else {
    //   final String targetFingerprint = match.group(1)!.split('/')[0];
    //   print("   ✓ Fingerprint extracted: $targetFingerprint");
    // }
    final String targetFingerprint = match!.group(1)!.split('/')[0];

    // print("🔍 Getting correct path from spendingPaths at index: $chosenPath");
    final correctPath = _pathAt(spendingPaths!, chosenPath!);
    // print("   ✓ Correct path: $correctPath");
    // print("   - Is immediate multisig? ${_isImmediateMultisig(correctPath)}");

    // print("✏️ Replacing descriptor with private keys...");
    descriptor = _isImmediateMultisig(correctPath)
        ? replacePubKeyWithPrivKeyMultiSig(
            descriptor,
            receivingPublicKey.toString(),
            receivingSecretKey.toString(),
          )
        : replacePubKeyWithPrivKeyOlder(
            chosenPath,
            descriptor,
            receivingPublicKey.toString(),
            receivingSecretKey.toString(),
          );
    // print("   ✓ Descriptor updated");
    // printInChunks("   - New descriptor: $descriptor...");

    // print("💼 Creating shared wallet with descriptor...");
    wallet = await createSharedWallet(descriptor);
    // print("   ✓ Wallet created: $wallet");

    // print("📶 Checking connectivity...");
    final List<ConnectivityResult> connectivityResult =
        await (Connectivity().checkConnectivity());
    // print("   - Connectivity result: $connectivityResult");

    final Balance utxos;
    int totalSpending;

    if (connectivityResult.contains(ConnectivityResult.none)) {
      // print("⚠️ OFFLINE MODE: No internet connection");
      if (!isSendAllBalance) {
        totalSpending = amount;
        // print("   - Total spending (offline): $totalSpending sats");
        // print("   - Available balance: $avBalance sats");

        if (avBalance < totalSpending) {
          // print("❌ ERROR: Insufficient confirmed funds available");
          throw Exception(
            "Not enough confirmed funds available. Please wait until your transactions confirm.",
          );
        }
        // print("   ✓ Sufficient funds available (offline check)");
      }
    } else {
      // print("🌐 ONLINE MODE: Syncing wallet...");
      await syncWallet(wallet);
      // print("   ✓ Wallet synced");

      utxos = wallet.balance();
      // print("   - Wallet balance - Confirmed: ${utxos.confirmed.toSat()} sats");
      // print(
      //     "   - Wallet balance - Trusted spendable: ${utxos.trustedSpendable.toSat()} sats");
      // print("   - Wallet balance - Immature: ${utxos.immature.toSat()} sats");
      // print(
      //     "   - Wallet balance - Untrusted: ${utxos.untrustedPending.toSat()} sats");

      if (!isSendAllBalance) {
        totalSpending = amount;
        // print("   - Total spending: $totalSpending sats");
        // print(
        //     "   - Confirmed UTXOs available: ${utxos.trustedSpendable.toSat()} sats");

        if (utxos.trustedSpendable.toSat() < totalSpending) {
          // print("❌ ERROR: Insufficient confirmed funds available");
          throw Exception(
            "Not enough confirmed funds available. Please wait until your transactions confirm.",
          );
        }
        // print("   ✓ Sufficient funds available");
      }
    }

    // print("💰 Getting fee rate...");
    final feeRate = customFeeRate ?? await getFeeRate();
    // print("   - Fee rate: $feeRate sat/vB");

    List<OutPoint> spendableOutpoints = [];
    // print("   - Initialized spendableOutpoints list");

    try {
      // print("🏗️ Building transaction...");
      var txBuilder = TxBuilder();
      // print("   ✓ TxBuilder initialized");

      // print("📬 Creating recipient address...");
      final recipientAddress = Address(
        recipientAddressStr,
        wallet.network(),
      );
      final recipientScript = recipientAddress.scriptPubkey();
      // print("   - Recipient script generated");
      // print("   - Network: ${wallet.network()}");

      // print("🏦 Getting internal change address...");
      var internalChangeAddress = wallet.peekAddress(KeychainKind.external_, 0);
      final changeScript = internalChangeAddress.address.scriptPubkey();
      // print("   - Change script generated from index 0");

      // print("📋 Getting wallet policies...");
      final Policy externalWalletPolicy =
          wallet.policies(KeychainKind.external_)!;
      // print("   ✓ External policy retrieved");

      // print("🔍 Parsing policy JSON...");
      final Map<String, dynamic> policy = jsonDecode(
        externalWalletPolicy.asString(),
      );
      // print("   ✓ Policy JSON decoded");

      // print("🛣️ Extracting all paths to fingerprint: $targetFingerprint");
      final path = extractAllPathsToFingerprint(policy, targetFingerprint);
      // print("   ✓ Paths extracted");
      // print("   - Number of paths: ${path.length}");

      if (_isImmediateMultisig(correctPath)) {
        // print("🔐 MULTISIG PATH DETECTED - Building policy path for multisig");
        multiSigPath = {
          for (int i = 0; i < path[0]["ids"].length - 1; i++)
            path[0]["ids"][i]: Uint32List.fromList([path[0]["indexes"][i]]),
        };
        // print("   ✓ MultiSig path generated: $multiSigPath");
      } else {
        // print("⏰ TIMELOCK PATH DETECTED - Building policy path for timelock");
        // print("   - Using chosenPath index: $chosenPath");
        timeLockPath = {
          for (int i = 0; i < path[chosenPath]["ids"].length - 1; i++)
            path[chosenPath]["ids"][i]: Uint32List.fromList(
              i == path[chosenPath]["ids"].length - 2
                  ? [0, 1]
                  : [path[chosenPath]["indexes"][i]],
            ),
        };
        // print("   ✓ TimeLock path generated: $timeLockPath");
      }

      final Psbt txBuilderResult;

      if (isSendAllBalance) {
        // print("💰💰 SEND ALL BALANCE MODE - Attempting to send full balance");
        try {
          if (_isImmediateMultisig(correctPath)) {
            // print("   - Using MULTISIG for send-all");
            txBuilder
                .addRecipient(recipientScript, Amount.fromSat(amount))
                .policyPath(multiSigPath!, KeychainKind.internal)
                .policyPath(multiSigPath, KeychainKind.external_)
                .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
                .finish(wallet);
          } else {
            // print("   - Using TIMELOCK for send-all");
            txBuilder
                .addRecipient(recipientScript, Amount.fromSat(amount))
                .policyPath(timeLockPath!, KeychainKind.internal)
                .policyPath(timeLockPath, KeychainKind.external_)
                .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
                .finish(wallet);
          }
          // print("   ✓ Send-all transaction built successfully");
          return amount.toString();
        } catch (e) {
          // print("❌❌ Send-all transaction FAILED");
          // print("   - Error: $e");
          // print("   - Error type: ${e.runtimeType}");

          // print("📦 Fetching UTXOs for fallback calculation...");
          final utxos = await getUtxos();
          // print("   ✓ Retrieved ${utxos.length} UTXOs");

          List<dynamic> spendableUtxos = [];

          if (_isImmediateMultisig(correctPath)) {
            // print("   - MULTISIG: Using all UTXOs as spendable");
            spendableUtxos = utxos;
          } else {
            // print("   - TIMELOCK: Filtering spendable UTXOs by timelock");
            final timelock = spendingPaths[chosenPath]['timelock'];
            // print("     - Timelock value: $timelock");

            int currentHeight = await fetchCurrentBlockHeight();
            // print("     - Current block height: $currentHeight");

            final type =
                spendingPaths[chosenPath]['type'].toString().toLowerCase();
            // print("     - Timelock type: $type");

            spendableUtxos = utxos.where((utxo) {
              final blockHeight = utxo['status']['block_height'];

              bool isSpendable = false;
              if (type.contains('relativetimelock')) {
                isSpendable = blockHeight != null &&
                    (blockHeight + timelock - 1 <= currentHeight ||
                        timelock == 0);
              } else if (type.contains('absolutetimelock')) {
                isSpendable = timelock <= currentHeight;
              } else {
                isSpendable = true;
              }

              return isSpendable;
            }).toList();
            // print(
            //     "     ✓ Found ${spendableUtxos.length} spendable UTXOs after filtering");
          }

          final totalSpendableBalance = spendableUtxos.fold<int>(
            0,
            (sum, utxo) => sum + (int.parse(utxo['value'].toString())),
          );
          // print("   - Total spendable balance: $totalSpendableBalance sats");

          if (e.toString().contains("Insufficient funds:")) {
            // More flexible regex that extracts both BTC amounts
            final RegExp regex =
                RegExp(r'([\d.]+)\s*BTC\s+available.*?([\d.]+)\s*BTC\s+needed');
            final match = regex.firstMatch(e.toString());

            if (match != null) {
              final double availableBTC = double.parse(match.group(1)!);
              final double neededBTC = double.parse(match.group(2)!);

              final int availableAmount = (availableBTC * 100000000).round();
              final int neededAmount = (neededBTC * 100000000).round();

              final int fee = neededAmount - availableAmount;
              final int sendAllBalance = totalSpendableBalance - fee;

              if (sendAllBalance > 0) {
                return sendAllBalance.toString();
              } else {
                throw Exception('No balance available after fee deduction');
              }
            } else {
              throw Exception(
                  'Failed to extract amounts from exception: ${e.toString()}');
            }
          } else {
            rethrow;
          }
        }
      }

      // print("📦 Fetching UTXOs for transaction...");
      final utxos = localUtxos ?? await getUtxos();
      // print("   ✓ Retrieved ${utxos.length} UTXOs");

      if (_isImmediateMultisig(correctPath)) {
        // print("🔐 MULTISIG: Converting all UTXOs to OutPoints");
        spendableOutpoints = utxos
            .map(
                (utxo) => OutPoint(Txid.fromString(utxo['txid']), utxo['vout']))
            .toList();
        // print("   ✓ Created ${spendableOutpoints.length} spendable OutPoints");
      } else {
        // print("⏰ TIMELOCK: Filtering spendable UTXOs by timelock condition");
        final timelock = spendingPaths[chosenPath]['timelock'];
        // print("   - Timelock value: $timelock");

        final type = spendingPaths[chosenPath]['type'].toString().toLowerCase();
        // print("   - Timelock type: $type");

        int currentHeight = await fetchCurrentBlockHeight();
        // print("   - Current block height: $currentHeight");

        spendableOutpoints = utxos
            .where((utxo) {
              final blockHeight = utxo['status']['block_height'];

              bool isSpendable = false;
              if (type.contains('relativetimelock')) {
                isSpendable = blockHeight != null &&
                    (blockHeight + timelock - 1 <= currentHeight ||
                        timelock == 0);
              } else if (type.contains('absolutetimelock')) {
                isSpendable = timelock <= currentHeight;
              } else {
                isSpendable = true;
              }

              return isSpendable;
            })
            .map(
                (utxo) => OutPoint(Txid.fromString(utxo['txid']), utxo['vout']))
            .toList();
        // print(
        //     "   ✓ Filtered to ${spendableOutpoints.length} spendable OutPoints");
      }

      if (_isImmediateMultisig(correctPath)) {
        // print("🔐 MULTISIG: Building transaction with policy paths");

        try {
          txBuilderResult = txBuilder
              // .addUtxos(spendableOutpoints)
              // .manuallySelectedOnly()
              .addRecipient(recipientScript, Amount.fromSat(amount))
              .drainWallet()
              .policyPath(multiSigPath!, KeychainKind.internal)
              .policyPath(multiSigPath, KeychainKind.external_)
              .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
              .drainTo(changeScript)
              .finish(wallet);
        } catch (e) {
          print('❌ Error in transaction building: $e');
          rethrow;
        }
      } else {
        // print("⏰ TIMELOCK: Building transaction with timelock policy paths");

        // print("   - Building complete transaction in one chain...");
        txBuilderResult = txBuilder
            // .addUtxos(spendableOutpoints)
            // .manuallySelectedOnly()
            .addRecipient(recipientScript, Amount.fromSat(amount))
            .drainWallet()
            .policyPath(timeLockPath!, KeychainKind.internal)
            .policyPath(timeLockPath, KeychainKind.external_)
            .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
            .drainTo(changeScript)
            .finish(wallet);
        // print("   ✓ Transaction built successfully");
      }

      // print("✍️ Signing transaction...");
      try {
        final signed = wallet.sign(
          txBuilderResult,
          SignOptions(
            false,
            null,
            true,
            true,
            true,
            true,
          ),
        );
        // print("   ✓ Signing complete. Signed: $signed");

        if (signed) {
          // print("   ✅ Transaction fully signed - ready for broadcast");
          // print("   📤 Extracting transaction...");
          final tx = txBuilderResult.extractTx();
          // print("      ✓ Transaction extracted");

          ElectrumClient? client;
          bool broadcastSuccess = false;

          for (final server in electrumServers) {
            // print("   🌐 Attempting broadcast to Electrum server: $server");
            try {
              // TODO: Helper to broadcast
              client = ElectrumClient(server, null);
              // final txid =
              client.transactionBroadcast(tx);
              // print("      ✅✅ BROADCAST SUCCESSFUL!");
              // print("      📎 TXID: $txid");
              broadcastSuccess = true;
              break;
            } catch (e) {
              // print("      ❌ Broadcast failed for $server: $e");
            } finally {
              client?.dispose();
              // print("      - Client disposed");
            }
          }

          if (!broadcastSuccess) {
            // print("      ❌❌ All broadcast attempts failed");
            throw Exception("Failed to broadcast to any Electrum server");
          }

          // print("🏁 Transaction broadcast complete - returning null");
          return null;
        } else {
          // print("   ⚠️ Transaction partially signed - returning PSBT");
          final psbtString = txBuilderResult.serialize();
          // print("      - PSBT length: ${psbtString.length} chars");
          // print(
          //     "      - PSBT preview: ${psbtString.substring(0, min(50, psbtString.length))}...");

          // print("   🛣️ Correct path: $correctPath");

          final jsonContent = {
            "psbt": psbtString,
            "spending_path": correctPath,
          };

          final jsonString = jsonEncode(jsonContent);
          // print("      ✓ JSON encoded, length: ${jsonString.length} chars");
          // print("🏁 Returning PSBT JSON string");
          return jsonString;
        }
      } catch (broadcastError) {
        // print("   ❌❌ Broadcasting error: ${broadcastError.toString()}");
        throw Exception("Broadcasting error: ${broadcastError.toString()}");
      }
    } on Exception catch (e, stackTrace) {
      print("🔥🔥 EXCEPTION CAUGHT at top level:");
      print("   - Error: ${e.toString()}");
      print("   - StackTrace: $stackTrace");
      throw Exception("Error: ${e.toString()}");
    }
    // finally {
    //   print("🏁 ===== EXITING createPartialTx =====");
    // }
  }

  Future<String?> createBackupTx(
    String descriptor,
    String mnemonic,
    String recipientAddressStr,
    int amount,
    int? chosenPath,
    int avBalance, {
    bool isSendAllBalance = false,
    List<Map<String, dynamic>>? spendingPaths,
    double? customFeeRate,
    List<dynamic>? localUtxos,
  }) async {
    Map<String, Uint32List>? multiSigPath;
    Map<String, Uint32List>? timeLockPath;

    // print('Bool: $multiSig');
    Mnemonic trueMnemonic = Mnemonic.fromString(mnemonic);
    DerivationPath hardenedDerivationPath;

    if (settingsProvider.network == Network.bitcoin) {
      if (oldCase) {
        hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
      } else {
        hardenedDerivationPath = DerivationPath("m/84h/0h/0h");
      }
    } else {
      hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
    }
    final receivingDerivationPath = DerivationPath("m/0");

    final (receivingSecretKey, receivingPublicKey) = deriveDescriptorKeys(
      hardenedDerivationPath,
      receivingDerivationPath,
      trueMnemonic,
    );

    // print(receivingPublicKey);

    // Extract the content inside square brackets
    final RegExp regex = RegExp(r'\[([^\]]+)\]');
    final Match? match = regex.firstMatch(receivingPublicKey.toString());

    final String targetFingerprint = match!.group(1)!.split('/')[0];
    // print("Fingerprint: $targetFingerprint");

    final correctPath = _pathAt(spendingPaths!, chosenPath!);

    descriptor = (_isImmediateMultisig(correctPath))
        ? replacePubKeyWithPrivKeyMultiSig(
            descriptor,
            receivingPublicKey.toString(),
            receivingSecretKey.toString(),
          )
        : replacePubKeyWithPrivKeyOlder(
            chosenPath,
            descriptor,
            receivingPublicKey.toString(),
            receivingSecretKey.toString(),
          );

    // printInChunks('Sending Descriptor: $descriptor');

    wallet = await createSharedWallet(descriptor);

    final List<ConnectivityResult> connectivityResult =
        await (Connectivity().checkConnectivity());

    final Balance utxos;
    // final List<LocalUtxo> unspent;

    int totalSpending;

    if (connectivityResult.contains(ConnectivityResult.none)) {
      if (!isSendAllBalance) {
        // totalSpending = amount + BigInt.from(feeRate);

        totalSpending = amount;
        // print("Total Spending: $totalSpending");
        // print("Available Balance: $avBalance");
        // Check If there are enough funds available
        if (avBalance < totalSpending) {
          // Exit early if no confirmed UTXOs are available
          throw Exception(
            "Not enough confirmed funds available. Please wait until your transactions confirm.",
          );
        }
      }
    } else {
      await syncWallet(wallet);
      utxos = wallet.balance();
      // print("Available UTXOs: ${utxos.confirmed}");

      if (!isSendAllBalance) {
        // totalSpending = amount + BigInt.from(feeRate);

        totalSpending = amount;
        // print("Total Spending: $totalSpending");
        // print("Confirmed Utxos: ${utxos.spendable}");
        // Check If there are enough funds available
        if (utxos.trustedSpendable.toSat() < totalSpending) {
          // Exit early if no confirmed UTXOs are available
          throw Exception(
            "Not enough confirmed funds available. Please wait until your transactions confirm.",
          );
        }
      }

      // unspent = wallet.listUnspent();
    }

    final feeRate = customFeeRate ?? await getFeeRate();

    // print('Custom Fee Rate: $customFeeRate');

    List<OutPoint> spendableOutpoints = [];

    // for (var utxo in unspent) {
    //   print('UTXO: ${utxo.outpoint.txid}, Amount: ${utxo.txout.value}');
    // }

    try {
      // Build the transaction
      var txBuilder = TxBuilder();

      final recipientAddress = Address(
        recipientAddressStr,
        wallet.network(),
      );
      final recipientScript = recipientAddress.scriptPubkey();

      var internalChangeAddress = wallet.peekAddress(KeychainKind.internal, 0);

      final changeScript = internalChangeAddress.address.scriptPubkey();

      // final internalWalletPolicy = wallet.policies(KeychainKind.internalChain);
      final Policy externalWalletPolicy =
          wallet.policies(KeychainKind.external_)!;

      // print(externalWalletPolicy.contribution());

      // printPrettyJson(internalWalletPolicy!.asString());
      // printPrettyJson(externalWalletPolicy.asString());

      // const String targetFingerprint = "fb94d032";

      final Map<String, dynamic> policy = jsonDecode(
        externalWalletPolicy.asString(),
      );

      final path = extractAllPathsToFingerprint(policy, targetFingerprint);

      // print(path);

      if (_isImmediateMultisig(correctPath)) {
        // First Path: Direct MULTISIG
        multiSigPath = {
          for (int i = 0; i < path[0]["ids"].length - 1; i++)
            path[0]["ids"][i]: Uint32List.fromList([path[0]["indexes"][i]]),
        };

        // print("Generated multiSigPath: $multiSigPath");
      } else {
        timeLockPath = {
          for (int i = 0; i < path[chosenPath]["ids"].length - 1; i++)
            path[chosenPath]["ids"][i]: Uint32List.fromList(
              i ==
                      path[chosenPath]["ids"].length -
                          2 // Check if it's the second-to-last item
                  ? [0, 1] // Select both indexes for the last `THRESH` node
                  : [path[chosenPath]["indexes"][i]],
            ),
        };

        // print("Generated timeLockPath: $timeLockPath");
      }

      // Build the transaction:
      final Psbt txBuilderResult;

      // await syncWallet(wallet);

      if (isSendAllBalance) {
        // print(internalChangeAddress.address.asString());
        // print('AmountSendAll: ${amount.toInt()}');
        try {
          if (_isImmediateMultisig(correctPath)) {
            txBuilder
                .addRecipient(recipientScript, Amount.fromSat(amount))
                .policyPath(multiSigPath!, KeychainKind.internal)
                .policyPath(multiSigPath, KeychainKind.external_)
                .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
                .finish(wallet);
          } else {
            // print(timeLockPath);
            txBuilder
                .addRecipient(recipientScript, Amount.fromSat(amount))
                .policyPath(timeLockPath!, KeychainKind.internal)
                .policyPath(timeLockPath, KeychainKind.external_)
                .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
                .finish(wallet);
          }

          return amount.toString();
        } catch (e) {
          print('Error: $e');

          final utxos = await getUtxos();

          // print(spendingPaths);
          // print(chosenPath);

          List<dynamic> spendableUtxos = [];

          if (_isImmediateMultisig(correctPath)) {
            spendableUtxos = utxos;
          } else {
            // print(chosenPath);
            // print(spendingPaths);

            // final timelock = spendingPaths![chosenPath!]['timelock'];
            // print('Timelock value: $timelock');

            // int currentHeight = await fetchCurrentBlockHeight();
            // print('Current block height: $currentHeight');

            spendableUtxos = utxos.where((utxo) {
              final status = utxo['status'];
              final confirmed = status != null && status['confirmed'] == true;

              // print(
              //     'Evaluating UTXO: txid=${utxo['txid']}, confirmed=$confirmed');

              return confirmed;
            }).toList();

            // print('Spendable UTXOs found: ${spendableUtxos.length}');
            // for (var spendableUtxo in spendableUtxos) {
            //   print(
            //     'Spendable UTXO: txid=${spendableUtxo['txid']}, blockHeight=${spendableUtxo['status']['block_height']}',
            //   );
            // }
          }

          // Sum the value of spendable UTXOs
          final totalSpendableBalance = spendableUtxos.fold<int>(
            0,
            (sum, utxo) => sum + (int.parse(utxo['value'].toString())),
          );

          // print('totalSpendableBalance: $totalSpendableBalance');
          // for (var spendableUtxo in spendableUtxos) {
          //   print("Spendable Outputs: ${spendableUtxo['txid']}");
          // }
          // Handle insufficient funds
          if (e.toString().contains("Insufficient funds:")) {
            // More flexible regex that extracts both BTC amounts
            final RegExp regex =
                RegExp(r'([\d.]+)\s*BTC\s+available.*?([\d.]+)\s*BTC\s+needed');
            final match = regex.firstMatch(e.toString());

            if (match != null) {
              final double availableBTC = double.parse(match.group(1)!);
              final double neededBTC = double.parse(match.group(2)!);

              final int availableAmount = (availableBTC * 100000000).round();
              final int neededAmount = (neededBTC * 100000000).round();

              final int fee = neededAmount - availableAmount;
              final int sendAllBalance = totalSpendableBalance - fee;

              if (sendAllBalance > 0) {
                return sendAllBalance.toString();
              } else {
                throw Exception('No balance available after fee deduction');
              }
            } else {
              throw Exception(
                  'Failed to extract amounts from exception: ${e.toString()}');
            }
          } else {
            rethrow;
          }
        }
      }

      // print('Spending: $amount');
      // print('LocalUtxos: $localUtxos');

      final utxos = localUtxos ?? await getUtxos();

      // spendingPaths = extractAllPaths(policy);

      if (_isImmediateMultisig(correctPath)) {
        spendableOutpoints = utxos
            .map(
                (utxo) => OutPoint(Txid.fromString(utxo['txid']), utxo['vout']))
            .toList();
      } else {
        // print(spendingPaths);

        final timelock = spendingPaths[chosenPath]['timelock'];
        // print('Timelock value: $timelock');

        final type = spendingPaths[chosenPath]['type'].toString().toLowerCase();

        // print('Type: $type');

        int currentHeight = await fetchCurrentBlockHeight();
        // print('Current block height: $currentHeight');

        // Filter spendable UTXOs
        spendableOutpoints = utxos
            .where((utxo) {
              final blockHeight = utxo['status']['block_height'];

              bool isSpendable = false;

              if (type.contains('relativetimelock')) {
                isSpendable = blockHeight != null &&
                    (blockHeight + timelock - 1 <= currentHeight ||
                        timelock == 0);
              } else if (type.contains('absolutetimelock')) {
                isSpendable = timelock <= currentHeight;
              } else {
                // No timelock type; assume spendable
                isSpendable = true;
              }

              // print(
              //   'Evaluating UTXO: txid=${utxo['txid']}, blockHeight=$blockHeight, isSpendable=$isSpendable',
              // );

              return isSpendable;
            })
            .map(
                (utxo) => OutPoint(Txid.fromString(utxo['txid']), utxo['vout']))
            .toList();
      }

      if (_isImmediateMultisig(correctPath)) {
        // print('MultiSig Builder');

        // for (var spendableOutpoint in spendableOutpoints) {
        //   print('Spendable Outputs: ${spendableOutpoint.txid}');
        // }
        try {
          txBuilderResult = txBuilder
              // .addUtxos(spendableOutpoints)
              // .manuallySelectedOnly()
              .addRecipient(recipientScript, Amount.fromSat(amount))
              .drainWallet()
              .policyPath(multiSigPath!, KeychainKind.internal)
              .policyPath(multiSigPath, KeychainKind.external_)
              .feeRate(FeeRate.fromSatPerVb(feeRate.toInt()))
              .drainTo(changeScript)
              .finish(wallet);
        } catch (e) {
          print('❌ Error in transaction building: $e');
          rethrow;
        }

        // print('Transaction Built');
      } else {
        // print('TimeLock Builder');
        // for (var spendableOutpoint in spendableOutpoints) {
        //   print('Spendable Outputs: ${spendableOutpoint.txid}');
        // }

        // print('Sending: $amount');
        txBuilderResult = txBuilder
            // .enableRbf()
            // .enableRbfWithSequence(olderValue)
            // .addUtxos(spendableOutpoints)
            // .manuallySelectedOnly()
            .addRecipient(
                recipientScript, Amount.fromSat(amount)) // Send to recipient
            .drainWallet() // Drain all wallet UTXOs, sending change to a custom address
            .policyPath(timeLockPath!, KeychainKind.internal)
            .policyPath(timeLockPath, KeychainKind.external_)
            .feeRate(FeeRate.fromSatPerVb(
                feeRate.toInt())) // Set the fee rate (in satoshis per byte)
            .drainTo(changeScript) // Specify the address to send the change
            .finish(wallet); // Finalize the transaction with wallet's UTXOs

        // print('Transaction Built');
      }

      try {
        wallet.sign(
          txBuilderResult,
          SignOptions(
            false,
            null,
            true,
            true,
            true,
            true,
          ),
        );

        // final psbtString = base64Encode(txBuilderResult.$1.serialize());

        final tx = txBuilderResult.extractTx();

        final serialized = tx.serialize();

        // Convert bytes to hex string
        final rawHex = hex.encode(serialized);
        // print('🚀 Raw tx hex: $rawHex');

        return rawHex;
        // }
      } catch (broadcastError) {
        print("Broadcasting error: ${broadcastError.toString()}");
        throw Exception("Broadcasting error: ${broadcastError.toString()}");
      }
    } on Exception catch (e, stackTrace) {
      print("Error: ${e.toString()}");
      print('StackTrace: $stackTrace');

      throw Exception("Error: ${e.toString()}");
    }
  }

  // This method takes a PSBT, signs it with the second user and then broadcasts it
  Future<String?> signBroadcastTx(
    String psbtString,
    String descriptor,
    String mnemonic,
    Map<String, dynamic> correctPath,
    // int? chosenPath,
    List<Map<String, dynamic>>? spendingPaths,
  ) async {
    Mnemonic trueMnemonic = Mnemonic.fromString(mnemonic);
    DerivationPath hardenedDerivationPath;

    if (settingsProvider.network == Network.bitcoin) {
      if (oldCase) {
        hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
      } else {
        hardenedDerivationPath = DerivationPath("m/84h/0h/0h");
      }
    } else {
      hardenedDerivationPath = DerivationPath("m/84h/1h/0h");
    }
    final receivingDerivationPath = DerivationPath("m/0");

    final (receivingSecretKey, receivingPublicKey) = deriveDescriptorKeys(
      hardenedDerivationPath,
      receivingDerivationPath,
      trueMnemonic,
    );

    // print(spendingPaths);
    // print("-----------");
    // print(correctPath);

    final index = spendingPaths!.indexWhere(
      (path) => const DeepCollectionEquality().equals(path, correctPath),
    );

    // print(index);

    // final correctPath = _pathAt(spendingPaths!, chosenPath!);

    descriptor = (_isImmediateMultisig(correctPath))
        ? replacePubKeyWithPrivKeyMultiSig(
            descriptor,
            receivingPublicKey.toString(),
            receivingSecretKey.toString(),
          )
        : replacePubKeyWithPrivKeyOlder(
            index,
            descriptor,
            receivingPublicKey.toString(),
            receivingSecretKey.toString(),
          );

    // printInChunks('Sending descriptor: $descriptor');

    wallet = await createSharedWallet(descriptor);

    await syncWallet(wallet);

    // Convert the psbt String to a PartiallySignedTransaction
    final psbt = Psbt(psbtString);
    // printInChunks('Transaction Not Signed: $psbt');

    try {
      final signed = wallet.sign(
        psbt,
        SignOptions(
          false,
          null,
          true,
          true,
          true,
          true,
        ),
      );
      // printInChunks('Transaction Signed: $psbt');

      if (signed) {
        // print('Signing returned true');
        final tx = psbt.extractTx();
        // print('Extracting');

        // final lockTime = tx.lockTime();
        // print('LockTime: $lockTime');

        // for (var input in tx.input()) {
        //   print("Input sequence number: ${input.sequence}");
        // }

        // final currentHeight = await blockchain.getHeight();
        // print('Current height: $currentHeight');

        ElectrumClient? client;

        for (final server in electrumServers) {
          try {
            // Pick the right server for the network you're on
            client = ElectrumClient(server, null);

            final txid = client.transactionBroadcast(tx);

            print("Broadcasted! txid: $txid");
          } catch (e) {
            print("Broadcast failed: $e");
            rethrow;
          } finally {
            client?.dispose();
          }
        } // print('Transaction sent');
      } else {
        final jsonContent = {
          "psbt": psbt.serialize(),
          "spending_path": correctPath,
        };

        final jsonString = jsonEncode(jsonContent);

        return jsonString;
      }

      // printInChunks('Transaction after Signing: $psbt');

      return null;
    } on Exception catch (e) {
      print("Error: ${e.toString()}");

      throw Exception("Error: ${e.toString()} psbt: $psbt");
    }
  }

  ///
  ///
  ///
  ///
  ///
  ///
  ///
  /// UTILITIES
  ///
  ///
  ///
  ///
  ///
  ///
  ///

  void printInChunks(String text, {int chunkSize = 800}) {
    for (int i = 0; i < text.length; i += chunkSize) {
      print(
        text.substring(
          i,
          i + chunkSize > text.length ? text.length : i + chunkSize,
        ),
      );
    }
  }

  void printPrettyJson(String jsonString) {
    final jsonObject = json.decode(jsonString);
    const encoder = JsonEncoder.withIndent('  ');
    printInChunks(encoder.convert(jsonObject));
  }

  void printPsbtJson(String serializedPsbt) {
    final jsonObject = json.decode(serializedPsbt);

    // Pretty-print JSON with indentation
    final prettyJson = JsonEncoder.withIndent('  ').convert(jsonObject);

    print(prettyJson);
  }

  String generateRandomName() {
    final random = Random();

    // Get random nouns and adjectives from the package
    final adjective = WordPair.random().first;
    final noun = WordPair.random().second;

    return '${adjective.capitalize()}${noun.capitalize()}${random.nextInt(1000)}';
  }

  String formatDuration(Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds} seconds';
    } else if (duration.inMinutes < 60) {
      return '${duration.inMinutes} minutes';
    } else {
      return '${duration.inHours} hours';
    }
  }
}

// Used to generate a random SharedWallet descriptorName
extension StringExtension on String {
  String capitalize() => this[0].toUpperCase() + substring(1);
}

String _bytesToHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

extension TxDetailsToJson on TxDetails {
  Map<String, dynamic> toJson() {
    // print('[TX][JSON] Serializing txid: $txid');

    Map<String, dynamic>? confirmationTime;

    final cp = chainPosition;
    if (cp is ConfirmedChainPosition) {
      // print('[TX][JSON] Tx is CONFIRMED');
      confirmationTime = {
        "height": cp.confirmationBlockTime.blockId,
        "timestamp": cp.confirmationBlockTime.confirmationTime,
      };
    } else {
      // print('[TX][JSON] Tx is UNCONFIRMED');
      confirmationTime = null;
    }

    final hex = _bytesToHex(tx.serialize());
    // print('[TX][JSON] Raw hex length: ${hex.length}');

    return {
      "txid": txid.toString(),
      "received": received.toSat(),
      "sent": sent.toSat(),
      "fee": fee?.toSat(),
      "confirmationTime": confirmationTime,
      "transaction": {
        "hex": hex,
      },
    };
  }
}
