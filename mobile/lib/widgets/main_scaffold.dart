import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

// Scaffold with Instagram-style bottom nav: Home on left, + FAB in centered
// notch, Profile on right. Used by the top-level Feed and Profile screens.
// Sub-screens like Upload and PostDetail use a plain Scaffold so the user
// gets a back arrow and no nav distraction.
class MainScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final MainTab selected;
  const MainScaffold({super.key, required this.body, required this.selected, this.appBar});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: appBar,
      body: body,
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/upload'),
        tooltip: 'New post',
        child: const Icon(Icons.add_a_photo),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 6,
        height: 60,
        padding: EdgeInsets.zero,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavButton(
              icon: selected == MainTab.home ? Icons.home : Icons.home_outlined,
              label: 'Home',
              active: selected == MainTab.home,
              activeColor: colors.primary,
              onTap: () { if (selected != MainTab.home) context.go('/'); },
            ),
            const SizedBox(width: 48), // gap for the notch
            _NavButton(
              icon: selected == MainTab.profile ? Icons.person : Icons.person_outline,
              label: 'You',
              active: selected == MainTab.profile,
              activeColor: colors.primary,
              onTap: () { if (selected != MainTab.profile) context.go('/me'); },
            ),
          ],
        ),
      ),
    );
  }
}

enum MainTab { home, profile }

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  const _NavButton({required this.icon, required this.label, required this.active, required this.activeColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : Colors.grey.shade600;
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
