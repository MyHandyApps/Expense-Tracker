import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        duration: const Duration(milliseconds: 1500), vsync: this
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    
    _controller.forward();
    
    // Auto navigate after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacement(
          context, 
          MaterialPageRoute(builder: (context) => const HomePage())
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: Theme.of(context).brightness == Brightness.dark 
                ? [const Color(0xFF16171d), const Color(0xFF2d3436)] // Deep Dark
                : [Colors.white, const Color(0xFFeef2f3)] // Light Ambient
          )
        ),
        child: FadeTransition(
            opacity: _fadeAnimation,
            child: const ReleaseNotesBody(),
        ),
      ),
    );
  }
}

class ReleaseNotesPage extends StatelessWidget {
  const ReleaseNotesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Release Notes"),
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: Theme.of(context).brightness == Brightness.dark 
                ? [const Color(0xFF16171d), const Color(0xFF2d3436)] 
                : [Colors.white, const Color(0xFFeef2f3)]
          )
        ),
        child: const SafeArea(
          child: ReleaseNotesBody(isPage: true),
        ),
      ),
    );
  }
}

class ReleaseNotesBody extends StatelessWidget {
  final bool isPage;
  const ReleaseNotesBody({super.key, this.isPage = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 2),
          // Logo / Title area
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.account_balance_wallet, 
              size: 48, 
              color: Theme.of(context).colorScheme.primary
            ),
          ),
          const SizedBox(height: 24),
          Text(
            "Expense Tracker",
            style: GoogleFonts.outfit(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          Text(
            "Ambient Financial Awareness",
            style: GoogleFonts.outfit(
              fontSize: 16,
              color: Colors.grey,
              fontWeight: FontWeight.w500
            ),
          ),
          const Spacer(flex: 1),
          
          if (!isPage)
             const SizedBox(height: 100), // Filler to balance layout if not showing user greeting

          // Release Notes / Features
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.new_releases, size: 20, color: Theme.of(context).colorScheme.secondary),
                    const SizedBox(width: 8),
                    const Text("What this app does:", style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 12),
                _buildFeatureRow(Icons.sms, "Auto-reads bank SMS to track expenses"),
                _buildFeatureRow(Icons.pie_chart, "Visualizes spending with charts"),
                _buildFeatureRow(Icons.security, "Data stays local on your device"),
                _buildFeatureRow(Icons.ios_share, "Export/Import your data anytime"),
              ],
            ),
          ),

          const Spacer(flex: 3),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}

