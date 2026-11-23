import 'package:material_ui/material_ui.dart';

import '../sync/api_client.dart';
import 'app_theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSignedIn, this.initialServer});
  final Future<void> Function(
      String server, String email, String token, String userId) onSignedIn;
  final String? initialServer;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _server = TextEditingController(
      text: widget.initialServer ?? 'http://localhost:8080');
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _register = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ApiClient(_server.text.trim());
      final res = _register
          ? await api.register(_email.text.trim(), _password.text)
          : await api.login(_email.text.trim(), _password.text);
      await widget.onSignedIn(_server.text.trim(), _email.text.trim(),
          res['token'] as String, res['userId'] as String);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Cannot reach your server. Check the address and your connection, then try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeServer() async {
    final ctl = TextEditingController(text: _server.text);
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your sync server'),
        content: SizedBox(
            width: 400,
            child: Form(
                key: form,
                child: TextFormField(
                  controller: ctl,
                  autofocus: true,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'https://your-server.example'),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  validator: (v) {
                    final uri = Uri.tryParse(v?.trim() ?? '');
                    return uri == null ||
                            !['http', 'https'].contains(uri.scheme) ||
                            uri.host.isEmpty
                        ? 'Enter an http or https server address.'
                        : null;
                  },
                  onFieldSubmitted: (_) {
                    if (form.currentState!.validate()) {
                      Navigator.pop(ctx, ctl.text.trim());
                    }
                  },
                ))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(ctx, ctl.text.trim());
                }
              },
              child: const Text('Use server')),
        ],
      ),
    );
    // A dialog's field remains mounted during its exit transition.
    if (mounted && result != null) {
      setState(() {
        _server.text = result;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
          child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 32),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight:
                              (box.maxHeight - 64).clamp(0, double.infinity)),
                      child: Center(
                          child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: AutofillGroup(
                            child: Form(
                                key: _form,
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Align(
                                          alignment: Alignment.centerLeft,
                                          child: PdfMark()),
                                      const SizedBox(height: 20),
                                      Text(
                                          _register
                                              ? 'Your reading,\neverywhere.'
                                              : 'Read anywhere.\nPick up where you left off.',
                                          style:
                                              theme.textTheme.headlineMedium),
                                      const SizedBox(height: 16),
                                      Text(
                                          'Your library, highlights and notes follow you to every device.',
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant)),
                                      const SizedBox(height: 36),
                                      TextFormField(
                                        controller: _email,
                                        enabled: !_busy,
                                        decoration: const InputDecoration(
                                            labelText: 'Email',
                                            hintText: 'you@example.com'),
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        autofillHints: const [
                                          AutofillHints.email
                                        ],
                                        autocorrect: false,
                                        textInputAction: TextInputAction.next,
                                        validator: (v) =>
                                            v == null || !v.trim().contains('@')
                                                ? 'Enter your email address.'
                                                : null,
                                      ),
                                      const SizedBox(height: 20),
                                      TextFormField(
                                        controller: _password,
                                        enabled: !_busy,
                                        decoration: InputDecoration(
                                          labelText: 'Password',
                                          hintText: _register
                                              ? 'At least 8 characters'
                                              : 'Your password',
                                          suffixIcon: IconButton(
                                              tooltip: _showPassword
                                                  ? 'Hide password'
                                                  : 'Show password',
                                              onPressed: () => setState(() =>
                                                  _showPassword =
                                                      !_showPassword),
                                              icon: Icon(_showPassword
                                                  ? Icons
                                                      .visibility_off_outlined
                                                  : Icons.visibility_outlined)),
                                        ),
                                        obscureText: !_showPassword,
                                        autofillHints: [
                                          _register
                                              ? AutofillHints.newPassword
                                              : AutofillHints.password
                                        ],
                                        textInputAction: TextInputAction.done,
                                        onFieldSubmitted: (_) => _submit(),
                                        validator: (v) => v == null || v.isEmpty
                                            ? 'Enter your password.'
                                            : _register && v.length < 8
                                                ? 'Use at least 8 characters.'
                                                : null,
                                      ),
                                      if (_error != null) ...[
                                        const SizedBox(height: 16),
                                        Semantics(
                                            liveRegion: true,
                                            child: Text(_error!,
                                                style: TextStyle(
                                                    color: scheme.error))),
                                      ],
                                      const SizedBox(height: 24),
                                      FilledButton(
                                          onPressed: _busy ? null : _submit,
                                          child: _busy
                                              ? const SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2))
                                              : Text(_register
                                                  ? 'Create account'
                                                  : 'Sign in')),
                                      const SizedBox(height: 12),
                                      TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => setState(() {
                                                    _register = !_register;
                                                    _error = null;
                                                  }),
                                          child: Text(_register
                                              ? 'Already have an account? Sign in'
                                              : 'Create account')),
                                      const SizedBox(height: 48),
                                      const Divider(),
                                      const SizedBox(height: 16),
                                      Row(children: [
                                        Icon(Icons.dns_outlined,
                                            size: 16,
                                            color: scheme.onSurfaceVariant),
                                        const SizedBox(width: 8),
                                        Expanded(
                                            child: Text(_server.text,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant))),
                                        TextButton(
                                            onPressed:
                                                _busy ? null : _changeServer,
                                            child: const Text('Change server')),
                                      ]),
                                    ]))),
                      )),
                    ),
                  ))),
    );
  }
}
