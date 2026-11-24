import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TenantRentCollectionPage extends StatefulWidget {
  final Map<String, dynamic>? tenantProfile;
  const TenantRentCollectionPage({super.key, required this.tenantProfile});

  @override
  State<TenantRentCollectionPage> createState() => _TenantRentCollectionPageState();
}

class _TenantRentCollectionPageState extends State<TenantRentCollectionPage> {
  final _amountController = TextEditingController();
  String _method = 'mpesa';
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _history = [];

  double get _monthlyRent {
    final unit = widget.tenantProfile?['units'];
    if (unit is! Map) return 0;
    return double.tryParse((unit['monthly_rent'] ?? unit['rent'] ?? '0').toString()) ?? 0;
  }

  @override
  void initState() {
    super.initState();
    if (_monthlyRent > 0) _amountController.text = _monthlyRent.toStringAsFixed(0);
    _loadHistory();
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final rows = await Supabase.instance.client
          .from('rent_payment_records')
          .select('id,amount,currency,payment_method,status,payment_reference,provider_reference,receipt_number,rejection_reason,created_at,verified_at')
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() => _history = List<Map<String, dynamic>>.from(rows));
    } catch (e) {
      debugPrint('Rent history unavailable: $e');
    }
  }

  double get _verifiedTotal => _history.where((p) => p['status'] == 'verified').fold<double>(0, (sum, p) => sum + (double.tryParse(p['amount']?.toString() ?? '0') ?? 0));

  Future<void> _startPayment() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid rent amount.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'rent-payment-intent',
        body: {'amount': amount, 'payment_method': _method},
      );
      final data = response.data;
      if (data is! Map || data['success'] != true || data['instructions'] is! Map) {
        throw Exception(data is Map ? (data['error'] ?? 'Payment could not be started.') : 'Unexpected payment response.');
      }
      final instructions = Map<String, dynamic>.from(data['instructions'] as Map);
      final payment = Map<String, dynamic>.from(data['payment'] as Map);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Complete your rent payment', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('KSh ${amount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  if (_method == 'mpesa') ...[
                    _instruction('Payment method', instructions['type'] == 'paybill' ? 'M-Pesa Paybill' : 'M-Pesa Till'),
                    if (instructions['paybill'] != null) _instruction('Paybill number', instructions['paybill'].toString()),
                    if (instructions['till'] != null) _instruction('Till number', instructions['till'].toString()),
                    _instruction('Account / reference', (instructions['account_reference'] ?? payment['payment_reference']).toString()),
                  ] else ...[
                    _instruction('Bank', (instructions['bank_name'] ?? 'Not provided').toString()),
                    _instruction('Account name', (instructions['account_name'] ?? 'Not provided').toString()),
                    _instruction('Account number', (instructions['account_number'] ?? 'Not provided').toString()),
                    if (instructions['branch'] != null) _instruction('Branch', instructions['branch'].toString()),
                    _instruction('Transfer reference', payment['payment_reference'].toString()),
                    if (instructions['instructions'] != null) Text(instructions['instructions'].toString()),
                  ],
                  const SizedBox(height: 12),
                  Text('Reference: ${payment['payment_reference']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text('Your rent balance is updated only after the landlord/payment provider verifies that the money has arrived.', style: TextStyle(color: Colors.black54, height: 1.4)),
                  const SizedBox(height: 16),
                  SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('Done'))),
                ],
              ),
            ),
          ),
        ),
      );
      await _loadHistory();
    } on FunctionException catch (e) {
      setState(() => _error = e.details?.toString() ?? e.reasonPhrase ?? 'Payment service unavailable.');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }


  Future<void> _submitReference(String paymentId) async {
    final controller = TextEditingController();
    final reference = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Submit transaction code'),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'M-Pesa receipt / bank reference'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Submit')),
        ],
      ),
    );
    controller.dispose();
    if (reference == null || reference.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke(
        'rent-payment-submit-reference',
        body: {'payment_id': paymentId, 'transaction_reference': reference},
      );
      await _loadHistory();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaction code sent for landlord verification.')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not submit transaction code: $e')),
      );
    }
  }

  Widget _instruction(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 125, child: Text(label, style: const TextStyle(color: Colors.black54))),
      Expanded(child: SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w700))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pay Rent', style: TextStyle(fontWeight: FontWeight.bold)), actions: [
        IconButton(onPressed: _loadHistory, icon: const Icon(Icons.refresh)),
      ]),
      body: RefreshIndicator(
        onRefresh: _loadHistory,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Pay rent directly to your landlord', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Choose M-Pesa or bank transfer. JUMAA tracks the payment and displays it as paid only after verification.', style: TextStyle(color: Colors.black54, height: 1.4)),
            const SizedBox(height: 18),
            const Text('Amount (KES)', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 7),
            TextField(controller: _amountController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(prefixText: 'KSh ', hintText: 'Enter amount')),
            const SizedBox(height: 16),
            const Text('Payment method', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 7),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'mpesa', label: Text('M-Pesa'), icon: Icon(Icons.phone_android)),
                ButtonSegment(value: 'bank_transfer', label: Text('Bank'), icon: Icon(Icons.account_balance)),
              ],
              selected: {_method},
              onSelectionChanged: (v) => setState(() => _method = v.first),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: _loading ? null : _startPayment,
              icon: _loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.lock_outline),
              label: Text(_loading ? 'Preparing...' : 'Get payment instructions'),
            )),
          ]))),
          const SizedBox(height: 20),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
            const Icon(Icons.receipt_long, color: Colors.green, size: 28),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Verified rent paid', style: TextStyle(color: Colors.black54)),
              Text('KSh ${_verifiedTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ])),
          ]))),
          const SizedBox(height: 12),
          const Text('Rent payment history', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_history.isEmpty)
            const Card(child: Padding(padding: EdgeInsets.all(22), child: Text('No rent payments recorded yet.')))
          else
            ..._history.map((p) {
              final status = p['status']?.toString() ?? 'pending';
              final amount = double.tryParse(p['amount']?.toString() ?? '0') ?? 0;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(status == 'verified' ? Icons.check_circle : status == 'rejected' ? Icons.cancel : Icons.schedule, color: status == 'verified' ? Colors.green : status == 'rejected' ? Colors.red : Colors.orange),
                  title: Text('KSh ${amount.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${(p['payment_method'] ?? '').toString().toUpperCase()} • ${p['payment_reference'] ?? ''}'),
                    if (p['receipt_number'] != null) Text('Receipt: ${p['receipt_number']}'),
                    if (p['rejection_reason'] != null) Text('Reason: ${p['rejection_reason']}', style: const TextStyle(color: Colors.red)),
                  ]),
                  trailing: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(status.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    if (status == 'pending') TextButton(onPressed: () => _submitReference(p['id'].toString()), child: const Text('Submit code')),
                  ]),
                ),
              );
            }),
        ]),
      ),
    );
  }
}
