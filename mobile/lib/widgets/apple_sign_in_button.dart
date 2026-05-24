import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/auth.dart';

// Sign in with Apple button, matching Apple's Human Interface Guidelines:
// black surface in light mode (inverse in dark), Apple logo, "Continue with
// Apple" label.
class AppleSignInButton extends ConsumerStatefulWidget {
  const AppleSignInButton({super.key});
  @override
  ConsumerState<AppleSignInButton> createState() => _AppleSignInButtonState();
}

class _AppleSignInButtonState extends ConsumerState<AppleSignInButton> {
  bool _busy = false;

  Future<void> _onTap() async {
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).signInWithApple();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Apple's HIG: button is black in light mode, white in dark mode.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? Colors.white : Colors.black;
    final fg = dark ? Colors.black : Colors.white;

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: _busy ? null : _onTap,
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_busy)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
                  )
                else
                  _AppleLogo(color: fg, size: 20),
                const SizedBox(width: 10),
                Text(
                  'Continue with Apple',
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Apple's logo path data. Single-colour mark.
class _AppleLogo extends StatelessWidget {
  final Color color;
  final double size;
  const _AppleLogo({required this.color, this.size = 20});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _AppleLogoPainter(color)),
    );
  }
}

class _AppleLogoPainter extends CustomPainter {
  final Color color;
  _AppleLogoPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    // 24×24 viewBox.
    final s = size.width / 24.0;
    canvas.scale(s);
    final p = Path()
      ..moveTo(17.05, 20.28)
      ..relativeCubicTo(-0.98, 0.95, -2.05, 0.8, -3.08, 0.35)
      ..relativeCubicTo(-1.09, -0.46, -2.09, -0.48, -3.24, 0)
      ..relativeCubicTo(-1.44, 0.62, -2.2, 0.44, -3.06, -0.35)
      ..cubicTo(2.79, 15.25, 3.51, 7.59, 9.05, 7.31)
      ..relativeCubicTo(1.35, 0.07, 2.29, 0.74, 3.08, 0.8)
      ..relativeCubicTo(1.18, -0.24, 2.31, -0.93, 3.57, -0.84)
      ..relativeCubicTo(1.51, 0.12, 2.65, 0.72, 3.4, 1.8)
      ..relativeCubicTo(-3.12, 1.87, -2.38, 5.98, 0.48, 7.13)
      ..relativeCubicTo(-0.57, 1.5, -1.31, 2.99, -2.54, 4.09)
      ..close()
      ..moveTo(12, 7.25)
      ..relativeCubicTo(-0.15, -2.23, 1.66, -4.07, 3.74, -4.25)
      ..relativeCubicTo(0.29, 2.58, -2.34, 4.5, -3.74, 4.25)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
