import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:another_telephony/telephony.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:share_plus/share_plus.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ============================================================================
// 1. ENTRY POINTS & BACKGROUND SMS RECEIVER
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
          overlayContent: "Categorize M-Pesa Outflow",
          flag: OverlayFlag.defaultFlag,
          visibility: NotificationVisibility.visibilityPublic,
          positionGravity: PositionGravity.auto,
          height: 1100,
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
// 2. THEME & TOKENS (OBSIDIAN BLACK & LIQUID GOLD)
// ============================================================================

class AurumTheme {
  static const Color obsidian = Color(0xFF08080A);
  static const Color surface = Color(0xFF121318);
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
// 3. BIOMETRIC & PIN GATEKEEPER SCREEN
// ============================================================================

class AurumAuthGate extends StatefulWidget {
  const AurumAuthGate({super.key});

  @override
  State<AurumAuthGate> createState() => _AurumAuthGateState();
}

class _AurumAuthGateState extends State<AurumAuthGate> {
  final LocalAuthentication _auth = LocalAuthentication();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  String _enteredPin = '';
  String _storedPin = '1234'; // Default PIN on fresh install
  bool _canCheckBiometrics = false;
  String _statusMessage = 'Enter PIN or authenticate via fingerprint';

  @override
  void initState() {
    super.initState();
    _initAuth();
  }

  Future<void> _initAuth() async {
    final pin = await _storage.read(key: 'aurum_pin');
    if (pin == null) {
      await _storage.write(key: 'aurum_pin', value: '1234');
    } else {
      _storedPin = pin;
    }

    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isDeviceSupported = await _auth.isDeviceSupported();
      setState(() {
        _canCheckBiometrics = canCheck && isDeviceSupported;
      });
      if (_canCheckBiometrics) {
        // Quick login: Automatically trigger biometric popup on app launch
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _triggerFingerprintAuth();
        });
      }
    } catch (_) {}
  }

  Future<void> _triggerFingerprintAuth() async {
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: 'Scan fingerprint to access Aurum Vault',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (authenticated && mounted) {
        _unlockApp();
      }
    } on PlatformException catch (e) {
      setState(() {
        _statusMessage = 'Biometric failed: ${e.message}';
      });
    }
  }

  void _onDigitPress(String digit) {
    if (_enteredPin.length < 4) {
      setState(() {
        _enteredPin += digit;
      });
      if (_enteredPin.length == 4) {
        _verifyPin();
      }
    }
  }

  void _onBackspace() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      });
    }
  }

  void _verifyPin() {
    if (_enteredPin == _storedPin) {
      _unlockApp();
    } else {
      setState(() {
        _statusMessage = 'Incorrect PIN. Try again.';
        _enteredPin = '';
      });
      HapticFeedback.vibrate();
    }
  }

  void _unlockApp() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AurumCommandCenter()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.obsidian,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AurumTheme.gold.withOpacity(0.6), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.18),
                    blurRadius: 28,
                    spreadRadius: 2,
                  )
                ],
              ),
              child: const Icon(Icons.shield_rounded, color: AurumTheme.gold, size: 44),
            ),
            const SizedBox(height: 18),
            const Text(
              'AURUM SECURITY VAULT',
              style: TextStyle(
                color: AurumTheme.gold,
                fontSize: 16,
                letterSpacing: 2.2,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 28),
            // PIN Dots Indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (index) {
                final filled = index < _enteredPin.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? AurumTheme.gold : Colors.transparent,
                    border: Border.all(
                      color: filled ? AurumTheme.goldBright : Colors.white24,
                      width: 1.5,
                    ),
                  ),
                );
              }),
            ),
            const Spacer(),
            // Numeric Keypad + Quick Biometric Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                children: [
                  for (var row in [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: row.map((digit) => _buildKeypadButton(digit)).toList(),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Quick Biometric Trigger Button
                        IconButton(
                          iconSize: 34,
                          icon: const Icon(Icons.fingerprint_rounded, color: AurumTheme.goldBright),
                          tooltip: 'Quick Login via Fingerprint',
                          onPressed: _triggerFingerprintAuth,
                        ),
                        _buildKeypadButton('0'),
                        IconButton(
                          iconSize: 28,
                          icon: const Icon(Icons.backspace_outlined, color: Colors.white70),
                          onPressed: _onBackspace,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypadButton(String digit) {
    return InkWell(
      onTap: () => _onDigitPress(digit),
      borderRadius: BorderRadius.circular(36),
      child: Container(
        width: 68,
        height: 68,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white10),
        ),
        child: Text(
          digit,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 4. M-PESA PARSER & EDGE CASES
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

    final amountRegex = RegExp(r'Ksh\s*([\d,]+\.\d{2})', caseSensitive: false);
    final matches = amountRegex.allMatches(rawSms).toList();
    if (matches.isEmpty) return null;

    final double amount = double.tryParse(matches[0].group(1)!.replaceAll(',', '')) ?? 0.0;

    double? newBalance;
    final balMatch = RegExp(r'balance is Ksh\s*([\d,]+\.\d{2})', caseSensitive: false).firstMatch(rawSms);
    if (balMatch != null) {
      newBalance = double.tryParse(balMatch.group(1)!.replaceAll(',', ''));
    }

    double fee = 0.0;
    final feeMatch = RegExp(r'Transaction cost,\s*Ksh\s*([\d,]+\.\d{2})', caseSensitive: false).firstMatch(rawSms);
    if (feeMatch != null) {
      fee = double.tryParse(feeMatch.group(1)!.replaceAll(',', '')) ?? 0.0;
    }

    String merchant = 'M-Pesa Transaction';
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
      merchant = 'Fuliza Repayment';
    }

    return {
      'receipt_code': receiptCode,
      'account_id': 1,
      'amount': amount,
      'fee': fee,
      'direction': direction,
      'merchant': merchant,
      'category': isFuliza ? 'Fuliza / Debt' : 'Uncategorized',
      'note': isFuliza ? 'Auto-flagged Fuliza' : '',
      'is_fuliza': isFuliza ? 1 : 0,
      'timestamp': timestampMs,
      'new_balance': newBalance,
    };
  }
}

// ============================================================================
// 5. SQLITE DATABASE ENGINE
// ============================================================================

class AurumDatabase {
  static final AurumDatabase instance = AurumDatabase._init();
  static Database? _database;
  AurumDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'aurum_ledger.db');
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

    await db.insert('accounts', {'name': 'M-Pesa Primary', 'type': 'M-Pesa', 'balance': 24500.0});
    await db.insert('accounts', {'name': 'Equity / KCB', 'type': 'Bank', 'balance': 65000.0});
    await db.insert('accounts', {'name': 'Cash in Wallet', 'type': 'Cash', 'balance': 4200.0});

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
    for (final entry in defaultRules.entries) {
      await db.insert('merchant_rules', {'keyword': entry.key, 'category': entry.value});
    }

    final defaultBudgets = {
      'Groceries': 20000.0,
      'Dining Out': 12000.0,
      'Transport': 15000.0,
      'Utilities': 8000.0,
      'Uncategorized': 5000.0,
    };
    for (final entry in defaultBudgets.entries) {
      await db.insert('budgets', {'category': entry.key, 'monthly_cap': entry.value});
    }
  }

  Future<String> resolveCategory(String merchant, String fallback) async {
    if (fallback != 'Uncategorized') return fallback;
    final db = await instance.database;
    final rules = await db.query('merchant_rules');
    final upper = merchant.toUpperCase();
    for (final r in rules) {
      final kw = (r['keyword'] as String).toUpperCase();
      if (upper.contains(kw)) {
        return r['category'] as String;
      }
    }
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

  Future<void> updateTransactionAndLearnRule({
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
// 6. TRUECALLER-STYLE OVERLAY UI
// ============================================================================

class AurumOverlayPrompt extends StatefulWidget {
  const AurumOverlayPrompt({super.key});

  @override
  State<AurumOverlayPrompt> createState() => _AurumOverlayPromptState();
}

class _AurumOverlayPromptState extends State<AurumOverlayPrompt> {
  Map<String, dynamic> _tx = {
    'receipt_code': 'SIM990KPLX',
    'amount': 1500.0,
    'merchant': 'NAIVAS SUPERMARKET',
    'category': 'Groceries',
  };

  final TextEditingController _noteCtrl = TextEditingController();
  String _selectedCategory = 'Groceries';
  final List<String> _categories = [
    'Groceries',
    'Dining Out',
    'Transport',
    'Utilities',
    'Personal Transfer',
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

  Future<void> _commit(bool markFuliza) async {
    await AurumDatabase.instance.updateTransactionAndLearnRule(
      receiptCode: _tx['receipt_code'] ?? '',
      merchant: _tx['merchant'] ?? '',
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
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xF2101116),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AurumTheme.gold, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: AurumTheme.gold.withOpacity(0.2),
                blurRadius: 20,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield_rounded, color: AurumTheme.gold, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'AURUM LIVE ACCOUNTABILITY',
                      style: TextStyle(
                        color: AurumTheme.gold,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => FlutterOverlayWindow.closeOverlay(),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
                ],
              ),
              const Divider(color: Colors.white12),
              Text(
                'Ksh ${NumberFormat('#,##0.00').format(_tx['amount'] ?? 0)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                '${_tx['merchant']} • ${_tx['receipt_code']}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _categories.map((c) {
                  final active = _selectedCategory == c;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedCategory = c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: active ? AurumTheme.gold : Colors.white10,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        c,
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
              const SizedBox(height: 10),
              TextField(
                controller: _noteCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Accountability Note (e.g. Lunch with team)',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.06),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                      ),
                      onPressed: () => _commit(true),
                      child: const Text('Fuliza / Ignore', style: TextStyle(color: Colors.white70, fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AurumTheme.gold,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () => _commit(false),
                      child: const Text('Save to Ledger', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 7. MAIN APPLICATION ROOT WIDGET
// ============================================================================

class AurumApp extends StatelessWidget {
  const AurumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aurum Ledger',
      debugShowCheckedModeBanner: false,
      theme: AurumTheme.darkTheme,
      home: const AurumAuthGate(),
    );
  }
}

// ============================================================================
// 8. FINANCIAL COMMAND CENTER DASHBOARD
// ============================================================================

class AurumCommandCenter extends StatefulWidget {
  const AurumCommandCenter({super.key});

  @override
  State<AurumCommandCenter> createState() => _AurumCommandCenterState();
}

class _AurumCommandCenterState extends State<AurumCommandCenter> {
  final Telephony telephony = Telephony.instance;
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _budgets = [];
  String _timeFilter = 'Month';
  int _navIndex = 0;
  bool _overlayGranted = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    await _refreshData();
    if (Platform.isAndroid) {
      _overlayGranted = await FlutterOverlayWindow.isPermissionGranted();
      final status = await Permission.sms.request();
      if (status.isGranted) {
        telephony.listenIncomingSms(
          onNewMessage: (SmsMessage msg) async {
            await backgroundSmsHandler(msg);
            await _refreshData();
          },
          onBackgroundMessage: backgroundSmsHandler,
        );
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshData() async {
    final db = await AurumDatabase.instance.database;
    final accts = await db.query('accounts');
    final txs = await db.query('transactions', orderBy: 'timestamp DESC');
    final bgs = await db.query('budgets');

    if (mounted) {
      setState(() {
        _accounts = accts;
        _transactions = txs;
        _budgets = bgs;
      });
    }
  }

  Future<void> _backfillInbox() async {
    if (!Platform.isAndroid) return;
    final granted = await Permission.sms.request().isGranted;
    if (!granted) return;

    final messages = await telephony.getInboxSms(
      columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
      filter: SmsFilter.where(SmsColumn.ADDRESS).like('%MPESA%'),
    );

    int count = 0;
    for (final m in messages) {
      final parsed = MpesaParser.parse(
        m.body ?? '',
        m.date ?? DateTime.now().millisecondsSinceEpoch,
      );
      if (parsed != null) {
        final inserted = await AurumDatabase.instance.insertTransactionWithRules(parsed);
        if (inserted) count++;
      }
    }
    await _refreshData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AurumTheme.gold,
          content: Text(
            'Synced $count M-Pesa transactions.',
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
  }

  List<Map<String, dynamic>> get _filteredTransactions {
    final now = DateTime.now();
    return _transactions.where((tx) {
      final dt = DateTime.fromMillisecondsSinceEpoch(tx['timestamp'] as int);
      if (_timeFilter == 'Today') {
        return dt.year == now.year && dt.month == now.month && dt.day == now.day;
      } else if (_timeFilter == '7 Days') {
        return now.difference(dt).inDays <= 7;
      } else if (_timeFilter == 'Month') {
        return dt.year == now.year && dt.month == now.month;
      }
      return true;
    }).toList();
  }

  Map<String, double> _accountCashflow(int accountId) {
    double mIn = 0;
    double mOut = 0;
    final now = DateTime.now();
    for (final tx in _transactions) {
      final dt = DateTime.fromMillisecondsSinceEpoch(tx['timestamp'] as int);
      if (tx['account_id'] == accountId && dt.month == now.month && dt.year == now.year) {
        if (tx['is_fuliza'] == 1) continue;
        if (tx['direction'] == 'IN') {
          mIn += (tx['amount'] as num).toDouble();
        } else {
          mOut += (tx['amount'] as num).toDouble() + (tx['fee'] as num).toDouble();
        }
      }
    }
    return {'in': mIn, 'out': mOut};
  }

  Future<void> _exportCsv() async {
    final buf = StringBuffer();
    buf.writeln('ReceiptCode,AccountID,Direction,Amount,Fee,Merchant,Category,Note,Fuliza,Timestamp');
    for (final t in _transactions) {
      final dt = DateTime.fromMillisecondsSinceEpoch(t['timestamp'] as int).toIso8601String();
      buf.writeln('"${t['receipt_code']}",${t['account_id']},${t['direction']},${t['amount']},${t['fee']},"${t['merchant']}","${t['category']}","${t['note']}",${t['is_fuliza']},$dt');
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/aurum_ledger.csv');
    await file.writeAsString(buf.toString());
    await Share.shareXFiles([XFile(file.path)], text: 'Aurum Ledger CSV Backup');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AurumTheme.obsidian,
        elevation: 0,
        title: const Text(
          'AURUM LEDGER',
          style: TextStyle(
            color: AurumTheme.gold,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
            fontSize: 16,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Simulate M-Pesa SMS',
            onPressed: _showSimulatorDialog,
            icon: const Icon(Icons.bolt, color: AurumTheme.goldBright),
          ),
          IconButton(
            tooltip: 'Backfill M-Pesa Inbox',
            onPressed: _backfillInbox,
            icon: const Icon(Icons.sync, color: Colors.white70),
          ),
          IconButton(
            tooltip: 'Export CSV',
            onPressed: _exportCsv,
            icon: const Icon(Icons.download_rounded, color: Colors.white70),
          ),
          IconButton(
            tooltip: 'Lock Vault',
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const AurumAuthGate()),
              );
            },
            icon: const Icon(Icons.lock_outline, color: Colors.white70),
          ),
        ],
      ),
      body: IndexedStack(
        index: _navIndex,
        children: [
          _buildDashboardTab(),
          _buildBudgetsTab(),
          _buildAccountsTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AurumTheme.gold,
        foregroundColor: Colors.black,
        onPressed: _showUnifiedEntryModal,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Log Entry', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AurumTheme.surface,
        indicatorColor: AurumTheme.gold.withOpacity(0.2),
        selectedIndex: _navIndex,
        onDestinationSelected: (idx) => setState(() => _navIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_customize_outlined),
            selectedIcon: Icon(Icons.dashboard_customize, color: AurumTheme.gold),
            label: 'Command Center',
          ),
          NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed, color: AurumTheme.gold),
            label: 'Guardrails',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet, color: AurumTheme.gold),
            label: 'Vault & Accounts',
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    final filtered = _filteredTransactions;
    double totalSpend = 0;
    double totalFees = 0;
    for (final tx in filtered) {
      if (tx['direction'] == 'OUT' && tx['is_fuliza'] == 0) {
        totalSpend += (tx['amount'] as num).toDouble();
        totalFees += (tx['fee'] as num).toDouble();
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 95),
      children: [
        if (!_overlayGranted && Platform.isAndroid)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AurumTheme.amber.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AurumTheme.amber),
            ),
            child: Row(
              children: [
                const Icon(Icons.layers_outlined, color: AurumTheme.amber),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Enable Floating Overlay for instant M-Pesa accountability.',
                    style: TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await FlutterOverlayWindow.requestPermission();
                    _overlayGranted = await FlutterOverlayWindow.isPermissionGranted();
                    setState(() {});
                  },
                  child: const Text('GRANT', style: TextStyle(color: AurumTheme.goldBright)),
                )
              ],
            ),
          ),

        // Multi-Account Balance Strip
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _accounts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final acct = _accounts[index];
              final flow = _accountCashflow(acct['id'] as int);
              return Container(
                width: 230,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1F2029), Color(0xFF121318)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AurumTheme.gold.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          acct['name'].toString().toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          acct['type'],
                          style: const TextStyle(color: AurumTheme.gold, fontSize: 10),
                        ),
                      ],
                    ),
                    Text(
                      'Ksh ${NumberFormat('#,##0.00').format(acct['balance'])}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.arrow_upward, color: AurumTheme.emerald, size: 12),
                        Text(
                          ' Ksh ${NumberFormat.compact().format(flow['in'])}',
                          style: const TextStyle(color: AurumTheme.emerald, fontSize: 11),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.arrow_downward, color: AurumTheme.crimson, size: 12),
                        Text(
                          ' Ksh ${NumberFormat.compact().format(flow['out'])}',
                          style: const TextStyle(color: AurumTheme.crimson, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),

        // Glassmorphic Hero Card
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AurumTheme.gold.withOpacity(0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'TOTAL SPEND',
                        style: TextStyle(
                          color: AurumTheme.gold,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      Text(
                        'Fees: Ksh ${NumberFormat('#,##0').format(totalFees)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Ksh ${NumberFormat('#,##0.00').format(totalSpend)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: ['Today', '7 Days', 'Month', 'All'].map((filter) {
                      final active = _timeFilter == filter;
                      return GestureDetector(
                        onTap: () => setState(() => _timeFilter = filter),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: active ? AurumTheme.gold : Colors.white10,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            filter,
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
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),

        const Text(
          'LEDGER STREAM',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),

        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AurumTheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'No transactions recorded in this period.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          )
        else
          ...filtered.map((tx) {
            final isOut = tx['direction'] == 'OUT';
            final dt = DateTime.fromMillisecondsSinceEpoch(tx['timestamp'] as int);
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AurumTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: isOut ? AurumTheme.crimson.withOpacity(0.15) : AurumTheme.emerald.withOpacity(0.15),
                    child: Icon(
                      isOut ? Icons.arrow_downward : Icons.arrow_upward,
                      color: isOut ? AurumTheme.crimson : AurumTheme.emerald,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tx['merchant'],
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          '${tx['category']} • ${DateFormat('dd MMM, HH:mm').format(dt)}',
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${isOut ? '-' : '+'} Ksh ${NumberFormat('#,##0').format(tx['amount'])}',
                    style: TextStyle(
                      color: isOut ? Colors.white : AurumTheme.emerald,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildBudgetsTab() {
    final Map<String, double> categorySpend = {};
    final now = DateTime.now();

    for (final tx in _transactions) {
      final dt = DateTime.fromMillisecondsSinceEpoch(tx['timestamp'] as int);
      if (tx['direction'] == 'OUT' && tx['is_fuliza'] == 0 && dt.month == now.month && dt.year == now.year) {
        final c = tx['category'] as String;
        categorySpend[c] = (categorySpend[c] ?? 0) + (tx['amount'] as num).toDouble();
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'SPEND DISTRIBUTION',
          style: TextStyle(color: AurumTheme.gold, fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 180,
          child: categorySpend.isEmpty
              ? const Center(child: Text('No monthly spend data yet', style: TextStyle(color: Colors.white38)))
              : PieChart(
                  PieChartData(
                    centerSpaceRadius: 40,
                    sectionsSpace: 2,
                    sections: categorySpend.entries.map((e) {
                      return PieChartSectionData(
                        value: e.value,
                        title: e.key,
                        radius: 50,
                        color: AurumTheme.gold,
                        titleStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black),
                      );
                    }).toList(),
                  ),
                ),
        ),
        const SizedBox(height: 20),
        const Text(
          'BUDGET GUARDRAILS (GOLD → AMBER → RED)',
          style: TextStyle(color: AurumTheme.gold, fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const SizedBox(height: 12),
        ..._budgets.map((b) {
          final cat = b['category'] as String;
          final cap = (b['monthly_cap'] as num).toDouble();
          final spent = categorySpend[cat] ?? 0.0;
          final ratio = (spent / cap).clamp(0.0, 1.0);

          Color barColor = AurumTheme.gold;
          if (ratio >= 0.9) {
            barColor = AurumTheme.crimson;
          } else if (ratio >= 0.7) {
            barColor = AurumTheme.amber;
          }

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AurumTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: barColor.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(cat, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    Text(
                      'Ksh ${NumberFormat('#,##0').format(spent)} / ${NumberFormat('#,##0').format(cap)}',
                      style: TextStyle(color: barColor, fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 8,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildAccountsTab() {
    final nameCtrl = TextEditingController();
    final balCtrl = TextEditingController();
    final newPinCtrl = TextEditingController();
    final storage = const FlutterSecureStorage();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'VAULT PIN SECURITY',
          style: TextStyle(color: AurumTheme.gold, fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AurumTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: newPinCtrl,
                obscureText: true,
                maxLength: 4,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Update 4-Digit Security PIN',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AurumTheme.gold,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(40),
                ),
                onPressed: () async {
                  if (newPinCtrl.text.trim().length == 4) {
                    await storage.write(key: 'aurum_pin', value: newPinCtrl.text.trim());
                    newPinCtrl.clear();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('PIN updated successfully')),
                      );
                    }
                  }
                },
                child: const Text('Update PIN', style: TextStyle(fontWeight: FontWeight.bold)),
              )
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'ADD ACCOUNT (BANK / CASH / OTHER)',
          style: TextStyle(color: AurumTheme.gold, fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AurumTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Account Name (e.g. Absa Bank)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: balCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Starting Balance (Ksh)'),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AurumTheme.gold,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(42),
                ),
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty) return;
                  final db = await AurumDatabase.instance.database;
                  await db.insert('accounts', {
                    'name': nameCtrl.text.trim(),
                    'type': 'Bank',
                    'balance': double.tryParse(balCtrl.text) ?? 0.0,
                  });
                  await _refreshData();
                  nameCtrl.clear();
                  balCtrl.clear();
                },
                child: const Text('Save Account', style: TextStyle(fontWeight: FontWeight.bold)),
              )
            ],
          ),
        ),
      ],
    );
  }

  void _showUnifiedEntryModal() {
    String sourceType = 'Cash';
    String direction = 'OUT';
    final amtCtrl = TextEditingController();
    final merchantCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AurumTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setMState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.of(ctx).viewInsets.bottom + 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MANUAL ENTRY', style: TextStyle(color: AurumTheme.gold, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: ['M-Pesa', 'Cash', 'Bank'].map((t) {
                      final active = sourceType == t;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setMState(() => sourceType = t),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: active ? AurumTheme.gold : Colors.white10,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              t,
                              style: TextStyle(
                                color: active ? Colors.black : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('Expense'),
                        selected: direction == 'OUT',
                        onSelected: (_) => setMState(() => direction = 'OUT'),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('Income'),
                        selected: direction == 'IN',
                        onSelected: (_) => setMState(() => direction = 'IN'),
                      ),
                    ],
                  ),
                  TextField(
                    controller: amtCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Amount (Ksh)'),
                  ),
                  TextField(
                    controller: merchantCtrl,
                    decoration: const InputDecoration(labelText: 'Description / Payee'),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AurumTheme.gold,
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: () async {
                      final val = double.tryParse(amtCtrl.text) ?? 0.0;
                      if (val <= 0) return;
                      await AurumDatabase.instance.insertTransactionWithRules({
                        'receipt_code': 'MAN${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
                        'account_id': sourceType == 'Cash' ? 3 : (sourceType == 'Bank' ? 2 : 1),
                        'amount': val,
                        'fee': 0.0,
                        'direction': direction,
                        'merchant': merchantCtrl.text.isEmpty ? '$sourceType Entry' : merchantCtrl.text,
                        'category': 'Uncategorized',
                        'note': '',
                        'is_fuliza': 0,
                        'timestamp': DateTime.now().millisecondsSinceEpoch,
                      });
                      if (mounted) Navigator.pop(ctx);
                      await _refreshData();
                    },
                    child: const Text('Save Entry', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

void _showSimulatorDialog() {
    final smsCtrl = TextEditingController(
      text: 'UCG892MKLQ Confirmed. Ksh1,850.00 paid to NAIVAS SUPERMARKET. on 16/10/26 at 1:15 PM. New M-PESA balance is Ksh22,650.00. Transaction cost, Ksh23.00.',
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.surface,
        title: const Text('Test Ingestion & Overlay', style: TextStyle(color: AurumTheme.gold, fontSize: 15)),
        content: TextField(
          controller: smsCtrl,
          maxLines: 4,
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AurumTheme.gold,
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              final parsed = MpesaParser.parse(smsCtrl.text, DateTime.now().millisecondsSinceEpoch);
              if (parsed != null) {
                await AurumDatabase.instance.insertTransactionWithRules(parsed);
                await _refreshData();
                if (Platform.isAndroid && await FlutterOverlayWindow.isPermissionGranted()) {
                  await FlutterOverlayWindow.showOverlay(
                    height: 1100,
                    width: WindowSize.matchParent,
                    enableDrag: true,
                  );
                  await Future.delayed(const Duration(milliseconds: 300));
                  await FlutterOverlayWindow.shareData(jsonEncode(parsed));
                }
              }
              if (mounted) Navigator.pop(ctx);
            },
            child: const Text('Parse & Test'),
          ),
        ],
      ),
    );
  }
}