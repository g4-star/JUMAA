import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/landlord.dart';

class LandlordPaymentsPage extends StatefulWidget {
  final Landlord? landlord;
  final String? propertyId;
  final String? propertyName;
  const LandlordPaymentsPage({
    super.key,
    this.landlord,
    this.propertyId,
    this.propertyName,
  }) : assert(landlord != null || propertyId != null);

  @override
  State<LandlordPaymentsPage> createState() => _LandlordPaymentsPageState();
}

class _LandlordPaymentsPageState extends State<LandlordPaymentsPage> {
  String get _propertyId => widget.landlord?.propertyId ?? widget.propertyId ?? '';
  String get _propertyName => widget.landlord?.propertyName ?? widget.propertyName ?? 'Property';
  final _client = Supabase.instance.client;
  final _paybill = TextEditingController();
  final _till = TextEditingController();
  final _mpesaReference = TextEditingController();
  final _bankName = TextEditingController();
  final _bankAccountName = TextEditingController();
  final _bankAccountNumber = TextEditingController();
  final _bankBranch = TextEditingController();
  final _instructions = TextEditingController();
  bool _loading = true;
  bool _savingAccount = false;
  bool _accountActive = false;
  String _destinationType = 'paybill';
  String? _error;
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _charges = [];

  @override
  void initState() {
    super.initState();
    _loadPayments();
    _loadAccount();
  }

  @override
  void dispose() {
    _paybill.dispose();
    _till.dispose();
    _mpesaReference.dispose();
    _bankName.dispose();
    _bankAccountName.dispose();
    _bankAccountNumber.dispose();
    _bankBranch.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    try {
      final row = await _client.from('rent_collection_accounts')
          .select('mpesa_paybill,mpesa_till,mpesa_account_reference,bank_name,bank_account_name,bank_account_number,bank_branch,payment_instructions,is_active')
          .eq('property_id', _propertyId)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _paybill.text = row['mpesa_paybill']?.toString() ?? '';
        _destinationType = (row['mpesa_till']?.toString().isNotEmpty ?? false)
            ? 'till'
            : ((row['bank_account_number']?.toString().isNotEmpty ?? false) &&
                    (row['mpesa_paybill']?.toString().isNotEmpty ?? false) == false
                ? 'bank'
                : 'paybill');
        _till.text = row['mpesa_till']?.toString() ?? '';
        _mpesaReference.text = row['mpesa_account_reference']?.toString() ?? '';
        _bankName.text = row['bank_name']?.toString() ?? '';
        _bankAccountName.text = row['bank_account_name']?.toString() ?? '';
        _bankAccountNumber.text = row['bank_account_number']?.toString() ?? '';
        _bankBranch.text = row['bank_branch']?.toString() ?? '';
        _instructions.text = row['payment_instructions']?.toString() ?? '';
        _accountActive = row['is_active'] == true;
      });
    } catch (e) {
      debugPrint('Rent collection account could not be loaded: $e');
    }
  }

  Future<void> _saveAccount() async {
    setState(() => _savingAccount = true);
    try {
      final response = await _client.functions.invoke(
        'rent-collection-account-configure',
        body: {
          'property_id': _propertyId,
          'destination_type': _destinationType,
          'mpesa_paybill': _destinationType == 'paybill' ? _paybill.text.trim() : '',
          'mpesa_till': _destinationType == 'till' ? _till.text.trim() : '',
          'mpesa_account_reference': _mpesaReference.text.trim(),
          'bank_name': _bankName.text.trim(),
          'bank_account_name': _bankAccountName.text.trim(),
          'bank_account_number': _bankAccountNumber.text.trim(),
          'bank_branch': _bankBranch.text.trim(),
          'payment_instructions': _instructions.text.trim(),
          'is_active': _accountActive,
        },
      );
      if (response.data is Map && response.data['success'] != true) {
        throw Exception(response.data['error'] ?? 'Could not save payment details.');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(response.data['message']?.toString() ?? 'Collection account saved.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save collection account: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingAccount = false);
    }
  }

  Future<void> _loadPayments() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await _client.from('rent_payment_records')
          .select('id,tenant_id,property_id,unit_id,amount,payment_method,status,payment_reference,provider_reference,receipt_number,rejection_reason,unallocated_amount,submitted_at,created_at,verified_at')
          .eq('property_id', _propertyId)
          .order('created_at', ascending: false);
      final chargeRows = await _client.from('rent_charge_records')
          .select('id,tenant_id,period_start,due_date,amount_due,amount_paid,status')
          .eq('property_id', _propertyId)
          .order('due_date', ascending: true);
      if (!mounted) return;
      setState(() {
        _payments = List<Map<String, dynamic>>.from(rows);
        _charges = List<Map<String, dynamic>>.from(chargeRows);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _generateMonthlyCharges() async {
    final now = DateTime.now();
    final periodController = TextEditingController(text: '${now.year}-${now.month.toString().padLeft(2, '0')}');
    final dueController = TextEditingController(text: '${now.year}-${now.month.toString().padLeft(2, '0')}-05');
    final values = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generate monthly rent charges'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: periodController, decoration: const InputDecoration(labelText: 'Billing month (YYYY-MM)')),
          TextField(controller: dueController, decoration: const InputDecoration(labelText: 'Due date (YYYY-MM-DD)')),
          const SizedBox(height: 8),
          const Text('Creates one charge per active tenant using the assigned unit monthly rent. Existing charges are not duplicated.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, [periodController.text.trim(), dueController.text.trim()]), child: const Text('Generate')),
        ],
      ),
    );
    periodController.dispose();
    dueController.dispose();
    if (values == null) return;
    try {
      final response = await _client.functions.invoke('rent-charge-generate', body: {
        'property_id': _propertyId,
        'period': values[0],
        'due_date': values[1],
      });
      if (response.data is Map && response.data['success'] != true) {
        throw Exception(response.data['error'] ?? 'Could not generate rent charges.');
      }
      await _loadPayments();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(response.data['message']?.toString() ?? 'Rent charges generated.')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not generate charges: $e')));
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
      final response = await _client.functions.invoke('rent-payment-reconcile', body: {
        'payment_id': payment['id'],
        'provider_reference': ref,
        'verification_note': 'Manually checked against landlord account statement.',
      });
      if (response.data is Map && response.data['success'] != true) {
        throw Exception(response.data['error'] ?? 'Verification failed.');
      }
      await _loadPayments();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verified. Receipt ${response.data['payment']?['receipt_number'] ?? ''}')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Verification failed: $e')));
    }
  }

  Future<void> _reject(Map<String, dynamic> payment) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject payment submission'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Reason (at least 8 characters)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Reject')),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.length < 8) return;
    try {
      final response = await _client.functions.invoke('rent-payment-reject', body: {
        'payment_id': payment['id'],
        'rejection_reason': reason,
      });
      if (response.data is Map && response.data['success'] != true) {
        throw Exception(response.data['error'] ?? 'Could not reject payment.');
      }
      await _loadPayments();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rejection failed: $e')));
    }
  }

  Widget _field(String label, TextEditingController controller, {String? hint, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _metric(String label, String value, IconData icon, Color color) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 5),
      child: Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15), textAlign: TextAlign.center),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.black54)),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final verified = _payments.where((p) => p['status'] == 'verified').toList();
    final awaiting = _payments.where((p) => p['status'] == 'submitted' || p['status'] == 'pending').toList();
    final total = verified.fold<double>(0, (sum, p) => sum + (double.tryParse(p['amount'].toString()) ?? 0));
    final rentCredits = verified.fold<double>(0, (sum, p) => sum + (double.tryParse(p['unallocated_amount']?.toString() ?? '0') ?? 0));
    final outstanding = _charges.fold<double>(0, (sum, charge) {
      final due = double.tryParse(charge['amount_due']?.toString() ?? '0') ?? 0;
      final paid = double.tryParse(charge['amount_paid']?.toString() ?? '0') ?? 0;
      return sum + (due - paid).clamp(0, double.infinity).toDouble();
    });
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final overdueCount = _charges.where((charge) {
      final dueDate = DateTime.tryParse(charge['due_date']?.toString() ?? '');
      return charge['status'] != 'paid' &&
          dueDate != null &&
          dueDate.isBefore(DateTime.now());
    }).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Rent collection', style: TextStyle(fontWeight: FontWeight.bold)), actions: [
        IconButton(onPressed: _loadPayments, icon: const Icon(Icons.refresh)),
      ]),
      body: RefreshIndicator(
        onRefresh: _loadPayments,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(_propertyName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              initiallyExpanded: false,
              title: const Text('Payment account settings', style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('Choose exactly one payment destination for this apartment'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _destinationType,
                  decoration: const InputDecoration(labelText: 'Payment destination type', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'paybill', child: Text('M-Pesa Paybill')),
                    DropdownMenuItem(value: 'till', child: Text('M-Pesa Till')),
                    DropdownMenuItem(value: 'bank', child: Text('Bank account')),
                  ],
                  onChanged: (value) => setState(() => _destinationType = value ?? 'paybill'),
                ),
                const SizedBox(height: 12),
                if (_destinationType == 'paybill') ...[
                  _field('Paybill number', _paybill, keyboardType: TextInputType.number),
                  _field('Paybill account number / reference', _mpesaReference),
                ] else if (_destinationType == 'till')
                  _field('Till number', _till, keyboardType: TextInputType.number)
                else ...[
                  _field('Bank name', _bankName),
                  _field('Account holder name', _bankAccountName),
                  _field('Bank account number', _bankAccountNumber, keyboardType: TextInputType.text),
                  _field('Branch', _bankBranch),
                ],
                _field('Additional tenant instructions', _instructions),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable rent collection instructions'),
                  subtitle: const Text('Tenants can see these details when active.'),
                  value: _accountActive,
                  onChanged: (value) => setState(() => _accountActive = value),
                ),
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: _savingAccount ? null : _saveAccount,
                  icon: _savingAccount ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
                  label: Text(_savingAccount ? 'Saving...' : 'Save payment account'),
                )),
                const SizedBox(height: 8),
                const Text('Only enter an account belonging to the property owner/landlord. JUMAA does not receive tenant rent.', style: TextStyle(color: Colors.black54, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _metric('Verified', verified.length.toString(), Icons.verified, Colors.green)),
            const SizedBox(width: 8),
            Expanded(child: _metric('Awaiting', awaiting.length.toString(), Icons.pending_actions, Colors.orange)),
            const SizedBox(width: 8),
            Expanded(child: _metric('Collected', 'KSh ${total.toStringAsFixed(0)}', Icons.account_balance_wallet, Colors.indigo)),
          ]),
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Rent accounting', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Outstanding: KSh ${outstanding.toStringAsFixed(2)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text('Overdue charges: $overdueCount', style: const TextStyle(color: Colors.deepOrange)),
            Text('Tenant rent credits: KSh ${rentCredits.toStringAsFixed(2)}', style: const TextStyle(color: Colors.teal)),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: _generateMonthlyCharges,
              icon: const Icon(Icons.calendar_month),
              label: const Text('Generate monthly rent charges'),
            )),
          ]))),
          const SizedBox(height: 20),
          const Text('Monthly rent charges', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_charges.isEmpty)
            const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No rent charges generated yet.')))
          else
            ..._charges.map((charge) {
              final due = double.tryParse(charge['amount_due']?.toString() ?? '0') ?? 0;
              final paid = double.tryParse(charge['amount_paid']?.toString() ?? '0') ?? 0;
              final balance = due - paid;
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  title: Text('${charge['period_start']} • Tenant ${charge['tenant_id']}'),
                  subtitle: Text('Due ${charge['due_date']} • KSh ${paid.toStringAsFixed(2)} paid of KSh ${due.toStringAsFixed(2)}'),
                  trailing: Text('KSh ${balance.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.bold, color: balance <= 0 ? Colors.green : Colors.deepOrange)),
                ),
              );
            }),
          const SizedBox(height: 20),
          const Text('Tenant rent payments', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_loading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (_error != null) Text('Could not load rent payments: $_error')
          else if (_payments.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('No rent payments have been initiated yet.')))
          else ..._payments.map((p) {
            final status = p['status'].toString();
            final amount = double.tryParse(p['amount'].toString()) ?? 0;
            final ref = p['provider_reference']?.toString() ?? '';
            return Card(
              margin: const EdgeInsets.only(bottom: 9),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('KSh ${amount.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
                    Chip(label: Text(status.toUpperCase())),
                  ]),
                  Text('${p['payment_method']} • Tenant ${p['tenant_id']}'),
                  const SizedBox(height: 3),
                  SelectableText('JUMAA ref: ${p['payment_reference']}'),
                  if (ref.isNotEmpty) SelectableText('Transaction: $ref'),
                  if (p['receipt_number'] != null) SelectableText('Receipt: ${p['receipt_number']}'),
                  if (p['rejection_reason'] != null) Text('Reason: ${p['rejection_reason']}', style: const TextStyle(color: Colors.red)),
                  if (status == 'submitted' && ref.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: FilledButton.icon(onPressed: () => _verify(p), icon: const Icon(Icons.verified), label: const Text('Verify'))),
                      const SizedBox(width: 8),
                      Expanded(child: OutlinedButton.icon(onPressed: () => _reject(p), icon: const Icon(Icons.close), label: const Text('Reject'))),
                    ]),
                  ],
                  if (status == 'pending') ...[
                    const Padding(padding: EdgeInsets.only(top: 6), child: Text('Waiting for tenant to submit the transaction code.', style: TextStyle(color: Colors.black54, fontSize: 12))),
                    Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _reject(p), child: const Text('Cancel / reject intent'))),
                  ],
                ]),
              ),
            );
          }),
          const SizedBox(height: 12),
          const Text('Only verify after checking the actual M-Pesa or bank statement. A tenant-submitted code alone is not proof of settlement.', style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.4)),
        ]),
      ),
    );
  }
}
