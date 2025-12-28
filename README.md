# Expense Tracker

A Flutter application to automatically track expenses by reading SMS messages.

## Features
- **Automatic Tracking**: Reads SMS for credit/debit transactions.
- **Monthly Reports**: View income and expense summaries by month.
- **Filtering**: Filter by Credit, Debit, or All transactions.
- **Reference Card**: See the latest transaction at the top for quick reference.
- **PDF Export**: Download monthly reports as PDF.
- **Smart Parsing**: Identifies merchants, handles UPI, and excludes bill reminders.

## Installation Troubleshooting

### Google Play Protect Blocked Installation
If you see a warning "Blocked by Play Protect" when installing the APK:
1. This happens because the app is **signed with a debug certificate** (not a verified Play Store certificate) and requests sensitive **SMS Permissions**.
2. Click **"More Details"** (or the arrow icon).
3. Select **"Install anyway"**.

This is normal for apps currently in development that are not yet published to the Play Store.

## Getting Started

To run this project:
1. Ensure you have Flutter installed.
2. Run `flutter pub get`.
3. Connect your Android device.
4. Run `flutter run`.
