import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<String> _categories = [];
  Map<String, double> _limits = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load Categories
    List<String>? catList = prefs.getStringList('user_categories');
    if (catList == null || catList.isEmpty) {
      // Default fallback if never set (though HomePage likely handles this, 
      // we want consistency if user comes straight here)
      catList = ["Groceries", "Fuel", "Food", "Travel", "Bills", "Shopping", "Medical", "Entertainment"];
      // Save default immediately so we have a base
      await prefs.setStringList('user_categories', catList);
    }

    // Load Limits
    Map<String, double> loadedLimits = {};
    for (String cat in catList) {
       double? val = prefs.getDouble("limit_$cat");
       if (val != null) loadedLimits[cat] = val;
    }

    setState(() {
      _categories = catList!;
      _limits = loadedLimits;
      _isLoading = false;
    });
  }

  Future<void> _addCategory(String name) async {
    if (name.trim().isEmpty) return;
    String clean = name.trim();
    if (_categories.contains(clean)) return;

    setState(() {
      _categories.add(clean);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('user_categories', _categories);
  }

  Future<void> _removeCategory(String name) async {
    setState(() {
      _categories.remove(name);
      _limits.remove(name); // Remove associated limit
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('user_categories', _categories);
    await prefs.remove("limit_$name");
  }

  Future<void> _updateLimit(String category, String value) async {
    double? limit = double.tryParse(value);
    final prefs = await SharedPreferences.getInstance();
    if (limit != null && limit > 0) {
      setState(() {
        _limits[category] = limit;
      });
      await prefs.setDouble("limit_$category", limit);
    } else {
      // If cleared or invalid, remove limit
      setState(() {
        _limits.remove(category);
      });
      await prefs.remove("limit_$category");
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Settings"),
          bottom: const TabBar(
            tabs: [
              Tab(text: "Manage Categories"),
              Tab(text: "Category Limits"),
            ],
          ),
        ),
        body: _isLoading 
            ? const Center(child: CircularProgressIndicator()) 
            : TabBarView(
                children: [
                  _buildManageCategories(),
                  _buildSetLimits(),
                ],
              ),
      ),
    );
  }

  Widget _buildManageCategories() {
    TextEditingController addController = TextEditingController();
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: addController,
                  decoration: const InputDecoration(
                    labelText: "New Category",
                    hintText: "Enter name",
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: () {
                   _addCategory(addController.text);
                   addController.clear();
                },
                child: const Text("Add"),
              )
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            itemCount: _categories.length,
            itemBuilder: (context, index) {
              final cat = _categories[index];
              return ListTile(
                leading: const Icon(Icons.label),
                title: Text(cat),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.grey),
                  onPressed: () => _confirmDelete(cat),
                ),
              );
            },
          ),
        )
      ],
    );
  }

  Future<void> _confirmDelete(String cat) async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Delete '$cat'?"),
        content: const Text("This will remove it from the selection list. Existing transactions with this category will remain, but you won't be able to select it for new ones."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Delete")),
        ],
      )
    );
    if (confirm == true) {
      _removeCategory(cat);
    }
  }

  Widget _buildSetLimits() {
    return ListView.builder(
      itemCount: _categories.length,
      padding: const EdgeInsets.all(16),
      itemBuilder: (context, index) {
        final cat = _categories[index];
        final limit = _limits[cat];
        final controller = TextEditingController(text: limit != null ? limit.toStringAsFixed(0) : "");

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(cat, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Limit",
                      prefixText: "₹",
                      isDense: true,
                    ),
                    onChanged: (val) => _updateLimit(cat, val),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }
}
