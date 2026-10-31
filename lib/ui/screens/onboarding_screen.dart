import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _nameController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    if (_error != null) {
      setState(() => _error = null);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _nameController
      ..removeListener(_onNameChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(
        () => _error = 'Pick a name so nearby people can recognise you.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.controller.completeOnboarding(name);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final canStart = _nameController.text.trim().isNotEmpty;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.65, -0.8),
            radius: 1.1,
            colors: [Color(0xFF14210F), MgsColors.ink],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const MgsWordmark(),
                    const SizedBox(height: 42),
                    Text(
                      'Messages that\ntravel person\nto person.',
                      style: textTheme.displayMedium?.copyWith(
                        fontSize: 46,
                        height: 0.98,
                        letterSpacing: -2.2,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'No internet. No servers. No accounts. MGS uses Bluetooth '
                      'to find people nearby and passes messages along until '
                      'they reach the right device.',
                      style: textTheme.bodyMedium?.copyWith(
                        color: MgsColors.muted,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 26),
                    const _Feature(
                      icon: Icons.wifi_off,
                      title: 'No internet',
                      body:
                          'Works in airplane mode, on a plane, at a protest, '
                          'or after a storm.',
                    ),
                    const _Feature(
                      icon: Icons.hub_outlined,
                      title: 'Mesh relay',
                      body:
                          'Every phone becomes a hop. Messages keep moving '
                          'between nearby devices.',
                    ),
                    const _Feature(
                      icon: Icons.devices,
                      title: 'Android · iOS · Windows',
                      body: 'One codebase, one protocol, no central service.',
                    ),
                    const SizedBox(height: 30),
                    TextField(
                      controller: _nameController,
                      maxLength: 32,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _start(),
                      decoration: InputDecoration(
                        labelText: 'Your display name',
                        hintText: 'e.g. Ada',
                        counterText: '',
                        errorText: _error,
                        prefixIcon: const Icon(
                          Icons.person_outline,
                          color: MgsColors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: _busy || !canStart ? null : _start,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: MgsColors.ink,
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('Start meshing'),
                                SizedBox(width: 8),
                                Icon(Icons.arrow_forward, size: 18),
                              ],
                            ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Bluetooth permission is requested when you start. MGS '
                      'never asks for an account or an internet connection.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: MgsColors.muted,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: MgsColors.lime.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MgsColors.lime.withValues(alpha: 0.22)),
            ),
            child: Icon(icon, size: 18, color: MgsColors.lime),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                    color: MgsColors.muted,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
