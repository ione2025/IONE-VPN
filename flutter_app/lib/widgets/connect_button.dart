import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../providers/vpn_provider.dart';

/// Large animated connect/disconnect button for the home screen.
class ConnectButton extends StatefulWidget {
  const ConnectButton({
    super.key,
    required this.status,
    required this.onPressed,
  });

  final VpnStatus status;
  final VoidCallback? onPressed;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _scale = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(ConnectButton old) {
    super.didUpdateWidget(old);
    if (widget.status == VpnStatus.connected) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.reset();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color get _ringColor {
    return switch (widget.status) {
      VpnStatus.connected => AppTheme.successGreen,
      VpnStatus.connecting || VpnStatus.disconnecting => AppTheme.warningAmber,
      VpnStatus.error => AppTheme.errorRed,
      _ => Colors.grey.shade600,
    };
  }

  Color get _buttonColor {
    return switch (widget.status) {
      VpnStatus.connected => AppTheme.successGreen,
      VpnStatus.connecting || VpnStatus.disconnecting => AppTheme.warningAmber,
      VpnStatus.error => AppTheme.errorRed,
      _ => AppTheme.primaryBlue,
    };
  }

  String get _label {
    return switch (widget.status) {
      VpnStatus.connected => 'Disconnect',
      VpnStatus.connecting => 'Connecting…',
      VpnStatus.disconnecting => 'Disconnecting…',
      VpnStatus.error => 'Retry',
      _ => 'Connect',
    };
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = widget.status == VpnStatus.connecting ||
        widget.status == VpnStatus.disconnecting;

    return ScaleTransition(
      scale: _scale,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 180,
          height: 180,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _ringColor, width: 4),
            color: _buttonColor.withOpacity(0.12),
          ),
          child: Center(
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _buttonColor,
                boxShadow: [
                  BoxShadow(
                    color: _buttonColor.withOpacity(0.35),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: isBusy
                  ? const Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 3,
                        ),
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.power_settings_new,
                            color: Colors.white, size: 42),
                        const SizedBox(height: 6),
                        Text(
                          _label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
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
