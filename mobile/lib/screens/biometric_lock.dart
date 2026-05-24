import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/auth.dart';
import '../state/biometric.dart';

class BiometricLockScreen extends ConsumerStatefulWidget {
  const BiometricLockScreen({super.key});
  @override
  ConsumerState<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends ConsumerState<BiometricLockScreen> {
  @override
  void initState() {
    super.initState();
    // Trigger the system biometric prompt as soon as the screen mounts. If
    // the user cancels, they can retry via the button.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryUnlock());
  }

  Future<void> _tryUnlock() async {
    await ref.read(biometricProvider.notifier).unlock();
  }

  @override
  Widget build(BuildContext context) {
    final bio = ref.watch(biometricProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 56, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 20),
                  Text('Familygram is locked', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Authenticate to view the family feed.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
                    textAlign: TextAlign.center,
                  ),
                  if (bio.error != null) Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(bio.error!, style: const TextStyle(color: Colors.red, fontSize: 12), textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: bio.checking
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.fingerprint),
                      label: const Text('Unlock'),
                      onPressed: bio.checking ? null : _tryUnlock,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () async {
                      ref.read(biometricProvider.notifier).reset();
                      await ref.read(authProvider.notifier).logout();
                    },
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
