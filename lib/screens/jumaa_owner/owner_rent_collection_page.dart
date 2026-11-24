import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../landlord/landlord_payments_page.dart';

class OwnerRentCollectionPage extends StatefulWidget {
  const OwnerRentCollectionPage({super.key});

  @override
  State<OwnerRentCollectionPage> createState() => _OwnerRentCollectionPageState();
}

class _OwnerRentCollectionPageState extends State<OwnerRentCollectionPage> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _properties = [];

  @override
  void initState() {
    super.initState();
    _loadProperties();
  }

  Future<void> _loadProperties() async {
    setState(() { _loading = true; _error = null; });
    try {
      final user = _client.auth.currentUser;
      if (user == null) throw Exception('Sign in again to manage rent collection.');
      final rows = await _client.from('properties')
          .select('id,name')
          .eq('owner_id', user.id)
          .order('name');
      if (!mounted) return;
      setState(() {
        _properties = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Property rent collection'),
        actions: [IconButton(onPressed: _loadProperties, icon: const Icon(Icons.refresh))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.error_outline, size: 44, color: Colors.red),
                    const SizedBox(height: 10),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _loadProperties, child: const Text('Retry')),
                  ]),
                ))
              : _properties.isEmpty
                  ? const Center(child: Text('No properties are assigned to your owner account yet.'))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text(
                          'Choose a property to manage its rent accounts, monthly charges, arrears and tenant payments.',
                          style: TextStyle(color: Colors.black54, height: 1.4),
                        ),
                        const SizedBox(height: 12),
                        ..._properties.map((property) {
                          final id = property['id']?.toString() ?? '';
                          final name = property['name']?.toString() ?? 'Property';
                          return Card(
                            child: ListTile(
                              leading: const CircleAvatar(child: Icon(Icons.apartment)),
                              title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: const Text('Rent accounts • Statements • Arrears'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: id.isEmpty ? null : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LandlordPaymentsPage(propertyId: id, propertyName: name),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
    );
  }
}
