import 'package:material_ui/material_ui.dart';

const _topics = [
  ('Money and transactions', 'Record income, spending, accounts and monthly budgets.', 'Add one recent income or expense, or import a statement and review it before saving.'),
  ('Goals', 'Track a future target, how much you have set aside, and the date you hope to reach it.', 'Choose a name, target amount, current savings and a target date. A goal is a plan, not a guarantee.'),
  ('Wealth and net worth', 'See the value of things you own alongside debts you owe.', 'Add an account or asset. Net worth = total assets − total liabilities.'),
  ('Debts', 'Track balances, interest rates, monthly payments and payoff plans.', 'Enter the current balance and rate from your loan statement, then compare payoff strategies.'),
  ('Insurance', 'Keep policy types, cover amounts, premiums and renewal dates together.', 'Add the details shown on your policy documents.'),
  ('Bills & recurring', 'See what is due soon – rent, EMIs, subscriptions, salary.', 'Add each regular payment once; mark it paid when it happens.'),
  ('Calculators', 'Explore estimates for loans, returns and retirement.', 'Try sample values first. Results depend on the assumptions you enter.'),
  ('AI advisor', 'Ask questions about the financial information you have saved.', 'Try: "How much did I spend last month?" or "How is my goal progressing?"'),
];

const _terms = [
  ('Asset', 'Something you own that has financial value, such as a bank balance, investment or property.'),
  ('Liability', 'Money you owe, such as a loan or credit-card balance.'),
  ('Net worth', 'The value of your assets minus the value of your liabilities.'),
  ('Allocation', 'How your assets are divided among types such as cash, funds or property.'),
  ('Cash flow', 'Money coming in compared with money going out during a period.'),
  ('Savings rate', 'The share of your income you keep after spending. (Income − expenses) ÷ income.'),
  ('Emergency fund', 'Easy-to-access savings for surprises – commonly 3 to 6 months of expenses.'),
  ('Budget', 'A spending limit you set for a category and month. It is a planning guide, not a bank restriction.'),
  ('Premium', 'The amount paid to keep an insurance policy active.'),
  ('Sum insured', 'The maximum cover stated for an insurance policy, subject to its terms.'),
  ('EMI', 'A fixed monthly loan payment that includes principal and interest.'),
  ('SIP', 'Investing a set amount at regular intervals. Returns are not guaranteed.'),
  ('CAGR', 'A smoothed yearly growth rate between a starting and ending value.'),
  ('XIRR', 'A yearly return estimate that accounts for investments made on different dates.'),
  ('SWP', 'Withdrawing a chosen amount from an investment regularly.'),
  ('FIRE', 'Financial Independence, Retire Early – planning based on expenses, savings and assumptions.'),
  ('Old vs new tax regime', 'India offers two ways to calculate income tax. The old one allows more deductions (80C, 80D…); the new one has lower rates but fewer deductions.'),
];

class LearnScreen extends StatefulWidget {
  const LearnScreen({super.key});

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final terms = _terms.where((t) => '${t.$1} ${t.$2}'.toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Learn')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Money basics, in plain language', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text("You don't need investing experience. Start with what you know and come back here whenever you need.",
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 16),
        Card(
          child: Column(children: [
            for (final (title, what, first) in _topics)
              ExpansionTile(
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(what),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.centerLeft,
                children: [Text('First step: $first')],
              ),
          ]),
        ),
        const SizedBox(height: 20),
        Text('Glossary', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(decoration: const InputDecoration(hintText: 'Search terms', prefixIcon: Icon(Icons.search), isDense: true), onChanged: (v) => setState(() => _query = v)),
        const SizedBox(height: 8),
        for (final (term, def) in terms)
          ListTile(contentPadding: EdgeInsets.zero, title: Text(term, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(def)),
      ]),
    );
  }
}
