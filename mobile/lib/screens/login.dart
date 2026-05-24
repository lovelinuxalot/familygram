import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../state/auth.dart';
import '../widgets/apple_sign_in_button.dart';
import '../widgets/google_sign_in_button.dart';

// Asks the backend whether demo mode is on. The login screen uses this to
// decide whether to render the email/password form. The flag is purely
// cosmetic — the real gate is /auth/demo on the backend.
final _demoModeProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.read(apiClientProvider).isDemoMode();
  } catch (_) {
    // If the backend isn't reachable, hide the form rather than the whole
    // login screen. Social sign-in will surface the connectivity issue.
    return false;
  }
});

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demoMode = ref.watch(_demoModeProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 48),
                  Text('Familygram', style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 12),
                  Text(
                    'Photos for the people who matter.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 48),
                  const AppleSignInButton(),
                  const SizedBox(height: 12),
                  const GoogleSignInButton(),
                  const SizedBox(height: 12),
                  Text(
                    'Sign-in is invite-only. Ask the family admin to add your Google email if you don\'t have access yet.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
                    textAlign: TextAlign.center,
                  ),
                  if (demoMode.valueOrNull == true) ...[
                    const SizedBox(height: 32),
                    const _DemoLoginForm(),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoLoginForm extends ConsumerStatefulWidget {
  const _DemoLoginForm();

  @override
  ConsumerState<_DemoLoginForm> createState() => _DemoLoginFormState();
}

class _DemoLoginFormState extends ConsumerState<_DemoLoginForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Email and password required');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signInWithDemo(email, password);
    } on ApiException catch (e) {
      setState(() => _error = e.status == 401 ? 'Invalid demo credentials' : e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'or sign in with demo account',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          enabled: !_submitting,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          enabled: !_submitting,
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Sign in'),
        ),
      ],
    );
  }
}
