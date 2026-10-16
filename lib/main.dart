import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:another_telephony/telephony.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:share_plus/share_plus.dart';

// ============================================================================
// 1. TRUECALLER-STYLE OVERLAY ENTRY POINT & BACKGROUND SMS HANDLER
// ============================================================================

@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AurumOverlayPrompt(),
    ),
  );
}

@pragma('vm:entry-point')
Future<void> backgroundSmsHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final body = message.body ?? '';
  final sender = message.address ?? '';

  if (sender.toUpperCase().contains('MPESA') || body.contains('Confirmed.')) {
    final parsed = MpesaParser.parse(body, message.date ?? DateTime.now().millisecondsSinceEpoch);
    if (parsed != null) {
      await AurumDatabase.instance.insertTransactionWithRules(parsed);
      if (await FlutterOverlayWindow.isPermissionGranted()) {
        await FlutterOverlayWindow.showOverlay(
          enableDrag: true,
          overlayTitle: "Aurum Accountability",
          overlayContent: "Categorize M-Pesa Transaction",
          flag: OverlayFlag.defaultFlag,
          visibility: NotificationVisibility.visibilityPublic,
          positionGravity: PositionGravity.auto,
          height: 1150,
          width: WindowSize.matchParent,
        );
        await Future.delayed(const Duration(milliseconds: 350));
        await FlutterOverlayWindow.shareData(jsonEncode(parsed));
      }
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AurumDatabase.instance.database;
  runApp(const AurumApp());
}

// ============================================================================
// 2. THEME & DESIGN TOKENS (DARK OBSIDIAN & LIQUID GOLD)
// ============================================================================

class AurumTheme {
  static const Color obsidian = Color(0xFF08080A);
  static const Color surface = Color(0xFF121318);
  static const Color cardGlass = Color(0xFF1A1B22);
  static const Color gold = Color(0xFFD4AF37);
  static const Color goldBright = Color(0xFFFFDF73);
  static const Color emerald = Color(0xFF2ECC71);
  static const Color amber = Color(0xFFF39C12);
  static const Color crimson = Color(0xFFE74C3C);

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: obsidian,
        primaryColor: gold,
        colorScheme: const ColorScheme.dark(
          primary: gold,
          secondary: goldBright,
          surface: surface,
        ),
        useMaterial3: true,
      );
}

// ============================================================================
// 3. M-PESA REGEX ENGINE & EDGE CASE HANDLER
// ============================================================================

class MpesaParser {
  static Map<String, dynamic>? parse(String rawSms, int timestampMs) {
    final codeMatch = RegExp(r'^([A-Z0-9]{10})\s+Confirmed', caseSensitive: false).firstMatch(rawSms.trim());
    if (codeMatch == null) return null;

    final receiptCode = codeMatch.group(1)!.toUpperCase();
    final isFuliza = rawSms.toLowerCase().contains('fuliza');
    final isReversal = rawSms.toLowerCase().contains('reversed');

    String direction = 'OUT';
    if (rawSms.toLowerCase().contains('you have received') ||
        rawSms.toLowerCase().contains('deposit of') ||
        isReversal) {
      direction = 'IN';
    }

    // Extract main transaction amount
    final amountRegex = RegExp(r'Ksh\s*([\d,]+\.\d{2})', caseSensitive: false);
    final matches = amountRegex.allMatches(rawSms).toList();
    if (matches.isEmpty) return null;

    final double amount = double.tryParse(matches[0].group(1)!.replaceAll(',', '')) ?? 0.0;

    // Extract New M-Pesa balance if present
    double? newBalance;
    final balMatch = RegExp(r'balance is Ksh\s*([\d,]+\.\d{2})', caseSensitive: false).firstMatch(rawSms);
    if (balMatch != null) {
      newBalance = double.tryParse(balMatch.group(1)!.replaceAll(',', ''));
    }

    // Extract Transaction Fee
    double fee = 0.0;
    final feeMatch = RegExp(r'Transaction cost,\s*Ksh\s*([\d,]+\.\d{2})', caseSensitive: false).firstMatch(rawSms);
    if (feeMatch != null) {
      fee = double.tryParse(feeMatch.group(1)!.replaceAll(',', '')) ?? 0.0;
    }

    // Extract Counterparty (Recipient / Sender)
    String merchant = 'M-Pesa Transfer';
    final sentTo = RegExp(r'sent to\s+(.+?)\s+on\s+\d', caseSensitive: false).firstMatch(rawSms);
    final paidTo = RegExp(r'paid to\s+(.+?)\.\s+on', caseSensitive: false).firstMatch(rawSms);
    final receivedFrom = RegExp(r'received\s+Ksh[\d,]+\.\d{2}\s+from\s+(.+?)\s+on\s+\d', caseSensitive: false).firstMatch(rawSms);

    if (sentTo != null) {
      merchant = sentTo.group(1)!.trim();
    } else if (paidTo != null) {
      merchant = paidTo.group(1)!.trim();
    } else if (receivedFrom != null) {
      merchant = receivedFrom.group(1)!.trim();
    } else if (isFuliza) {
      merchant = 'Fuliza M-Pesa Repayment';
    }

    return {
      'receipt_code': receiptCode,
      'account_id': 1, // Default M-Pesa Account ID
      'amount': amount,
      'fee': fee,
      'direction': direction,
      'merchant': merchant,
      'category': isFuliza ? 'Fuliza / Debt' : 'Uncategorized',
      'note': isFuliza ? 'Auto-flagged Fuliza edge case' : '',
      'is_fuliza': isFuliza ? 1 : 0,
      'timestamp': timestampMs,
      'new_balance': newBalance,
    };
  }
}

// ============================================================================
// 4. SQLITE ARCHITECTURE (ACCOUNTS, TRANSACTIONS, MERCHANT_RULES, BUDGETS)
// ============================================================================

class AurumDatabase {
  static final AurumDatabase instance = AurumDatabase._init();
  static Database? _database;
  AurumDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'aurum_command_center.db');
    _database = await openDatabase(path, version: 1, onCreate: _createDB);
    return _database!;
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        balance REAL NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        receipt_code TEXT UNIQUE,
        account_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        fee REAL DEFAULT 0.0,
        direction TEXT NOT NULL,
        merchant TEXT NOT NULL,
        category TEXT NOT NULL,
        note TEXT,
        is_fuliza INTEGER DEFAULT 0,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE merchant_rules (
        keyword TEXT PRIMARY KEY,
        category TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE budgets (
        category TEXT PRIMARY KEY,
        monthly_cap REAL NOT NULL
      )
    ''');

    // Seed Default Accounts
    await db.insert('accounts', {'name': 'M-Pesa Primary', 'type': 'M-Pesa', 'balance': 24500.0});
    await db.insert('accounts', {'name': 'Equity / KCB Bank', 'type': 'Bank', 'balance': 68000.0});
    await db.insert('accounts', {'name': 'Cash Wallet', 'type': 'Cash', 'balance': 3500.0});

    // Seed Smart Merchant Rules
    final defaultRules = {
      'NAIVAS': 'Groceries',
      'CARREFOUR': 'Groceries',
      'QUICKMART': 'Groceries',
      'KPLC': 'Utilities',
      'ZUKU': 'Utilities',
      'SAFARICOM': 'Utilities',
      'UBER': 'Transport',
      'BOLT': 'Transport',
      'TOTAL': 'Transport',
      'SHELL': 'Transport',
      'JAVA': 'Dining Out',
      'KFC': 'Dining Out',
    };
    for (var entry in defaultRules.entries) {
      await db.insert('merchant_rules', {'keyword': entry.key, 'category': entry.value});
    }

    // Seed Default Budget Guardrails
    final defaultBudgets = {
      'Groceries': 20000.0,
      'Dining Out': 12000.0,
      'Transport': 15000.0,
      'Utilities': 10000.0,
      'Uncategorized': 8000.0,
    };
    for (var entry in defaultBudgets.entries) {
      await db.insert('budgets', {'category': entry.key, 'monthly_cap': entry.value});
    }
  }

  Future<String> resolveCategory(String merchant, String fallback) async {
    if (fallback != 'Uncategorized') return fallback;
    final db = await instance.database;
    final rules = await db.query('merchant_rules');
    final upperMerchant = merchant.toUpperCase();
    for (final rule in rules) {
      final kw = (rule['keyword'] as String).toUpperCase();
      if (upperMerchant.contains(kw)) {
        return rule['category'] as String;
      }
    }
    // Heuristic AI guess for person-to-person vs business
    if (RegExp(r'\d{7,}').hasMatch(merchant)) return 'Personal Transfer';
    return 'Uncategorized';
  }

  Future<bool> insertTransactionWithRules(Map<String, dynamic> txData) async {
    final db = await instance.database;
    final category = await resolveCategory(txData['merchant'], txData['category']);

    final row = {
      'receipt_code': txData['receipt_code'],
      'account_id': txData['account_id'] ?? 1,
      'amount': txData['amount'],
      'fee': txData['fee'] ?? 0.0,
      'direction': txData['direction'],
      'merchant': txData['merchant'],
      'category': category,
      'note': txData['note'] ?? '',
      'is_fuliza': txData['is_fuliza'] ?? 0,
      'timestamp': txData['timestamp'],
    };

    try {
      await db.insert('transactions', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      // Update balance
      if (txData['new_balance'] != null && txData['account_id'] == 1) {
        await db.update('accounts', {'balance': txData['new_balance']}, where: 'id = 1');
      } else {
        final acctId = txData['account_id'] ?? 1;
        final double delta = txData['direction'] == 'IN'
            ? (txData['amount'] as double)
            : -((txData['amount'] as double) + (txData['fee'] as double? ?? 0.0));
        await db.rawUpdate('UPDATE accounts SET balance = balance + ? WHERE id = ?', [delta, acctId]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> learnRuleAndUpdateTransaction({
    required String receiptCode,
    required String merchant,
    required String category,
    required String note,
    required bool isFuliza,
  }) async {
    final db = await instance.database;
    await db.update(
      'transactions',
      {
        'category': category,
        'note': note,
        'is_fuliza': isFuliza ? 1 : 0,
      },
      where: 'receipt_code = ?',
      whereArgs: [receiptCode],
    );

    final cleanKey = merchant.split(' ').first.toUpperCase();
    if (cleanKey.length >= 3 && cleanKey != 'M-PESA') {
      await db.insert(
        'merchant_rules',
        {'keyword': cleanKey, 'category': category},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

// ============================================================================
// 5. TRUECALLER-STYLE FLOATING ACCOUNTABILITY OVERLAY UI
// ============================================================================

class AurumOverlayPrompt extends StatefulWidget {
  const AurumOverlayPrompt({super.key});

  @override
  State<AurumOverlayPrompt> createState() => _AurumOverlayPromptState();
}

class _AurumOverlayPromptState extends State<AurumOverlayPrompt> {
  Map<String, dynamic> _tx = {
    'receipt_code': 'SIM992KPLX',
    'amount': 1450.0,
    'fee': 23.0,
    'merchant': 'NAIVAS SUPERMARKET WESTLANDS',
    'category': 'Groceries',
    'direction': 'OUT',
  };

  final TextEditingController _noteCtrl = TextEditingController();
  String _selectedCategory = 'Groceries';
  final List<String> _categories = [
    'Groceries',
    'Dining Out',
    'Transport',
    'Utilities',
    'Personal Transfer',
    'Business',
    'Fuliza / Debt',
  ];

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((event) {
      if (event != null && event is String) {
        final decoded = jsonDecode(event) as Map<String, dynamic>;
        setState(() {
          _tx = decoded;
          if (_categories.contains(decoded['category'])) {
            _selectedCategory = decoded['category'];
          }
        });
      }
    });
  }

  Future<void> _commitOverlay({required bool markFuliza}) async {
    await AurumDatabase.instance.learnRuleAndUpdateTransaction(
      receiptCode: _tx['receipt_code'],
      merchant: _tx['merchant'],
      category: markFuliza ? 'Fuliza / Debt' : _selectedCategory,
      note: _noteCtrl.text.trim(),
      isFuliza: markFuliza,
    );
    await FlutterOverlayWindow.closeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xF5101116),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AurumTheme.gold, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: AurumTheme.gold.withOpacity(0.25),
                blurRadius: 24,
                spreadRadius: 2,
              )
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AurumTheme.gold.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_rounded, color: AurumTheme.gold, size: 22),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'AURUM LIVE ACCOUNTABILITY',
                        style: TextStyle(
                          color: AurumTheme.gold,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => FlutterOverlayWindow.closeOverlay(),
                      icon: const Icon(Icons.close, color: Colors.white54),
                    )
                  ],
                ),
                const Divider(color: Colors.white12),
                const SizedBox(height: 6),
                Text(
                  'Ksh ${NumberFormat('#,##0.00').format(_tx['amount'] ?? 0)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${_tx['merchant']} • Code: ${_tx['receipt_code']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Tap to Confirm or Re-Assign Category:',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _categories.map((cat) {
                    final active = _selectedCategory == cat;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedCategory = cat),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: active ? AurumTheme.gold : Colors.white10,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          cat,
                          style: TextStyle(
                            color: active ? Colors.black : Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _noteCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Why did you spend this? (Accountability Note)',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.06),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        onPressed: () => _commitOverlay(markFuliza: true),
                        child: const Text('Ignore / Fuliza', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AurumTheme.gold,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () => _commitOverlay(markFuliza: false),
                        child: const Text(
                          'Save to Ledger',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 6. MAIN APPLICATION & COMMAND CENTER DASHBOARD
// ============================================================================

class
