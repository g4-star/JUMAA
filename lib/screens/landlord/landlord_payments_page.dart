import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/landlord.dart';

class LandlordPaymentsPage extends StatefulWidget {
  final Landlord landlord;
  const LandlordPaymentsPage({super.key, required this.landlord});

  @override
  State<LandlordPaymentsPage> createState() => _LandlordPaymentsPageState();
}

class _LandlordPaymentsPageState extends State<LandlordPaymentsPage> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _payments = [];

  @override
  void initState() {
    super.initState();
    _loadPayments();
  }

  Future<void> _loadPayments() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await _client.from('rent_payment_records')
          .select('id,tenant_id,property_id,unit_id,amount,payment_method,status,payment_reference,provider_reference,submitted_at,created_at')
          .eq('property_id', widget.landlord.propertyId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() { _payments = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _verify(Map<String, dynamic> payment) async {
    final ref = payment['provider_reference']?.toString() ?? '';
    if (ref.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify rent received?'),
        content: Text('Confirm that KSh ${payment['amount']} was received in the landlord\'s M-Pesa/bank account and that transaction $ref appears in the account statement. Only then mark it as paid.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm received')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _client.functions.invoke('rent-payment-reconcile', body: {
        'payment_id': payment['id'],
        'provider_reference': ref,
        'verification_note': 'Manually checked against landlord account statement.',
      });
      await _loadPayments();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rent payment verified.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Verification failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final verified = _payments.where((p) => p['status'] == 'verified').toList();
    final awaiting = _payments.where((p) => p['status'] == 'submitted' || p['status'] == 'pending').toList();
    final total = verified.fold<double>(0, (sum, p) => sum + (double.tryParse(p['amount'].toString()) ?? 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Rent collection', style: TextStyle(fontWeight: FontWeight.bold)), actions: [
        IconButton(onPressed: _loadPayments, icon: const Icon(Icons.refresh)),
      ]),
      body: _loading ? const Center(child: CircularProgressIndicator())
        : _error != null ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Could not load rent payments: $_error')))
        : RefreshIndicator(onRefresh: _loadPayments, child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(widget.landlord.propertyName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _metric('Verified', verified.length.toString(), Icons.verified, Colors.green)),
              const SizedBox(width: 8),
              Expanded(child: _metric('Awaiting', awaiting.length.toString(), Icons.pending_actions, Colors.orange)),
              const SizedBox(width: 8),
              Expanded(child: _metric('Collected', 'KSh ${total.toStringAsFixed(0)}', Icons.account_balance_wallet, Colors.indigo)),
            ]),
            const SizedBox(height: 20),
            const Text('Tenant rent payments', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (_payments.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('No rent payments have been initiated yet.')))
            else ..._payments.map((p) {
              final status = p['status'].toString();
              final amount = double.tryParse(p['amount'].toString()) ?? 0;
              final ref = p['provider_reference']?.toString() ?? '';
              return Card(margin: const EdgeInsets.only(bottom: 9), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('KSh ${amount.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
                  Chip(label: Text(status.toUpperCase())),
                ]),
                Text('${p['payment_method']} • Tenant ${p['tenant_id']}'),
                const SizedBox(height: 3),
                SelectableText('JUMAA ref: ${p['payment_reference']}'),
                if (ref.isNotEmpty) SelectableText('Transaction: $ref'),
                if (status == 'submitted' && ref.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: () => _verify(p), icon: const Icon(Icons.verified), label: const Text('Verify money received'))),
                ],
                if (status == 'pending') const Padding(padding: EdgeInsets.only(top: 6), child: Text('Waiting for tenant to submit the transaction code.', style: TextStyle(color: Colors.black54, fontSize: 12))),
              ])));
            }),
            const SizedBox(height: 12),
            const Text('Only verify after checking the actual M-Pesa or bank statement. A tenant-submitted code alone is not proof of settlement.', style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.4)),
          ])),
    );
  }

  Widget _metric(String label, String value, IconData icon, Color color) => Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 5), child: Column(children: [
    Icon(icon, color: color, size: 20),
    const SizedBox(height: 5),
    Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15), textAlign: TextAlign.center),
    Text(label, style: const TextStyle(fontSize: 10, color: Colors.black54)),
  ])));
}
