import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'chats_screen.dart';
import 'nearby_screen.dart';
import 'settings_screen.dart';

/// Signed-in shell: chats, radar, and settings behind a bottom navigation bar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() => _tab = index);
  }

  void _openNearby() => _selectTab(1);

  Future<void> _openChat(String threadId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(controller: widget.controller, threadId: threadId),
      ),
    );
    // Coming back from a chat should land on the conversation list.
    if (mounted && _tab != 0) _selectTab(0);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TickerMode(
            enabled: _tab == 0,
            child: ChatsScreen(
              controller: controller,
              onOpenNearby: _openNearby,
              onOpenChat: _openChat,
            ),
          ),
          TickerMode(
            enabled: _tab == 1,
            child: NearbyScreen(controller: controller, onOpenChat: _openChat),
          ),
          TickerMode(
            enabled: _tab == 2,
            child: SettingsScreen(controller: controller),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final unread = controller.totalUnread;
          return NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _selectTab,
            destinations: [
              NavigationDestination(
                icon: _UnreadBadge(
                  unread: unread,
                  child: const Icon(Icons.forum_outlined),
                ),
                selectedIcon: _UnreadBadge(
                  unread: unread,
                  child: const Icon(Icons.forum),
                ),
                label: 'Chats',
              ),
              const NavigationDestination(
                icon: Icon(Icons.radar_outlined),
                selectedIcon: Icon(Icons.radar),
                label: 'Radar',
              ),
              const NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Settings',
              ),
            ],
          );
        },
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.unread, required this.child});

  final int unread;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (unread <= 0) return child;
    return Badge(
      label: Text(unread > 99 ? '99+' : '$unread'),
      backgroundColor: MgsColors.lime,
      textColor: const Color(0xFF101A00),
      child: child,
    );
  }
}
