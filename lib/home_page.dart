import 'dart:convert';
import 'package:flutter/foundation.dart'; // For compute if needed, though simpler here
import 'dart:io';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';


class Transaction {
  final String sender;
  final String cleanSender;
  final String accountName;
  final String body;
  final DateTime date;
  final double amount;
  final bool isCredit;
  final double? currentBalance;

  Transaction({
    required this.sender,
    required this.cleanSender,
    required this.body,
    required this.date,
    required this.amount,
    required this.isCredit,
    this.currentBalance,
    required this.accountName,
  });
  Map<String, dynamic> toJson() => {
    'sender': sender,
    'cleanSender': cleanSender,
    'body': body,
    'date': date.toIso8601String(),
    'amount': amount,
    'isCredit': isCredit,
    'currentBalance': currentBalance,
    'accountName': accountName,
  };

  factory Transaction.fromJson(Map<String, dynamic> json) {
    return Transaction(
      sender: json['sender'],
      cleanSender: json['cleanSender'],
      body: json['body'],
      date: DateTime.parse(json['date']),
      amount: json['amount'],
      isCredit: json['isCredit'],
      currentBalance: json['currentBalance'],
      accountName: json['accountName'],
    );
  }
}

class GroupedTransaction {
  final String sender;
  final double totalAmount;
  final double totalCredit;
  final double totalDebit;
  final List<Transaction> transactions;

  GroupedTransaction({
    required this.sender,
    required this.totalAmount,
    required this.totalCredit,
    required this.totalDebit,
    required this.transactions,
  });
}

class CategoryGroup {
  final String categoryName;
  final double totalAmount; // Net flow
  final double totalCredit;
  final double totalDebit;
  final List<GroupedTransaction> merchants;

  CategoryGroup({
    required this.categoryName,
    required this.totalAmount,
    required this.totalCredit,
    required this.totalDebit,
    required this.merchants,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SmsQuery _query = SmsQuery();
  
  // All loaded transactions
  List<Transaction> _allTransactions = [];
  
  // Display Data (Can be CategoryGroup or GroupedTransaction)
  List<dynamic> _displayList = [];
  
  // Filtered and Grouped data for display (Deprecated-ish, but keeping for PDF generation if needed, or we adapt)
  // We'll regenerate a flat list for PDF.
  List<GroupedTransaction> _flatGroupedTransactions = []; // For PDF usage
  
  double _monthTotalCredit = 0.0;
  double _monthTotalDebit = 0.0;
  Map<String, double> _manualOpeningBalances = {}; // Key format: "Sender_YYYY_MM"
  Map<String, String> _merchantCategories = {}; // Key: Merchant Name, Value: Category Name

  
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = true;
  bool _permissionDenied = false;

  String _filterType = 'All'; // 'All', 'Credit', 'Debit'
  List<String> _accounts = ['All'];
  String _selectedAccount = 'All';
  String? _userName;

  Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/transactions.ndjson');
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    await _checkUserName();
    await _loadManualBalances();
    await _loadCategories();
    await _loadMessages();
  }

  Future<void> _checkUserName() async {
    final prefs = await SharedPreferences.getInstance();
    String? name = prefs.getString('user_name');
    if (name == null) {
      // Ask for name
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        name = await _showNameDialog();
        if (name != null && name!.isNotEmpty) {
           await prefs.setString('user_name', name!);
           setState(() {
             _userName = name;
           });
        }
      });
    } else {
      setState(() {
        _userName = name;
      });
    }
  }

  Future<String?> _showNameDialog() async {
    TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false, // Force entry
      builder: (context) => AlertDialog(
        title: const Text("Welcome!"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Please enter your name to continue."),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: "Name",
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text("Save"),
          )
        ],
      ),
    );
  }

  Future<void> _loadCategories() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    Map<String, String> loaded = {};
    for (String key in keys) {
      if (key.startsWith('cat_')) {
        // key: cat_MERCHANT
        final val = prefs.getString(key);
        if (val != null) {
          loaded[key.substring(4)] = val;
        }
      }
    }
    setState(() {
      _merchantCategories = loaded;
    });
  }

  Future<void> _saveCategory(String merchant, String category) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("cat_$merchant", category);
    setState(() {
      _merchantCategories[merchant] = category;
    });
    _filterByMonth(); // Re-group with new category
  }

  Future<void> _loadManualBalances() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    Map<String, double> loaded = {};
    for (String key in keys) {
      if (key.startsWith('balance_')) {
        // key: balance_Sender_2025_12
        final val = prefs.getDouble(key);
        if (val != null) {
          loaded[key.substring(8)] = val; // Store as "Sender_2025_12"
        }
      }
    }
    setState(() {
      _manualOpeningBalances = loaded;
    });
  }

  Future<void> _saveManualBalance(String sender, DateTime month, double amount) async {
    final prefs = await SharedPreferences.getInstance();
    final key = "${sender}_${month.year}_${month.month}";
    await prefs.setDouble("balance_$key", amount);
    setState(() {
      _manualOpeningBalances[key] = amount;
    });
    // Re-process to apply changes
    // _processMessages(await _query.querySms(kinds: [SmsQueryKind.inbox], count: 500));
    _loadMessages(); // Reload will re-read file and SMS merge
  }

  Future<void> _loadMessages() async {
    // 1. Load Local JSON first
    List<Transaction> localTransactions = [];
    try {
      final file = await _localFile;
      if (await file.exists()) {
        final lines = await file.readAsLines();
        for (var line in lines) {
          if (line.trim().isNotEmpty) {
             try {
               localTransactions.add(Transaction.fromJson(jsonDecode(line)));
             } catch (e) {
               print("Error parsing line: $e");
             }
          }
        }
      }
    } catch (e) {
      print("Error reading local file: $e");
    }

    // 2. Query SMS
    var permission = await Permission.sms.status;
    if (permission.isDenied || permission.isRestricted || permission.isPermanentlyDenied) {
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        setState(() {
          _permissionDenied = true;
          _isLoading = false;
        });
        // If permission denied, show just local data? 
        if (localTransactions.isNotEmpty) {
           // We need to run reconcile on these
           // But _processMessages expects SmsMessage. 
           // Let's refactor _processMessages to take Transactions or handle logic differently.
           // Actually, easiest is to treat localTransactions as the "base".
           _finalizeTransactions(localTransactions, []);
        }
        return;
      }
    }

    final messages = await _query.querySms(
      kinds: [SmsQueryKind.inbox],
      count: 200, // Reduced count since we cache, but initially we might need more?
      // Optimization: Only query if we want updates.
    );

    // 3. Convert SMS to Transactions (Memory only for now)
    List<Transaction> smsTransactions = _convertSmsToTransactions(messages);

    // 4. Differential Update
    // Identify SMS transactions that are NOT in localTransactions
    // Key: Date + Body + Sender
    Set<String> localKeys = localTransactions.map((t) => "${t.date.millisecondsSinceEpoch}_${t.sender}_${t.amount}").toSet();
    
    List<Transaction> newTransactions = [];
    for (var t in smsTransactions) {
      String key = "${t.date.millisecondsSinceEpoch}_${t.sender}_${t.amount}";
      if (!localKeys.contains(key)) {
        newTransactions.add(t);
        localKeys.add(key); // Prevent double adding within the same batch
      }
    }

    // 5. Append New to File
    if (newTransactions.isNotEmpty) {
      final file = await _localFile;
      final sink = file.openWrite(mode: FileMode.append);
      for (var t in newTransactions) {
        sink.writeln(jsonEncode(t.toJson()));
      }
      await sink.close();
      localTransactions.addAll(newTransactions);
    }

    _finalizeTransactions(localTransactions, []);
  }

  // Refactored message processing
  List<Transaction> _convertSmsToTransactions(List<SmsMessage> messages) {
    List<Transaction> temp = [];
    final amountRegex = RegExp(r'(?:Rs\.?|INR|₹)\s*([\d,]+(?:\.\d{1,2})?)', caseSensitive: false);

    for (var msg in messages) {
      if (msg.body == null || msg.address == null) continue;
      String body = msg.body!.toLowerCase();
      
      // EXCLUSION LOGIC (Same as before)
      if (body.contains("to be paid") || 
          body.contains("bill generated") || 
          body.contains("payment due") || 
          body.contains("to be debited") ||
          body.contains("will be debited") ||
          body.contains("about to debit") ||
          body.contains("scheduled for") ||
          body.contains("auto-pay scheduled") ||
          body.contains("request received") ||
          body.contains("statement") ||
          body.contains("summary") ||
          body.contains("report") ||
          body.contains("have activated") ||
          body.contains("outstanding")) {
        continue;
      }

      if ((body.contains("due") || body.contains("remind") || body.contains("upcoming")) && 
          !body.contains("debited") && !body.contains("paid") && !body.contains("sent") && !body.contains("auto-debited")) {
        continue;
      }

      bool hasCreditKw = body.contains("credited") || body.contains("received") || body.contains("deposited") || body.contains("salary");
      bool hasDebitKw = body.contains("debited") || body.contains("spent") || body.contains("sent") || body.contains("paid") || body.contains("purchase") || body.contains("withdrawn");
      
      if (!hasCreditKw && !hasDebitKw) continue;

      bool isCredit = false;
      bool isDebit = false;

      if (hasCreditKw && hasDebitKw) {
        int creditIndex = body.indexOf("credited");
        if (creditIndex == -1) creditIndex = 9999;
        int debitIndex = body.indexOf("debited");
        if (debitIndex == -1) debitIndex = 9999;
        if (debitIndex < creditIndex) {
            isDebit = true;
        } else {
            isCredit = true;
        }
      } else {
        isCredit = hasCreditKw;
        isDebit = hasDebitKw;
      }

      final match = amountRegex.firstMatch(msg.body!);
      if (match != null) {
        String amountStr = match.group(1)!.replaceAll(',', '');
        double? amount = double.tryParse(amountStr);
        
        if (amount != null) {
          String entity = _extractEntity(msg.body!, msg.address!);
          String accountName = _extractAccount(msg.body!, msg.address!);
          if (body.contains("salary")) entity = "SALARY";
          double? balance = _extractBalance(msg.body!);

          temp.add(Transaction(
            sender: msg.address!,
            cleanSender: entity,
            accountName: accountName,
            body: msg.body!,
            date: msg.date ?? DateTime.now(),
            amount: amount,
            isCredit: isCredit,
            currentBalance: balance,
          ));
        }
      }
    }
    return temp;
  }

  void _finalizeTransactions(List<Transaction> transactions, List<dynamic> unused) {
      // Sort
    transactions.sort((a, b) => b.date.compareTo(a.date));

    final reconciled = _reconcileTransactions(transactions);

    // Extract unique accounts
    Set<String> accountSet = {};
    for (var t in reconciled) {
      if (t.accountName.isNotEmpty) {
        accountSet.add(t.accountName);
      }
    }
    List<String> sortedAccounts = accountSet.toList()..sort();
    
    setState(() {
      _allTransactions = reconciled;
      _accounts = ['All', ...sortedAccounts];
      // reset selection if not in list (unless it's 'All')
      if (!_accounts.contains(_selectedAccount)) {
        _selectedAccount = 'All';
      }
      _isLoading = false;
    });

    _filterByMonth();
  }


  String _cleanSenderName(String sender) {
    if (sender.contains('-')) {
      final parts = sender.split('-');
      if (parts.length > 1) {
        return parts.sublist(1).join('-');
      }
    }
    return sender;
  }

  // extract the "Receiver" or "Merchant" from the body
  String _extractEntity(String body, String sender) {
    // 1. UPI Reference Pattern (Common in many banks)
    // "UPI/12398/Amazon"
    final upiRefMatch = RegExp(r'UPI/(?:(?:\d+|CR|DR)/)*([a-zA-Z0-9\s\.]+)', caseSensitive: false).firstMatch(body);
    if (upiRefMatch != null) {
      String potentialName = upiRefMatch.group(1)!.trim();
      if (potentialName.length > 3 && !RegExp(r'^\d+$').hasMatch(potentialName)) {
        return potentialName.replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
      }
    }

    // 2. "to" Pattern
    final toMatch = RegExp(r'(?:paid|sent|transfer|debited).*?to\s+([a-zA-Z0-9\s\.]+?)(?:\s+(?:on|using|via|Ref|UPI)|$|\.)', caseSensitive: false).firstMatch(body);
    if (toMatch != null) {
      String name = toMatch.group(1)!.trim();
      
      // If the match is a phone number
      if (RegExp(r'^\d+$').hasMatch(name.replaceAll(' ', ''))) {
        // Look for name in Parens: "987654321(Name)"
        final nameInParens = RegExp("\\((['\"]?)([a-zA-Z\\s]+)(['\"]?)\\)").firstMatch(body);
        if (nameInParens != null) {
          return nameInParens.group(2)!.toUpperCase();
        }
      } else if (name.isNotEmpty && name.length < 30 && !name.toLowerCase().contains("account")) {
        return name.toUpperCase();
      }
    }

    // 3. "at" Pattern
    final atMatch = RegExp(r'(?:spent|purchase|txn).*?at\s+([a-zA-Z0-9\s\.]+?)(?:\s+(?:on|using|with|Ref)|$|\.)', caseSensitive: false).firstMatch(body);
    if (atMatch != null) {
      String name = atMatch.group(1)!.trim();
      if (name.isNotEmpty && name.length < 30) {
        return name.toUpperCase();
      }
    }
    
    // 3.5 "Beneficiary credited" Pattern
    final creditedMatch = RegExp(r';\s*([a-zA-Z\s\.]+) credited', caseSensitive: false).firstMatch(body);
    if (creditedMatch != null) {
      String name = creditedMatch.group(1)!.trim();
      if (name.isNotEmpty && name.length < 30) {
        return name.toUpperCase();
      }
    }

    // 4. VPA Pattern
    final upiMatch = RegExp(r'to\s+([a-zA-Z0-9\.\s]+?)@\w+', caseSensitive: false).firstMatch(body);
    if (upiMatch != null) {
      return upiMatch.group(1)!.trim().replaceAll('.', ' ').toUpperCase();
    }
    
    // 5. Fallback for Credits
    if (body.toLowerCase().contains("credited") || body.toLowerCase().contains("received")) {
        final fromMatch = RegExp(r'(?:from|by)\s+([a-zA-Z0-9\s\.]+?)(?:\s+(?:on|via|Ref|IMPS|NEFT)|$|\.)', caseSensitive: false).firstMatch(body);
        if (fromMatch != null) {
             String name = fromMatch.group(1)!.trim();
             if (name.isNotEmpty && name.length < 30 && !name.toLowerCase().contains("account")) {
               return name.toUpperCase();
             }
        }
    }

    return _cleanSenderName(sender);
  }

  // Deprecated direct processing, split into _convert and _finalize
  void _processMessages(List<SmsMessage> messages) {
    if (messages.isEmpty) return;
    List<Transaction> txns = _convertSmsToTransactions(messages);
    _finalizeTransactions(txns, []);
  }



  // REPLACED: Opening Balance Prompt removed as per request.
  String _extractAccount(String body, String sender) {
    // Look for Account Number patterns: "A/c X1234", "A/c ...1234", "A/c 1234", "ending 1234", "X1234"
    // Regex matches 3-4 digits preceded by X or . or 'ending '
    // We strictly match patterns that imply YOUR account, trying to avoid beneficiary accounts if possible
    // though beneficiary patterns often look different (e.g. "to A/c..").
    
    // Pattern 1: Explicit "A/c" or "Card" with number
    final accMatch = RegExp(r'(?:A\/c|Account|Card|Acct|Debit Card|Credit Card)\s*(?:No\.?|Number)?\s*(?:[:\s-]*)(?:[xX\.]*(\d{3,4}))', caseSensitive: false).firstMatch(body);
    if (accMatch != null) {
      return "XX${accMatch.group(1)}";
    }
    
    // Pattern 2: "ending 1234"
    final cardMatch = RegExp(r'ending\s*(?:with)?\s*(?:[xX\.]*(\d{4}))', caseSensitive: false).firstMatch(body);
    if (cardMatch != null) {
       return "XX${cardMatch.group(1)}";
    }

    // Pattern 3: Simple "X1234" pattern often found in alerts
    // But be careful not to match random codes. Usually preceded by space or start.
    // e.g. "Acct XX1234" is covered above. 
    // "HDFC Bank: Rs 500 debited from X1234"
    final xMatch = RegExp(r'\s+X(\d{4})[\s\.]', caseSensitive: false).firstMatch(body);
    if (xMatch != null) {
      return "XX${xMatch.group(1)}";
    }

    return ''; // Return empty string if no valid account number is found
  }

  double? _extractBalance(String body) {
     final balMatch = RegExp(r'(?:Bal|Balance|Avail\s*Bal|A\/c\s*Bal)[:\.\s-]*\s*(?:Rs\.?|INR|₹)?\s*([\d,]+\.?\d{0,2})', caseSensitive: false).firstMatch(body);
     if (balMatch != null) {
         String raw = balMatch.group(1)!.replaceAll(',', '');
         // Remove trailing '.' if present (e.g. "5000.")
         if (raw.endsWith('.')) raw = raw.substring(0, raw.length - 1);
         return double.tryParse(raw);
     }
     return null;
  }

  List<Transaction> _reconcileTransactions(List<Transaction> input) {
    if (input.isEmpty) return [];

    Map<String, List<Transaction>> bySender = {};
    for (var t in input) {
      if (!bySender.containsKey(t.sender)) bySender[t.sender] = [];
      bySender[t.sender]!.add(t);
    }

    List<Transaction> output = [];

    bySender.forEach((sender, txns) {
      // Sort Ascending for processing
      txns.sort((a, b) => a.date.compareTo(b.date));
      
      List<Transaction> senderReconciled = [];
      double? lastBalance;
      double runningFlowSinceLastBalance = 0;

      // CHECK FOR MANUAL OPENING BALANCE
      // We need to find the balance for this specific sender for the month of the FIRST transaction?
      // Or we check if there are manual balances covering the periods in this list.
      // Since txns cover multiple months, we need to apply manual balances as checkpoints.
      
      // Convert Manual Balances to "Checkpoint Transactions"
      // Key format: "Sender_YYYY_MM" -> Date: YYYY-MM-01 00:00:00
      List<Transaction> checkpoints = [];
      _manualOpeningBalances.forEach((key, value) {
         if (key.startsWith(sender)) {
            // Extract Date
            final parts = key.split('_'); // [Sender, YYYY, MM]
            // We need to match EXACT accountName or Sender? 
            // The ManualBalance currently uses "Sender". 
            // Since we shifted to "AccountName" in Transaction, we might have a mismatch if we strictly filter.
            // For now, let's keep it bound to Sender logic as reconciler is iterating by SENDER (line 393: bySender).
            // This method creates 'bySender' aggregation. 
            // If we want per-account reconciliation, we should group by accountName in _reconcileTransactions.
            
            // However, _reconcileTransactions logic is still using 'sender' for grouping.
            // Let's keep it as is for now to avoid breaking existing reconciliation logic, 
            // as 'sender' is stable. accountName is derived.
            // When filtering for display, we will use accountName.
            
            if (parts.length >= 3) {
               int year = int.parse(parts[parts.length-2]);
               int month = int.parse(parts[parts.length-1]);
               DateTime date = DateTime(year, month, 1);
               
               checkpoints.add(Transaction(
                 sender: sender,
                 cleanSender: "Manual Balance",
                 accountName: "Manual Adjustment",
                 body: "Opening Balance set by User",
                 date: date,
                 amount: 0,
                 isCredit: true,
                 currentBalance: value,
               ));
            }
         }
      });
      
      // Merge Checkpoints into txns
      txns.addAll(checkpoints);
      txns.sort((a, b) => a.date.compareTo(b.date));

      for (var t in txns) {
        // If it's our manual checkpoint, it consumes the balance logic but adds no flow
        bool isCheckpoint = t.cleanSender == "Manual Balance";
        double flow = isCheckpoint ? 0 : (t.isCredit ? t.amount : -t.amount);
        
        if (lastBalance != null) {
          if (t.currentBalance != null) {
            // Checkpoint
            double expected = lastBalance! + runningFlowSinceLastBalance + flow;
            double actual = t.currentBalance!;
            double diff = actual - expected;

            // If discrepancy is significant (> 1.0)
            if (diff.abs() > 1.0) {
               bool isCredit = diff > 0;
               senderReconciled.add(Transaction(
                 sender: sender,
                 cleanSender: "Balance Correction",
                 accountName: "System Correction",
                 body: "Auto-adjustment: Balance gap detected.",
                 date: t.date.subtract(const Duration(seconds: 1)), // Just before this txn
                 amount: diff.abs(),
                 isCredit: isCredit,
                 currentBalance: null, 
               ));
            }
            
            lastBalance = actual;
            runningFlowSinceLastBalance = 0;
          } else {
             runningFlowSinceLastBalance += flow;
          }
        } else {
          // Initialize baseline
          if (t.currentBalance != null) {
             lastBalance = t.currentBalance;
             runningFlowSinceLastBalance = 0;
          }
        }
        senderReconciled.add(t);
      }
      output.addAll(senderReconciled);
    });

    // Final sort Descending for global list
    output.sort((a, b) => b.date.compareTo(a.date));
    return output;
  }

  // ... existing state variables
  Transaction? _lastMonthlyTransaction;

  // ... existing methods

  void _filterByMonth() {
    // 1. Get ALL transactions for this month (for the "Last Transaction" reference)
    final allMonthTransactions = _allTransactions.where((t) {
      return t.date.year == _selectedDate.year && t.date.month == _selectedDate.month;
    }).toList();
    
    // Sort to find the latest
    allMonthTransactions.sort((a, b) => b.date.compareTo(a.date));
    
    if (allMonthTransactions.isNotEmpty) {
      _lastMonthlyTransaction = allMonthTransactions.first;
    } else {
      _lastMonthlyTransaction = null;
    }

    // 2. Filter for the List View
    final filtered = allMonthTransactions.where((t) {
      // Account Filter
      if (_selectedAccount != 'All' && t.accountName != _selectedAccount) {
        return false;
      }
      // Type Filter
      if (_filterType == 'Credit') return t.isCredit;
      if (_filterType == 'Debit') return !t.isCredit;
      return true;
    }).toList();

    // 3. Hierarchical Grouping
    // Map<CategoryName, Map<MerchantName, List<Transaction>>>
    Map<String, Map<String, List<Transaction>>> structure = {};
    // Separate list for uncategorized merchants to keep them top-level
    Map<String, List<Transaction>> uncategorizedMap = {};

    for (var t in filtered) {
       String? cat = _merchantCategories[t.cleanSender];
       if (cat != null) {
         // It has a category
         if (!structure.containsKey(cat)) {
           structure[cat] = {};
         }
         if (!structure[cat]!.containsKey(t.cleanSender)) {
           structure[cat]![t.cleanSender] = [];
         }
         structure[cat]![t.cleanSender]!.add(t);
       } else {
         // Uncategorized
         if (!uncategorizedMap.containsKey(t.cleanSender)) {
           uncategorizedMap[t.cleanSender] = [];
         }
         uncategorizedMap[t.cleanSender]!.add(t);
       }
    }

    List<dynamic> layout = [];
    List<GroupedTransaction> allFlatGroups = []; // For PDF
    double totalCredit = 0;
    double totalDebit = 0;

    // Process Categories
    structure.forEach((catName, merchantMap) {
       List<GroupedTransaction> subGroups = [];
       double catCredit = 0;
       double catDebit = 0;

       merchantMap.forEach((merchName, txns) {
          GroupedTransaction gt = _createGroup(merchName, txns);
          subGroups.add(gt);
          catCredit += gt.totalCredit;
          catDebit += gt.totalDebit;
          allFlatGroups.add(gt);
       });
       
       totalCredit += catCredit;
       totalDebit += catDebit;

       // Sort merchants inside category by activity
       subGroups.sort((a, b) => b.transactions.first.date.compareTo(a.transactions.first.date));

       layout.add(CategoryGroup(
         categoryName: catName,
         totalAmount: catCredit - catDebit,
         totalCredit: catCredit,
         totalDebit: catDebit,
         merchants: subGroups,
       ));
    });

    // Process Uncategorized
    uncategorizedMap.forEach((merchName, txns) {
       GroupedTransaction gt = _createGroup(merchName, txns);
       layout.add(gt);
       allFlatGroups.add(gt);
       totalCredit += gt.totalCredit;
       totalDebit += gt.totalDebit;
    });

    // Sort Top Level (Categories mixed with Uncategorized Merchants)
    // We sort by latest transaction date in that block
    layout.sort((a, b) {
       // 1. Priority: Categories First
       bool aIsCategory = a is CategoryGroup;
       bool bIsCategory = b is CategoryGroup;
       if (aIsCategory && !bIsCategory) return -1;
       if (!aIsCategory && bIsCategory) return 1;

       // 2. Secondary: Date Descending
       DateTime dateA;
       if (a is CategoryGroup) {
         // Latest date in the category
         dateA = a.merchants.first.transactions.first.date;
       } else {
         dateA = (a as GroupedTransaction).transactions.first.date;
       }
       
       DateTime dateB;
       if (b is CategoryGroup) {
         dateB = b.merchants.first.transactions.first.date;
       } else {
         dateB = (b as GroupedTransaction).transactions.first.date;
       }
       return dateB.compareTo(dateA);
    });

    setState(() {
      _displayList = layout;
      _flatGroupedTransactions = allFlatGroups;
      _monthTotalCredit = totalCredit;
      _monthTotalDebit = totalDebit;
      // _lastMonthlyTransaction is already set
    });
  }

  GroupedTransaction _createGroup(String colName, List<Transaction> txns) {
      double credential = 0;
      double deb = 0;
      for(var t in txns) {
         if (t.cleanSender == "Manual Balance") continue;
         if (t.isCredit) credential += t.amount;
         else deb += t.amount;
      }
      return GroupedTransaction(
        sender: colName,
        totalAmount: credential - deb,
        totalCredit: credential,
        totalDebit: deb,
        transactions: txns,
      );
  }

  void _changeMonth(int offset) {
    setState(() {
      _selectedDate = DateTime(_selectedDate.year, _selectedDate.month + offset);
    });
    _filterByMonth();
  }

  Future<void> _generatePdfAndOpen() async {
    final pdf = pw.Document();
    final monthName = DateFormat('MMMM yyyy').format(_selectedDate);
    final currencyFormat = NumberFormat.currency(symbol: "INR ", locale: "en_IN");

    // Flatten all filtered transactions for the table
    List<Transaction> transactionsForPdf = [];
    for (var group in _flatGroupedTransactions) {
      transactionsForPdf.addAll(group.transactions);
    }
    // Sort by Date Descending
    transactionsForPdf.sort((a, b) => b.date.compareTo(a.date));

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Expense Report', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
                  pw.Text(monthName, style: const pw.TextStyle(fontSize: 18, color: PdfColors.grey700)),
                ],
              )
            ),
            pw.SizedBox(height: 20),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
              children: [
                pw.Column(
                  children: [
                    pw.Text('Total Income', style: const pw.TextStyle(color: PdfColors.green)),
                    pw.Text(currencyFormat.format(_monthTotalCredit), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.green)),
                  ],
                ),
                pw.Column(
                  children: [
                    pw.Text('Total Expense', style: const pw.TextStyle(color: PdfColors.red)),
                    pw.Text(currencyFormat.format(_monthTotalDebit), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.red)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 30),
            pw.Table.fromTextArray(
              context: context,
              headers: ['Date', 'Entity', 'Type', 'Amount'],
              data: transactionsForPdf.map((t) {
                return [
                  DateFormat('dd-MMM-yyyy').format(t.date),
                  t.cleanSender,
                  t.isCredit ? 'Credit' : 'Debit',
                  currencyFormat.format(t.amount),
                ];
              }).toList(),
              border: pw.TableBorder.all(color: PdfColors.grey300),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.deepPurple),
              cellAlignment: pw.Alignment.centerLeft,
              cellAlignments: {
                2: pw.Alignment.center,
                3: pw.Alignment.centerRight,
              },
            ),
          ];
        },
      ),
    );

    try {
      final output = await getTemporaryDirectory();
      // Filename like: Report_December_2025.pdf
      final file = File("${output.path}/Report_${monthName.replaceAll(' ', '_')}.pdf");
      await file.writeAsBytes(await pdf.save());
      
      // Open the file
      await OpenFilex.open(file.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating PDF: $e')),
        );
      }
    }
  }

  int _currentTabIndex = 0;
  String _analysisView = 'Monthly'; // 'Weekly', 'Monthly'
  String _analysisFilter = 'All'; // 'All', 'Credit', 'Debit'
  int _selectedChartIndex = -1;

  Future<void> _showExportDialog() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Export Data", style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text("Save or send your transaction history.", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.ios_share, color: Colors.blue),
              ),
              title: const Text("Share / Email"),
              subtitle: const Text("Send via Email, WhatsApp, etc."),
              onTap: () async {
                Navigator.pop(context);
                final file = await _localFile;
                if (await file.exists()) {
                   await Share.shareXFiles([XFile(file.path)], text: 'Expense Tracker Backup');
                } else {
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No data file found.")));
                }
              },
            ),
             const SizedBox(height: 16),
             ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.save_alt, color: Colors.green),
              ),
              title: const Text("Save to Phone"),
              subtitle: const Text("Save copy to local storage"),
              onTap: () async {
                 Navigator.pop(context);
                 final file = await _localFile;
                 if (await file.exists()) {
                    // Sharing is the modern standard for saving to Files on Android 10+
                    await Share.shareXFiles([XFile(file.path)], text: 'Expense Tracker Backup');
                 }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importData() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null) {
      File pickerFile = File(result.files.single.path!);
      try {
        final content = await pickerFile.readAsString();
        // Parse NDJSON
        List<Transaction> imported = [];
        final lines = content.split('\n');
        for(var line in lines) {
           if(line.trim().isNotEmpty) {
             try {
                imported.add(Transaction.fromJson(jsonDecode(line)));
             } catch(e) {
               // ignore errors
             }
           }
        }
        
        if (imported.isNotEmpty) {
           await _mergeAndSave(imported);
        } else {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No valid transactions found in file.")));
        }
      } catch (e) {
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error reading file: $e")));
      }
    }
  }

  Future<void> _mergeAndSave(List<Transaction> newTxns) async {
      Set<String> existingKeys = _allTransactions.map((t) => "${t.date.millisecondsSinceEpoch}_${t.amount}_${t.sender}").toSet();
      List<Transaction> toAdd = [];
      for(var t in newTxns) {
         String key = "${t.date.millisecondsSinceEpoch}_${t.amount}_${t.sender}";
         if(!existingKeys.contains(key)) {
            toAdd.add(t);
            existingKeys.add(key);
         }
      }
      
      if(toAdd.isNotEmpty) {
         final file = await _localFile;
         final sink = file.openWrite(mode: FileMode.append);
         for(var t in toAdd) {
           sink.writeln(jsonEncode(t.toJson()));
         }
         await sink.close();
         
         await _loadMessages(); // Reload full state
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Imported ${toAdd.length} new transactions.")));
      } else {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No new unique transactions found.")));
      }
  }

  @override

  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Text(_userName != null ? "Hello $_userName" : "Expense Tracker", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
             if (_userName != null)
               const Text("Your Expenses", style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: "Export",
            onPressed: _showExportDialog,
          ),
          IconButton(
            icon: const Icon(Icons.file_upload),
            tooltip: "Import",
            onPressed: _importData,
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: "Download PDF",
            onPressed: () {
               if (_flatGroupedTransactions.isNotEmpty) {
                 _generatePdfAndOpen();
               } else {
                 ScaffoldMessenger.of(context).showSnackBar(
                   const SnackBar(content: Text("No data to export for this month")),
                 );
               }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh",
            onPressed: () {
              setState(() {
                _isLoading = true;
              });
              _loadMessages();
            },
          )
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: Theme.of(context).brightness == Brightness.dark 
              ? [const Color(0xFF16171d), const Color(0xFF2d3436)]
              : [Colors.white, const Color(0xFFf5f7fa)]
          )
        ),
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _permissionDenied
              ? _buildPermissionView()
              : _currentTabIndex == 0 
                  ? _buildTransactionsTab()
                  : _buildAnalysisTab(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (index) {
           setState(() {
             _currentTabIndex = index;
           });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.list), label: 'Transactions'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Analysis'),
        ],
      ),
    );
  }

  Widget _buildTransactionsTab() {
    return Column(
      children: [
        _buildMonthSelector(),
        if (_lastMonthlyTransaction != null) _buildLastTransactionCard(),
        _buildSummaryCard(),
        Expanded(child: _buildGroupedList()),
      ],
    );
  }

  Widget _buildAnalysisTab() {
    // 1. Get Base Data (Filtered by Type and Time Window)
    final List<Transaction> relevantData = _getFilteredTransactionsForAnalysis();
    
    // 2. Prepare Trend Data (Bar Chart)
    final trendData = _prepareTrendData(relevantData);
    List<String> xLabels = trendData.keys.toList();
    List<double> barValues = trendData.values.toList();
    
    // Determine Selected Period for Pie Chart
    int targetIndex = _selectedChartIndex;
    if (targetIndex < 0 || targetIndex >= xLabels.length) {
      targetIndex = xLabels.length - 1; // Default to latest
    }
    String targetKey = xLabels.isNotEmpty ? xLabels[targetIndex] : "";
    
    // Filter Data for Pie Chart based on Selection
    final List<Transaction> pieData = xLabels.isEmpty ? [] : relevantData.where((t) {
       String key;
       if (_analysisView == 'Monthly') {
         key = DateFormat('MMM').format(t.date);
       } else {
         DateTime weekStart = t.date.subtract(Duration(days: t.date.weekday - 1));
         key = "${weekStart.day}/${weekStart.month}";
       }
       return key == targetKey;
    }).toList();
    
    // Determine Max Y for Bar Chart
    double maxY = barValues.isEmpty ? 100 : barValues.reduce((curr, next) => curr > next ? curr : next);
    if (maxY == 0) maxY = 100;
    maxY = maxY * 1.2;

    // 3. Prepare Category Data (Pie Chart)
    final categoryData = _prepareCategoryData(pieData);
    final totalAmount = categoryData.values.fold(0.0, (sum, item) => sum + item);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Controls
          Row(
            children: [
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Weekly', label: Text('Weekly')),
                    ButtonSegment(value: 'Monthly', label: Text('Monthly')),
                  ],
                  selected: {_analysisView},
                  onSelectionChanged: (Set<String> newSelection) {
                    setState(() {
                      _analysisView = newSelection.first;
                      _selectedChartIndex = -1;
                    });
                  },
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _analysisFilter,
                items: ['All', 'Credit', 'Debit'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                onChanged: (val) {
                   setState(() {
                     _analysisFilter = val!;
                   });
                },
              )
            ],
          ),
          const SizedBox(height: 20),
          
          // TREND CHART
          const Align(alignment: Alignment.centerLeft, child: Text("Trend", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: barValues.isEmpty 
              ? const Center(child: Text("No Data"))
              : BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: maxY,
                      barTouchData: BarTouchData(
                        enabled: true,
                        touchCallback: (FlTouchEvent event, barTouchResponse) {
                           if (!event.isInterestedForInteractions || barTouchResponse == null || barTouchResponse.spot == null) {
                             return;
                           }
                           if (event is FlTapUpEvent) { // Only update on tap up
                             setState(() {
                               _selectedChartIndex = barTouchResponse.spot!.touchedBarGroupIndex;
                             });
                           }
                        },
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) => Colors.blueGrey,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            return BarTooltipItem(
                              "${xLabels[group.x.toInt()]}\n",
                              const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              children: [
                                TextSpan(
                                  text: NumberFormat.currency(symbol: "₹", decimalDigits: 0, locale: "en_IN").format(rod.toY),
                                  style: const TextStyle(color: Colors.yellowAccent),
                                )
                              ]
                            );
                          }
                        ),
                      ),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) {
                            if (value.toInt() >= 0 && value.toInt() < xLabels.length) {
                               return Padding(
                                 padding: const EdgeInsets.only(top: 8.0),
                                 child: Text(
                                   xLabels[value.toInt()], 
                                   style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                   textAlign: TextAlign.center,
                                 ),
                               );
                            }
                            return const SizedBox.shrink();
                          },
                          reservedSize: 30,
                        ),
                      ),
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: false),
                    gridData: const FlGridData(show: false),
                    barGroups: List.generate(barValues.length, (index) {
                       return BarChartGroupData(
                         x: index,
                         barRods: [
                             BarChartRodData(
                               toY: barValues[index],
                               color: _selectedChartIndex == index || (index == xLabels.length - 1 && _selectedChartIndex == -1) 
                                   ? (_analysisFilter == 'Credit' ? Colors.green : (_analysisFilter == 'Debit' ? Colors.red : Colors.blue))
                                   : Colors.grey.withOpacity(0.5), // Highlight selected
                               width: 12,
                               borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                             )
                         ]
                       );
                    }),
                  ),
                ),
          ),

          const SizedBox(height: 30),
          
          // CATEGORY CHART
          Align(alignment: Alignment.centerLeft, child: Text("Category Distribution ${targetKey.isNotEmpty ? '($targetKey)' : ''}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          const SizedBox(height: 10),
          SizedBox(
            height: 250, // Enough for Pie + Legend
            child: categoryData.isEmpty 
             ? const Center(child: Text("No Data for Categories"))
             : Row(
               children: [
                 // Pie Chart
                 Expanded(
                   flex: 5,
                   child: PieChart(
                     PieChartData(
                       sectionsSpace: 0,
                       centerSpaceRadius: 0, 
                       sections: categoryData.entries.map((e) {
                         final double percent = (e.value / totalAmount) * 100;
                         final bool isLarge = percent > 15;
                         return PieChartSectionData(
                           color: _getCategoryColor(e.key),
                           value: e.value,
                           title: "${percent.toStringAsFixed(0)}%",
                           radius: isLarge ? 50 : 40,
                           titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                           badgeWidget: isLarge ? _Badge(e.key) : null,
                           badgePositionPercentageOffset: 1.1
                         );
                       }).toList(),
                     )
                   ),
                 ),
                 // Legend List
                 Expanded(
                   flex: 4,
                   child: ListView(
                     children: categoryData.entries.map((e) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            children: [
                              Container(width: 12, height: 12, color: _getCategoryColor(e.key)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "${e.key} (${NumberFormat.compactCurrency(symbol: '₹').format(e.value)})", 
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis
                                )
                              ),
                            ],
                          ),
                        );
                     }).toList(),
                   ),
                 ),
               ],
             ),
          )
        ],
      ),
    );
  }

  // Helper Widget for Pie Chart Badges
  Widget _Badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 2)],
      ),
      child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black87)),
    );
  }

  Color _getCategoryColor(String category) {
    // Generate deterministic color based on hash
    final int hash = category.codeUnits.fold(0, (p, c) => p + c);
    final List<Color> palette = [
      Colors.blue, Colors.red, Colors.green, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.brown, Colors.indigo
    ];
    return palette[hash % palette.length];
  }

  // 1. Centralized Method to get Raw Data for Analysis
  List<Transaction> _getFilteredTransactionsForAnalysis() {
    if (_allTransactions.isEmpty) return [];

    // Filter by Type
    List<Transaction> filtered = _allTransactions.where((t) {
      if (_analysisFilter == 'Credit') return t.isCredit;
      if (_analysisFilter == 'Debit') return !t.isCredit;
      return true;
    }).toList();

    // Sort by Date Descending (Newest first)
    filtered.sort((a, b) => b.date.compareTo(a.date));

    // Filter by Time Window
    DateTime cutoff;
    if (_analysisView == 'Monthly') {
      // Last 6 months (roughly 180 days)
      cutoff = DateTime.now().subtract(const Duration(days: 180));
    } else {
      // Last 8 weeks (56 days)
      cutoff = DateTime.now().subtract(const Duration(days: 56));
    }
    
    return filtered.where((t) => t.date.isAfter(cutoff)).toList();
  }

  // 2. Prepare Trend Data (Aggregated by Date Key)
  Map<String, double> _prepareTrendData(List<Transaction> rawData) {
    Map<String, double> grouped = {};
    
    // We need to process from Oldest to Newest for the Chart
    List<Transaction> ascending = List.from(rawData)..sort((a, b) => a.date.compareTo(b.date));

    if (_analysisView == 'Monthly') {
       for (var t in ascending) {
         String key = DateFormat('MMM').format(t.date); // Jan, Feb...
         grouped[key] = (grouped[key] ?? 0) + t.amount;
       }
    } else {
       for (var t in ascending) {
         // Weekly Labels: "dd/MM"
         DateTime weekStart = t.date.subtract(Duration(days: t.date.weekday - 1));
         String key = "${weekStart.day}/${weekStart.month}";
         grouped[key] = (grouped[key] ?? 0) + t.amount;
       }
    }
    return grouped;
  }

  // 3. Prepare Category Data (Aggregated by Category)
  Map<String, double> _prepareCategoryData(List<Transaction> rawData) {
    Map<String, double> grouped = {};
    for (var t in rawData) {
      String cat = _merchantCategories[t.cleanSender] ?? 'Uncategorized';
      grouped[cat] = (grouped[cat] ?? 0) + t.amount;
    }
    
    // Sort by Value Descending
    var entries = grouped.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    
    return Map.fromEntries(entries);
  }

  Widget _buildLastTransactionCard() {
    final t = _lastMonthlyTransaction!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Latest Transaction", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                Text(
                  "${t.cleanSender} • ${DateFormat('MMM d, h:mm a').format(t.date)}",
                  style: const TextStyle(fontSize: 12),
                  maxLines: 1, 
                  overflow: TextOverflow.ellipsis
                ),
              ],
            ),
          ),
          Text(
            NumberFormat.currency(symbol: "₹", locale: "en_IN").format(t.amount),
            style: TextStyle(
              color: t.isCredit ? Colors.green[800] : Colors.red[800],
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 60, color: Colors.grey),
          const SizedBox(height: 16),
          const Text("SMS Permission Denied"),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _loadMessages,
            child: const Text("Retry Permission"),
          )
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton.filledTonal(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _changeMonth(-1),
              ),
              Text(
                DateFormat("MMMM yyyy").format(_selectedDate),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.chevron_right),
                onPressed: _selectedDate.month == DateTime.now().month && _selectedDate.year == DateTime.now().year 
                  ? null
                  : () => _changeMonth(1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedAccount,
                    isExpanded: true,
                    icon: const Icon(Icons.account_balance_wallet),
                    items: _accounts.map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      setState(() {
                        _selectedAccount = newValue!;
                      });
                      _filterByMonth();
                    },
                  ),
                ),
                const Divider(),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _filterType,
                    isExpanded: true,
                    icon: const Icon(Icons.filter_list),
                    items: ['All', 'Credit', 'Debit'].map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      setState(() {
                        _filterType = newValue!;
                      });
                      _filterByMonth();
                    },
                  ),
                ),
              ],
            ),
            ),
          ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    // Prevent Division by zero
    double total = _monthTotalCredit + _monthTotalDebit;
    
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSummaryRow("Income", _monthTotalCredit, Colors.greenAccent),
                const SizedBox(height: 10),
                _buildSummaryRow("Expense", _monthTotalDebit, Colors.redAccent),
              ],
            ),
          ),
          if (total > 0)
          SizedBox(
            height: 70,
            width: 70,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 0,
                sections: [
                  PieChartSectionData(
                    color: Colors.greenAccent,
                    value: _monthTotalCredit <= 0 && _monthTotalDebit <= 0 ? 1 : (_monthTotalCredit > 0 ? _monthTotalCredit : 0),
                    radius: 20,
                    showTitle: false,
                  ),
                  PieChartSectionData(
                    color: Colors.redAccent,
                    value: _monthTotalDebit > 0 ? _monthTotalDebit : 0,
                    radius: 20,
                    showTitle: false,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, double amount, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(
          NumberFormat.currency(symbol: "₹", locale: "en_IN").format(amount),
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildGroupedList() {
    if (_displayList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 60, color: Colors.grey.withOpacity(0.5)),
            const SizedBox(height: 16),
            const Text("No transactions found"),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _displayList.length,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemBuilder: (context, index) {
        final item = _displayList[index];
        
        if (item is CategoryGroup) {
          return _buildCategoryTile(item);
        } else if (item is GroupedTransaction) {
          return _buildMerchantTile(item);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildCategoryTile(CategoryGroup cat) {
    return Card(
      elevation: 0,
      color: Colors.blue.withOpacity(0.05), // Distinct color for Categories
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.blue.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(12)
      ),
      child: ExpansionTile(
          shape: const Border(),
          leading: const CircleAvatar(
             child: Icon(Icons.folder_open),
          ),
          title: Text(cat.categoryName, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text("${cat.merchants.length} Merchants"),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                NumberFormat.compactCurrency(symbol: "₹").format(cat.totalCredit > 0 ? cat.totalCredit : cat.totalDebit),
                style: TextStyle(
                  color: cat.totalCredit >= cat.totalDebit ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          children: cat.merchants.map((m) => _buildMerchantTile(m, isNested: true)).toList(),
      ),
    );
  }

  Widget _buildMerchantTile(GroupedTransaction group, {bool isNested = false}) {
    return Card(
      elevation: 0,
      color: isNested ? Colors.white.withOpacity(0.5) : Theme.of(context).cardColor,
      margin: isNested ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4) : const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.grey.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(12)
      ),
      child: ExpansionTile(
        shape: const Border(),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          maxRadius: 16,
          child: Text(
            group.sender.substring(0, 1).toUpperCase(),
            style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onPrimaryContainer),
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(group.sender, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
            // TAG BUTTON 
            IconButton(
              icon: const Icon(Icons.label_outline, size: 18, color: Colors.grey),
              onPressed: () {
                _showCategoryDialog(group.sender, group.sender); // Sender is the merchant name here
              },
            ),
          ],
        ),
        subtitle: Text("${group.transactions.length} Txns", style: const TextStyle(fontSize: 10)),
        trailing: Container(
          constraints: const BoxConstraints(minWidth: 60),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                NumberFormat.compactCurrency(symbol: "₹").format(group.totalCredit > 0 ? group.totalCredit : group.totalDebit),
                style: TextStyle(
                  color: group.totalCredit >= group.totalDebit ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        children: group.transactions.map((t) => _buildTransactionItem(t)).toList(),
      ),
    );
  }

  void _showCategoryDialog(String currentGroup, String originalMerchant) {
    // If grouped by Category, originalMerchant might be different from currentGroup.
    // We want to edit the category for the Underlying Merchant(s).
    // But here we can simplified: We are assigning a category to the "Merchant".
    // If the group is already a Category (e.g. Groceries), we might want to move it?
    // Let's assume user long-presses a Merchant Group to assign it to a Category.
    // If they long-press a Category Group, it's ambiguous which merchant they mean.
    // For now, let's allow re-mapping the 'cleanSender' of the first transaction in the group?
    // Or just pass the group name if it's not a category? 
    // Optimization: Just show dialog acting on 'originalMerchant' (cleanSender).
    
    TextEditingController catController = TextEditingController();
    String? assigned = _merchantCategories[originalMerchant];
    if (assigned != null) catController.text = assigned;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Categorize '$originalMerchant'"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Group this merchant under a category:", style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              TextField(
                controller: catController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: "Category Name",
                  hintText: "e.g. Groceries",
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.category),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 12),
              const Text("Quick Select:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ["Groceries", "Fuel", "Food", "Travel", "Bills", "Shopping", "Medical", "Entertainment"].map((c) {
                  return ActionChip(
                    label: Text(c.toUpperCase(), style: const TextStyle(fontSize: 10)),
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      catController.text = c;
                    },
                  );
                }).toList(),
              )
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), 
            child: const Text("Cancel")
          ),
          FilledButton.icon(
            icon: const Icon(Icons.check),
            label: const Text("Save Category"),
            onPressed: () {
               if (catController.text.trim().isEmpty) {
                 // Remove category
                 final prefs = SharedPreferences.getInstance();
                 prefs.then((p) {
                   p.remove("cat_$originalMerchant");
                   setState(() {
                     _merchantCategories.remove(originalMerchant);
                   });
                   _filterByMonth();
                 });
               } else {
                 _saveCategory(originalMerchant, catController.text.trim());
               }
               Navigator.pop(context);
            },
          )
        ],
      ),
    );
  }

  Widget _buildTransactionItem(Transaction t) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 72, right: 16, bottom: 8),
      title: Text(
        t.body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      subtitle: Text(
        DateFormat("MMM d, h:mm a").format(t.date),
        style: const TextStyle(fontSize: 10, color: Colors.grey),
      ),
      trailing: Text(
        NumberFormat.currency(symbol: "₹", locale: "en_IN").format(t.amount),
        style: TextStyle(
          color: t.isCredit ? Colors.green : Colors.red,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
