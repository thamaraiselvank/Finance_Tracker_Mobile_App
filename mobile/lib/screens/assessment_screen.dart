import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

typedef _Opts = List<(String, String)>;

const _incomeSources = <(String, String)>[
  ('salary', 'Salary'),
  ('self_employed', 'Self-employed'),
  ('business', 'Business'),
  ('freelance', 'Freelance / gig'),
  ('investment', 'Interest / dividends'),
  ('rental', 'Rent'),
  ('pension', 'Pension'),
  ('other', 'Other'),
];
const _investmentTypes = <(String, String)>[
  ('cash_deposit', 'Cash / deposits'),
  ('stocks', 'Stocks'),
  ('mutual_funds', 'Mutual funds'),
  ('bonds', 'Bonds'),
  ('gold', 'Gold'),
  ('property', 'Property'),
  ('retirement', 'Retirement savings'),
  ('crypto', 'Crypto'),
  ('other', 'Other'),
];

/// 15-question financial check-up with AI-generated next steps.
class AssessmentScreen extends StatefulWidget {
  const AssessmentScreen({super.key});

  @override
  State<AssessmentScreen> createState() => _AssessmentScreenState();
}

class _AssessmentScreenState extends State<AssessmentScreen> {
  int _section = 0;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _result;

  final _a = <String, dynamic>{
    'income_sources': <String>[],
    'investment_types': <String>[],
    'gold_share': 'not_applicable',
  };
  final _income = TextEditingController();
  final _essentials = TextEditingController();
  final _savings = TextEditingController();
  final _debtOutstanding = TextEditingController();
  final _debtPayment = TextEditingController();

  static const _titles = [
    'Income & work',
    'Spending & savings',
    'Debt & commitments',
    'Protection & planning',
    'Investments & goals',
  ];

  @override
  void dispose() {
    for (final c in [
      _income,
      _essentials,
      _savings,
      _debtOutstanding,
      _debtPayment,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(String key, dynamic value) => setState(() {
    _a[key] = value;
    _error = null;
  });

  bool _filled(TextEditingController c, {bool positive = false}) {
    final n = double.tryParse(c.text.trim());
    return n != null && (positive ? n > 0 : n >= 0);
  }

  bool get _sectionComplete => switch (_section) {
    0 =>
      (_a['income_sources'] as List).isNotEmpty &&
          _filled(_income) &&
          _a['income_stability'] != null,
    1 =>
      _filled(_essentials, positive: true) &&
          _a['month_end_pattern'] != null &&
          _filled(_savings),
    2 =>
      _a['debt_status'] != null &&
          (_a['debt_status'] != 'yes' ||
              (_filled(_debtOutstanding) &&
                  _filled(_debtPayment) &&
                  _a['debt_payment_pattern'] != null)) &&
          (_a['debt_status'] != 'no' ||
              (_a['upcoming_large_expense'] != null &&
                  _a['unexpected_expense_plan'] != null)),
    3 =>
      _a['health_cover'] != null &&
          _a['has_dependents'] != null &&
          (_a['has_dependents'] == false || _a['term_cover'] != null) &&
          _a['planning_confidence'] != null,
    _ =>
      _a['market_reaction'] != null &&
          _a['goal_priority'] != null &&
          _a['goal_horizon'] != null &&
          (!(_a['investment_types'] as List).contains('gold') ||
              _a['gold_share'] != 'not_applicable'),
  };

  Future<void> _next() async {
    if (!_sectionComplete) {
      setState(
        () => _error = 'Please answer each question. Choose "Not sure" if you don\'t know.',
      );
      return;
    }
    if (_section < 4) {
      setState(() => _section++);
      return;
    }
    setState(() => _busy = true);
    final debt = _a['debt_status'];
    final answers = {
      ..._a,
      'monthly_net_income': double.parse(_income.text),
      'essential_monthly_spending': double.parse(_essentials.text),
      'liquid_savings': double.parse(_savings.text),
      'term_cover': _a['has_dependents'] == true
          ? _a['term_cover']
          : 'not_applicable',
      if (debt == 'yes') ...{
        'debt_outstanding': double.parse(_debtOutstanding.text),
        'monthly_debt_payment': double.parse(_debtPayment.text),
      } else ...{
        'debt_outstanding': null,
        'monthly_debt_payment': null,
        'debt_payment_pattern': null,
      },
      if (debt != 'no') ...{
        'upcoming_large_expense': null,
        'unexpected_expense_plan': null,
      },
    };
    try {
      final res = await context.services.ai.financialAssessment(answers);
      if (mounted) setState(() => _result = res);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_result != null) {
      return _ResultView(
        result: _result!,
        onRestart: () => setState(() {
          _result = null;
          _section = 0;
        }),
      );
    }
    final theme = Theme.of(context);
    final symbol = context.read<AppState>().money.symbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Financial check-up')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Section ${_section + 1} of 5',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            _titles[_section],
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ProgressBar(value: (_section + 1) / 5),
          const SizedBox(height: 8),
          Text(
            'Estimates are fine. Your answers and score are sent to the AI – not your transactions, account numbers or name.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          ..._questions(symbol),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (_section > 0) ...[
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: _busy ? null : () => setState(() => _section--),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: SaveButton(
                  busy: _busy,
                  onPressed: _next,
                  label: _section == 4 ? 'See my results' : 'Next',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _questions(String symbol) => switch (_section) {
    0 => [
      _q(
        '1. What are your income sources?',
        _multi('income_sources', _incomeSources),
      ),
      _q(
        '2. Typical monthly take-home income',
        _number(_income, symbol, 'Enter 0 if you have no regular income'),
      ),
      _q(
        '3. How predictable is your income?',
        _single('income_stability', [
          ('regular', 'Mostly regular'),
          ('mostly_regular', 'Some variation'),
          ('variable', 'Varies significantly'),
          ('seasonal', 'Seasonal or irregular'),
        ]),
      ),
    ],
    1 => [
      _q(
        '4. Monthly spending on essentials',
        _number(
          _essentials,
          symbol,
          'Housing, food, utilities, transport, healthcare',
        ),
      ),
      _q(
        '5. What usually happens by month end?',
        _single('month_end_pattern', [
          ('save_regularly', 'I usually save some'),
          ('save_sometimes', 'I save in some months'),
          ('break_even', 'I mostly break even'),
          ('withdraw_or_borrow', 'I use savings or credit'),
        ]),
      ),
      _q(
        '6. Savings you can access quickly (without selling investments)',
        _number(_savings, symbol, null),
      ),
    ],
    2 => [
      _q(
        '7. Do you have outstanding debt?',
        _single('debt_status', [
          ('yes', 'Yes'),
          ('no', 'No'),
          ('not_sure', "I'm not sure"),
        ]),
      ),
      if (_a['debt_status'] == 'yes') ...[
        _q(
          '8. Total you still owe',
          _number(
            _debtOutstanding,
            symbol,
            'Credit cards, personal, vehicle, education, home loans',
          ),
        ),
        _q(
          '9. Monthly repayments, and how are they going?',
          Column(
            children: [
              _number(_debtPayment, symbol, null),
              _single('debt_payment_pattern', [
                ('on_time', 'I pay on time'),
                ('sometimes_late', 'Sometimes late'),
                ('missed_recently', 'I missed a recent payment'),
              ]),
            ],
          ),
        ),
      ],
      if (_a['debt_status'] == 'no') ...[
        _q(
          '8. Any large expenses expected in the next 12 months?',
          _single('upcoming_large_expense', [
            ('yes', 'Yes'),
            ('no', 'No'),
            ('not_sure', 'Not sure'),
          ]),
        ),
        _q(
          '9. How would you cover an unexpected expense?',
          _single('unexpected_expense_plan', [
            ('savings', 'Accessible savings'),
            ('monthly_cashflow', 'Current income'),
            ('borrow', 'I may need to borrow'),
            ('not_sure', 'Not sure'),
          ]),
        ),
      ],
    ],
    3 => [
      _q(
        '10. Do you have health insurance?',
        _single('health_cover', [
          ('personal', 'A personal policy'),
          ('employer', 'Employer cover only'),
          ('both', 'Personal and employer'),
          ('none', 'No cover'),
          ('not_sure', "I'm not sure"),
        ]),
      ),
      _q(
        '11. Does anyone depend on your income?',
        _single(
          'has_dependents',
          [
            (true, 'Yes'),
            (false, 'No'),
          ].map((e) => (e.$1.toString(), e.$2)).toList(),
          mapValue: (v) => v == 'true',
        ),
      ),
      if (_a['has_dependents'] == true)
        _q(
          'Do you have term / life cover for them?',
          _single('term_cover', [
            ('adequate', 'Yes, I think it is adequate'),
            ('some', 'I have some cover'),
            ('none', 'No cover'),
            ('not_sure', "I'm not sure"),
          ]),
        ),
      _q(
        '12. How confident are you tracking bill, insurance and tax dates?',
        _single('planning_confidence', [
          ('confident', 'I keep track of them'),
          ('somewhat', 'I track some'),
          ('need_help', 'I could use reminders'),
          ('not_sure', 'Not sure'),
        ]),
      ),
    ],
    _ => [
      _q(
        '13. Which investments do you have?',
        _multi(
          'investment_types',
          _investmentTypes,
          onChanged: (list) {
            if (!list.contains('gold')) {
              _a['gold_share'] = 'not_applicable';
            } else if (_a['gold_share'] == 'not_applicable') {
              _a['gold_share'] = 'not_sure';
            }
          },
        ),
      ),
      if ((_a['investment_types'] as List).contains('gold'))
        _q(
          'About what share of your investments is gold?',
          _single('gold_share', [
            ('none', 'Very little'),
            ('under_10', 'Under 10%'),
            ('10_to_25', '10–25%'),
            ('26_to_50', '26–50%'),
            ('over_50', 'Over 50%'),
            ('not_sure', 'Not sure'),
          ]),
        ),
      _q(
        '14. If investments fell 20%, what would you do?',
        _single('market_reaction', [
          ('sell', 'Sell to avoid further loss'),
          ('wait', 'Wait and review my plan'),
          ('invest_more', 'Invest more if my plan allowed'),
          ('not_sure', "I'm not sure"),
        ]),
      ),
      _q(
        '15. Your main goal next',
        Column(
          children: [
            DropdownInput<String>(
              label: 'Goal',
              value: _a['goal_priority'],
              items: const {
                'emergency_fund': 'Build emergency savings',
                'debt_repayment': 'Repay debt',
                'home': 'Buy a home',
                'education': 'Education',
                'retirement': 'Retirement',
                'wealth_building': 'Build long-term wealth',
                'family': 'Family needs',
                'other': 'Other',
              },
              onChanged: (v) => _set('goal_priority', v),
            ),
            DropdownInput<String>(
              label: 'When?',
              value: _a['goal_horizon'],
              items: const {
                'under_1_year': 'Within a year',
                '1_to_3_years': '1–3 years',
                '3_to_10_years': '3–10 years',
                'over_10_years': 'Over 10 years',
                'not_sure': 'Not sure yet',
              },
              onChanged: (v) => _set('goal_horizon', v),
            ),
          ],
        ),
      ),
    ],
  };

  Widget _q(String title, Widget body) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        body,
      ],
    ),
  );

  Widget _single(
    String key,
    _Opts options, {
    dynamic Function(String)? mapValue,
  }) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final (value, label) in options)
        ChoiceChip(
          label: Text(label),
          selected: (mapValue != null ? mapValue(value) : value) == _a[key],
          onSelected: (_) =>
              _set(key, mapValue != null ? mapValue(value) : value),
        ),
    ],
  );

  Widget _multi(
    String key,
    _Opts options, {
    void Function(List<String>)? onChanged,
  }) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final (value, label) in options)
        FilterChip(
          label: Text(label),
          selected: (_a[key] as List<String>).contains(value),
          onSelected: (on) {
            final list = List<String>.from(_a[key] as List<String>);
            on ? list.add(value) : list.remove(value);
            onChanged?.call(list);
            _set(key, list);
          },
        ),
    ],
  );

  Widget _number(TextEditingController c, String symbol, String? hint) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: c,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                prefixText: '$symbol ',
                hintText: 'Enter an estimate',
                helperText: hint,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            AmountWords(
              controller: c,
              currency: currencyForSymbol(symbol) ?? 'INR',
            ),
          ],
        ),
      );
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.onRestart});
  final Map<String, dynamic> result;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = toInt(result['score']);
    final color = score >= 70
        ? AppColors.income
        : (score >= 45 ? AppColors.warning : AppColors.expense);
    final pillars = Map<String, dynamic>.from(result['pillar_scores'] ?? {});
    final strengths = (result['strengths'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    final recs = (result['recommendations'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your results'),
        actions: [
          TextButton(onPressed: onRestart, child: const Text('Retake')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  SizedBox(
                    width: 86,
                    height: 86,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: score / 100,
                            strokeWidth: 9,
                            color: color,
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                        Text(
                          '$score',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result['rating']?.toString() ?? '',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                        Text(
                          'Data confidence: ${result['data_confidence'] ?? '—'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(result['summary']?.toString() ?? ''),
          if (pillars.isNotEmpty) ...[
            const SectionHeader('Score by area'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    for (final e in pillars.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text(humanize(e.key))),
                                Text('${toInt(e.value)}'),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ProgressBar(value: toInt(e.value) / 100),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (strengths.isNotEmpty) ...[
            const SectionHeader('What you are doing well'),
            ...strengths.map(
              (s) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.check_circle,
                  color: AppColors.income,
                ),
                title: Text(s),
              ),
            ),
          ],
          if (recs.isNotEmpty) ...[
            const SectionHeader('Next steps'),
            for (final r in recs)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Chip(
                            label: Text(humanize(r['priority']?.toString())),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              r['area']?.toString() ?? '',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        r['title']?.toString() ?? '',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(r['why']?.toString() ?? ''),
                      const SizedBox(height: 8),
                      for (final a in (r['actions'] as List? ?? []))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('•  $a'),
                        ),
                      if (r['progress_check'] != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Check: ${r['progress_check']}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
          if (result['disclaimer'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                result['disclaimer'].toString(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
