import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class JumaaOwnerSubscriptionsPage extends StatefulWidget {
  const JumaaOwnerSubscriptionsPage({super.key});

  @override
  State<JumaaOwnerSubscriptionsPage> createState() =>
      _JumaaOwnerSubscriptionsPageState();
}

class _JumaaOwnerSubscriptionsPageState
    extends State<JumaaOwnerSubscriptionsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _subscriptions = [];
  final Map<String, Map<String, dynamic>> _properties = {};
  final Map<String, Map<String, dynamic>> _owners = {};
  final Map<String, List<Map<String, dynamic>>> _history = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Sign in as a JUMAA administrator.');
      final profile = await _supabase
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();
      if (profile?['role']?.toString().toLowerCase() != 'jumaa_owner') {
        throw Exception('This page is available to JUMAA administrators only.');
      }

      final rows = await _supabase
          .from('subscriptions')
          .select('*')
          .order('next_payment_at', ascending: true);
      final subscriptions = List<Map<String, dynamic>>.from(rows);
      final propertyIds = subscriptions
          .map((row) => row['property_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final ownerIds = subscriptions
          .map((row) => row['owner_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      _properties.clear();
      _owners.clear();
      _history.clear();

      if (propertyIds.isNotEmpty) {
        final propertyRows = await _supabase
            .from('properties')
            .select('id,name')
            .inFilter('id', propertyIds);
        for (final row in propertyRows) {
          final item = Map<String, dynamic>.from(row);
          _properties[item['id'].toString()] = item;
        }
      }
      if (ownerIds.isNotEmpty) {
        final ownerRows = await _supabase
            .from('profiles')
            .select('id,full_name,email')
            .inFilter('id', ownerIds);
        for (final row in ownerRows) {
          final item = Map<String, dynamic>.from(row);
          _owners[item['id'].toString()] = item;
        }
      }

      if (subscriptions.isNotEmpty) {
        final historyRows = await _supabase
            .from('subscription_reschedules')
            .select('*')
            .order('created_at', ascending: false)
            .limit(200);
        final history = List<Map<String, dynamic>>.from(historyRows);
        for (final item in history) {
          final id = item['subscription_id']?.toString() ?? '';
          (_history[id] ??= <Map<String, dynamic>>[]).add(item);
        }
        final adminIds = history
            .map((item) => item['admin_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();
        if (adminIds.isNotEmpty) {
          final adminRows = await _supabase
              .from('profiles')
              .select('id,full_name,email')
              .inFilter('id', adminIds);
          for (final row in adminRows) {
            final item = Map<String, dynamic>.from(row);
            _owners[item['id'].toString()] = item;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _subscriptions = subscriptions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String _date(dynamic value) {
    if (value == null) return '—';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    final local = parsed.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  String _money(dynamic value) {
    final amount = double.tryParse(value?.toString() ?? '') ?? 0;
    return 'KSh ${amount.toStringAsFixed(2)}';
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
        return Colors.green;
      case 'trial':
        return Colors.orange;
      case 'expired':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  Future<void> _reschedule(Map<String, dynamic> subscription) async {
    final reasonController = TextEditingController();
    final currentDue = DateTime.tryParse(
          subscription['next_payment_at']?.toString() ??
              subscription['trial_ends_at']?.toString() ??
              '',
        ) ??
        DateTime.now();
    DateTime selectedDate = DateTime(
      currentDue.year,
      currentDue.month,
      currentDue.day,
    ).add(const Duration(days: 1));
    String mode = 'temporary_grace';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reschedule property payment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Choose how the revised date should work.'),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: mode,
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => mode = value);
                    }
                  },
                  child: Column(
                    children: const [
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        value: 'temporary_grace',
                        title: Text('Temporary grace'),
                        subtitle: Text(
                          'Keep the regular billing cycle unchanged.',
                        ),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        value: 'shift_cycle',
                        title: Text('Shift billing cycle'),
                        subtitle: Text(
                          'Make the new date the future billing anchor.',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime.now().add(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) {
                      setDialogState(() => selectedDate = picked);
                    }
                  },
                  icon: const Icon(Icons.calendar_month),
                  label: Text(_date(selectedDate.toIso8601String())),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Reason (required)',
                    hintText: 'e.g. Owner requested payment on Friday',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Confirm date'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      reasonController.dispose();
      return;
    }
    if (reasonController.text.trim().length < 5) {
      reasonController.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a reason of at least five characters.')),
        );
      }
      return;
    }

    try {
      final dueAt = DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        23,
        59,
      ).toUtc();
      final result = await _supabase.rpc(
        'reschedule_jumaa_subscription',
        params: {
          'p_subscription_id': subscription['id'],
          'p_new_due_at': dueAt.toIso8601String(),
          'p_mode': mode,
          'p_reason': reasonController.text.trim(),
        },
      );
      final notificationId = result is Map
          ? result['notification_id']?.toString()
          : null;
      if (notificationId != null && notificationId.isNotEmpty) {
        try {
          await _supabase.functions.invoke(
            'send-jumaa-notification',
            body: {'owner_notification_id': notificationId},
          );
        } catch (notificationError) {
          debugPrint('Subscription reschedule notification delivery failed: $notificationError');
        }
      }
      reasonController.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Property subscription date rescheduled.')),
      );
      await _load();
    } catch (error) {
      reasonController.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not reschedule: $error'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _reviewLegacyCredit(
    Map<String, dynamic> subscription,
    double pendingAmount,
  ) async {
    final amountController = TextEditingController(text: pendingAmount.toStringAsFixed(2));
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Review historical credit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Unverified historical credit: ${_money(pendingAmount)}'),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Credit to approve (KES)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Review reason (required)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Approve credit'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      amountController.dispose();
      reasonController.dispose();
      return;
    }

    final amount = double.tryParse(amountController.text.trim());
    final reason = reasonController.text.trim();
    amountController.dispose();
    reasonController.dispose();

    if (amount == null || amount < 0 || amount > pendingAmount || reason.length < 5) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid amount within the pending credit and a reason of at least five characters.')),
        );
      }
      return;
    }

    try {
      final result = await _supabase.rpc(
        'review_jumaa_legacy_subscription_credit',
        params: {
          'p_subscription_id': subscription['id'],
          'p_approved_amount': amount,
          'p_reason': reason,
        },
      );
      final notificationId = result is Map
          ? result['notification_id']?.toString()
          : null;
      if (notificationId != null && notificationId.isNotEmpty) {
        try {
          await _supabase.functions.invoke(
            'send-jumaa-notification',
            body: {'owner_notification_id': notificationId},
          );
        } catch (notificationError) {
          debugPrint('Legacy credit review notification failed: $notificationError');
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Legacy credit review recorded.')),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not approve credit: $error'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _subscriptionCard(Map<String, dynamic> row) {
    final propertyId = row['property_id']?.toString() ?? '';
    final ownerId = row['owner_id']?.toString() ?? '';
    final property = _properties[propertyId] ?? {};
    final owner = _owners[ownerId] ?? {};
    final status = row['status']?.toString() ?? 'unknown';
    final history = _history[row['id']?.toString() ?? ''] ?? const [];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.apartment_rounded, color: Color(0xFF7C3AED)),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    property['name']?.toString() ?? 'Property',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                Chip(
                  label: Text(status.toUpperCase()),
                  backgroundColor: _statusColor(status).withValues(alpha: .12),
                  labelStyle: TextStyle(color: _statusColor(status), fontSize: 10, fontWeight: FontWeight.w800),
                  side: BorderSide.none,
                ),
              ],
            ),
            Text(
              owner['full_name']?.toString() ?? owner['email']?.toString() ?? ownerId,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const Divider(height: 22),
            _detail('Monthly fee', _money(row['monthly_amount'])),
            _detail('Units', row['unit_count']?.toString() ?? '—'),
            _detail('Trial ends', _date(row['trial_ends_at'])),
            _detail('Next due date', _date(row['next_payment_at'])),
            if (row['grace_until'] != null)
              _detail('Approved grace until', _date(row['grace_until'])),
            _detail('Available credit', _money(row['available_credit_amount'])),
            _detail(
              'Legacy credit awaiting review',
              _money(
                (double.tryParse(row['legacy_credit_amount']?.toString() ?? '') ?? 0) -
                (double.tryParse(row['legacy_credit_reviewed_amount']?.toString() ?? '') ?? 0),
              ),
            ),
            _detail('Outstanding balance', _money(row['outstanding_balance'])),
            const SizedBox(height: 12),
            if ((double.tryParse(row['legacy_credit_amount']?.toString() ?? '') ?? 0) >
                (double.tryParse(row['legacy_credit_reviewed_amount']?.toString() ?? '') ?? 0)) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _reviewLegacyCredit(
                    row,
                    (double.tryParse(row['legacy_credit_amount']?.toString() ?? '') ?? 0) -
                        (double.tryParse(row['legacy_credit_reviewed_amount']?.toString() ?? '') ?? 0),
                  ),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('REVIEW LEGACY CREDIT'),
                ),
              ),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _reschedule(row),
                icon: const Icon(Icons.event_repeat),
                label: const Text('RESCHEDULE PAYMENT'),
              ),
            ),
            if (history.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Reschedule history (${history.length})'),
                children: history.take(5).map((item) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(item['mode'] == 'shift_cycle' ? 'Billing cycle shifted' : 'Temporary grace granted'),
                  subtitle: Text(
                    '${_date(item['original_due_at'])} → ${_date(item['new_due_at'])}\n'
                    '${item['reason'] ?? ''}\n'
                    'Admin: ${_owners[item['admin_id']?.toString()]?['full_name'] ?? item['admin_id'] ?? 'Unknown'}',
                  ),
                  trailing: Text(_date(item['created_at']), style: const TextStyle(fontSize: 10)),
                )).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Property Subscriptions'),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : _subscriptions.isEmpty
                  ? const Center(child: Text('No property subscriptions found.'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text(
                            '${_subscriptions.length} property subscriptions',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 12),
                          ..._subscriptions.map(_subscriptionCard),
                        ],
                      ),
                    ),
    );
  }
}
