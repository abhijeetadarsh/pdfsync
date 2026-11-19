import 'package:material_ui/material_ui.dart';

import '../sync/api_client.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSignedIn, this.initialServer});
  final Future<void> Function(String server, String email, String token, String userId) onSignedIn;
  final String? initialServer;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _server = TextEditingController(text: widget.initialServer ?? 'http://localhost:8080');
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit(bool register) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ApiClient(_server.text.trim());
      final res = register
          ? await api.register(_email.text.trim(), _password.text)
          : await api.login(_email.text.trim(), _password.text);
      await widget.onSignedIn(_server.text.trim(), _email.text.trim(), res['token'] as String, res['userId'] as String);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Cannot reach server: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.picture_as_pdf, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 8),
                Text('PDF Sync', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 24),
                TextField(controller: _server, decoration: const InputDecoration(labelText: 'Server URL'), keyboardType: TextInputType.url),
                const SizedBox(height: 12),
                TextField(
                    controller: _email,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email]),
                const SizedBox(height: 12),
                TextField(
                    controller: _password,
                    decoration: const InputDecoration(labelText: 'Password (8+ characters)'),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(false)),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(onPressed: _busy ? null : () => _submit(false), child: const Text('Sign in')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _busy ? null : () => _submit(true), child: const Text('Create account')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
