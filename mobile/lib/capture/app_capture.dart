import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../services/services.dart';
import 'receipt_parser.dart';
import 'sms_parser.dart';

/// Native capture channel (MainActivity.kt / PaymentNotificationListener.kt).
const _channel = MethodChannel('finverse/capture');

/// Moves payment notifications from UPI apps into the review inbox.
///
/// The native listener queues them even while Finverse is closed; this drains
/// the queue when the app starts and whenever it comes back to the foreground.
class NotificationSync extends ChangeNotifier with WidgetsBindingObserver {
  NotificationSync(this.capture, {this.onAdded});

  final CaptureService capture;

  /// Called after new inbox items were added (to refresh badges).
  final VoidCallback? onAdded;

  bool get supported => Platform.isAndroid;
  bool granted = false;
  int lastAdded = 0;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    await refresh();
  }

  /// Opens Android's Notification access screen, where the user switches
  /// Finverse on. Access is re-checked when they come back.
  Future<void> openSettings() => _channel.invokeMethod('openNotificationAccess');

  Future<void> refresh() async {
    if (!supported) return;
    try {
      granted = await _channel.invokeMethod<bool>('notificationAccessGranted') ?? false;
      final rows = await _channel.invokeListMethod<Map>('drainNotifications') ?? [];
      if (rows.isNotEmpty) {
        final result = await capture.ingest([
          for (final r in rows)
            CapturedMessage(
              source: 'UPI_NOTIFICATION',
              sender: r['sender'] as String,
              body: r['body'] as String,
              receivedAt: DateTime.fromMillisecondsSinceEpoch((r['date'] as num).toInt()),
            ),
        ]);
        lastAdded = result['added'] as int;
        if (lastAdded > 0) onAdded?.call();
      }
    } on MissingPluginException {
      // Not running on the Android app (tests, other platforms).
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Handles "Share to Finverse" from other apps (screenshots and text).
class ShareCapture {
  ShareCapture(this.capture, this.navigatorKey, {this.onAdded});

  final CaptureService capture;
  final GlobalKey<NavigatorState> navigatorKey;
  final VoidCallback? onAdded;

  void init() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') await _takeShared();
    });
    // Something may have been shared before Flutter started.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeShared());
  }

  Future<void> _takeShared() async {
    final Map? item;
    try {
      item = await _channel.invokeMethod<Map>('takeShared');
    } on MissingPluginException {
      return;
    }
    if (item == null) return;
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.push(MaterialPageRoute(
      builder: (_) => SharedPaymentScreen(item: Map<String, dynamic>.from(item!), capture: capture, onAdded: onAdded),
    ));
  }
}

/// Reads text from an image on the phone (Google ML Kit, offline).
/// Lines are returned top to bottom with their on-screen height.
Future<List<OcrLine>> readImageText(String path) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    final lines = [for (final block in result.blocks) ...block.lines]
      ..sort((a, b) {
        final dy = a.boundingBox.top - b.boundingBox.top;
        // Same row (within half a line): left to right.
        return dy.abs() < a.boundingBox.height / 2 ? a.boundingBox.left.compareTo(b.boundingBox.left) : dy.sign.toInt();
      });
    return [for (final l in lines) OcrLine(l.text, l.boundingBox.height)];
  } finally {
    await recognizer.close();
  }
}

/// Shown when something is shared to Finverse: reads it, adds the payment to
/// the review inbox and says what happened.
class SharedPaymentScreen extends StatefulWidget {
  const SharedPaymentScreen({super.key, required this.item, required this.capture, this.onAdded, this.ocr = readImageText});

  final Map<String, dynamic> item;
  final CaptureService capture;
  final VoidCallback? onAdded;
  final Future<List<OcrLine>> Function(String path) ocr;

  @override
  State<SharedPaymentScreen> createState() => _SharedPaymentScreenState();
}

enum _Outcome { working, added, autoAdded, autoIgnored, duplicate, notFound, error }

class _SharedPaymentScreenState extends State<SharedPaymentScreen> {
  _Outcome _outcome = _Outcome.working;
  ParsedSms? _parsed;
  String _readText = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _process();
  }

  Future<void> _process() async {
    try {
      final item = widget.item;
      final CapturedMessage message;
      if (item['type'] == 'image') {
        final lines = await widget.ocr(item['path'] as String);
        _readText = lines.map((l) => l.text).join('\n');
        final parsed = ReceiptParser.parse(lines);
        if (parsed == null) return _finish(_Outcome.notFound);
        _parsed = parsed;
        message = CapturedMessage(source: 'SHARE', sender: 'SHARE', body: _readText, receivedAt: DateTime.now(), parsed: parsed);
      } else if (item['type'] == 'text') {
        _readText = item['text'] as String;
        // Usually a forwarded bank SMS or payment message; else a receipt's text.
        final parsed = SmsParser.parse('SHARE', _readText, fromPaymentApp: true) ?? ReceiptParser.parse(_readText.split('\n').map((t) => OcrLine(t, 1)).toList());
        if (parsed == null) return _finish(_Outcome.notFound);
        _parsed = parsed;
        message = CapturedMessage(source: 'SHARE', sender: 'SHARE', body: _readText, receivedAt: DateTime.now(), parsed: parsed);
      } else {
        _error = 'The shared image could not be opened. Try taking a screenshot of the payment screen and sharing that.';
        return _finish(_Outcome.error);
      }
      final result = await widget.capture.ingest([message]);
      if ((result['added'] as int) > 0) {
        widget.onAdded?.call();
        return _finish(_Outcome.added);
      }
      if (((result['auto_added'] as int?) ?? 0) > 0) return _finish(_Outcome.autoAdded);
      if (((result['auto_ignored'] as int?) ?? 0) > 0) return _finish(_Outcome.autoIgnored);
      _finish(_Outcome.duplicate);
    } on PlatformException catch (e) {
      // Native errors (e.g. ML Kit) carry a Java stack trace; don't show it.
      debugPrint('Share capture failed: $e');
      _error = 'This image could not be read. Try taking a screenshot of the payment screen and sharing that.';
      _finish(_Outcome.error);
    } catch (e) {
      _error = e.toString();
      _finish(_Outcome.error);
    }
  }

  void _finish(_Outcome outcome) {
    if (mounted) setState(() => _outcome = outcome);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _parsed;
    final (IconData icon, String title, String message) = switch (_outcome) {
      _Outcome.working => (Icons.document_scanner_outlined, 'Reading…', 'Finding the payment on this phone. Nothing is uploaded.'),
      _Outcome.added => (
          Icons.check_circle_outline,
          'Added to your review inbox',
          '${p!.type == 'INCOME' ? 'Received' : 'Paid'} ${_amount(p.amount)}${p.merchant == null ? '' : ' ${p.type == 'INCOME' ? 'from' : 'to'} ${p.merchant}'}'
              '\nCheck it and swipe right to add it to Money.',
        ),
      _Outcome.autoAdded => (Icons.auto_awesome, 'Added to Money', 'It matched one of your Auto-categorise rules, so it was added straight away.'),
      _Outcome.autoIgnored => (Icons.visibility_off_outlined, 'Ignored', 'One of your Auto-categorise rules says to ignore payments like this.'),
      _Outcome.duplicate => (Icons.done_all, 'Already captured', 'This payment is already in your inbox or in Money.'),
      _Outcome.notFound => (Icons.search_off, 'No payment found', 'This doesn\'t look like a payment receipt. Try a screenshot of the payment success screen.'),
      _Outcome.error => (Icons.error_outline, 'Could not read this', _error ?? ''),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Add to Finverse')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 24),
        if (_outcome == _Outcome.working)
          const Center(child: CircularProgressIndicator())
        else
          Icon(icon, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        if (_outcome != _Outcome.working)
          FilledButton(onPressed: () => Navigator.pop(context, _outcome == _Outcome.added), child: const Text('Done')),
        if (_readText.isNotEmpty && _outcome != _Outcome.working) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Text that was read'),
            children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(_readText))],
          ),
        ],
      ]),
    );
  }

  String _amount(double v) => context.read<AppState>().money.format(v);
}
