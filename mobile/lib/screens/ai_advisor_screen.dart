import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../services/errors.dart';
import '../widgets/common.dart';

const _welcome =
    "Hi! I'm your Finverse financial assistant. Ask about your spending, savings, debt, investments, insurance, or goals. I'll use the financial information saved in your account to help answer.";

class _Msg {
  final bool fromUser;
  final String text;
  final List<String> actions;
  _Msg(this.fromUser, this.text, [this.actions = const []]);
}

class AiAdvisorScreen extends StatefulWidget {
  const AiAdvisorScreen({super.key});

  @override
  State<AiAdvisorScreen> createState() => _AiAdvisorScreenState();
}

class _AiAdvisorScreenState extends State<AiAdvisorScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  String? _conversationId;
  Map<String, dynamic>? _quota;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _loadQuota();
    try {
      _applyConversation(await context.services.ai.currentConversation());
    } catch (_) {
      _messages
        ..clear()
        ..add(_Msg(false, _welcome));
    }
    if (mounted) setState(() => _loading = false);
    _scrollToEnd();
  }

  Future<void> _loadQuota() async {
    try {
      final q = await context.services.ai.quota();
      if (mounted) setState(() => _quota = q);
    } catch (_) {}
  }

  void _applyConversation(Map<String, dynamic> data) {
    _conversationId = data['id']?.toString();
    final msgs = (data['messages'] as List? ?? []).map((m) {
      final map = Map<String, dynamic>.from(m);
      final actions = (map['actions'] as List? ?? []).map((e) => e.toString()).toList();
      return _Msg(map['role'] == 'user', map['content']?.toString() ?? '', actions);
    }).toList();
    _messages
      ..clear()
      ..addAll(msgs.isEmpty ? [_Msg(false, _welcome)] : msgs);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final question = (preset ?? _input.text).trim();
    if (question.isEmpty || _sending || _loading) return;
    setState(() {
      _messages.add(_Msg(true, question));
      _sending = true;
      _input.clear();
    });
    _scrollToEnd();
    try {
      final res = await context.services.ai.chat(question, conversationId: _conversationId);
      _conversationId = res['conversation_id']?.toString() ?? _conversationId;
      if (res['quota'] is Map) _quota = Map<String, dynamic>.from(res['quota']);
      _messages.add(_Msg(false, res['answer']?.toString() ?? '', (res['suggested_actions'] as List? ?? []).map((e) => e.toString()).toList()));
    } on ApiException catch (e) {
      final detail = e.detail;
      var text = e.message;
      if (detail is Map) {
        if (detail['quota'] is Map) _quota = Map<String, dynamic>.from(detail['quota']);
        if (detail['code'] == 'chat_rate_limited' && detail['retry_after_seconds'] != null) {
          text = '${detail['message']} Try again in ${detail['retry_after_seconds']} seconds.';
        }
      }
      _messages.add(_Msg(false, text));
    } on ServiceException catch (e) {
      _messages.add(_Msg(false, e.message));
    } catch (_) {
      _messages.add(_Msg(false, "I'm having trouble analysing that right now. Please try again."));
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToEnd();
    }
  }

  Future<void> _newChat() async {
    if (_sending) return;
    setState(() => _loading = true);
    try {
      final data = await context.services.ai.newConversation();
      _conversationId = data['id']?.toString();
      _messages
        ..clear()
        ..add(_Msg(false, _welcome));
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openHistory() async {
    List<Map<String, dynamic>> items;
    try {
      items = await context.services.ai.conversations();
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
      return;
    }
    if (!mounted) return;
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => items.isEmpty
          ? const EmptyState(icon: Icons.history, title: 'No past conversations')
          : ListView(children: [
              for (final c in items)
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(c['conversation_title']?.toString() ?? 'Conversation', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(displayDate(toDate(c['updated_at'] ?? c['created_at']))),
                  selected: c['id']?.toString() == _conversationId,
                  onTap: () => Navigator.pop(ctx, c['id']?.toString()),
                ),
            ]),
    );
    if (id == null || !mounted) return;
    setState(() => _loading = true);
    try {
      _applyConversation(await context.services.ai.conversation(id));
    } catch (e) {
      if (mounted) context.showSnack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
      _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = _quota == null ? null : toInt(_quota!['remaining']);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('AI advisor'),
          if (remaining != null)
            Text('$remaining of ${toInt(_quota!['limit'])} questions left today', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ]),
        actions: [
          IconButton(tooltip: 'History', onPressed: _openHistory, icon: const Icon(Icons.history)),
          IconButton(tooltip: 'New chat', onPressed: _newChat, icon: const Icon(Icons.add_comment_outlined)),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length + (_sending ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _messages.length) return const _Bubble(fromUser: false, child: _TypingDots());
                      final m = _messages[i];
                      final isLast = i == _messages.length - 1;
                      return Column(crossAxisAlignment: m.fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
                        _Bubble(fromUser: m.fromUser, child: SelectableText(m.text, style: TextStyle(color: m.fromUser ? theme.colorScheme.onPrimary : null, height: 1.4))),
                        if (!m.fromUser && isLast && m.actions.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Wrap(spacing: 8, runSpacing: 4, children: [
                              for (final a in m.actions) ActionChip(label: Text(a), onPressed: () => _send(a)),
                            ]),
                          ),
                      ]);
                    },
                  ),
          ),
          if (!_loading && _messages.length <= 1)
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                for (final q in const ['How am I doing this month?', 'Where can I cut spending?', 'Am I on track for retirement?', 'Is my insurance enough?'])
                  Padding(padding: const EdgeInsets.only(right: 8), child: ActionChip(label: Text(q), onPressed: () => _send(q))),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 1200,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Ask about your finances…', counterText: ''),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _sending ? null : () => _send(), icon: const Icon(Icons.send)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.fromUser, required this.child});
  final bool fromUser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: fromUser ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(fromUser ? 16 : 4),
            bottomRight: Radius.circular(fromUser ? 4 : 16),
          ),
        ),
        child: child,
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  const _TypingDots();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 40, height: 16, child: Center(child: LinearProgressIndicator(minHeight: 3)));
}
