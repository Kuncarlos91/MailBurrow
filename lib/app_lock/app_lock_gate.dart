import 'package:flutter/material.dart';

import 'app_lock_controller.dart';
import 'app_lock_settings.dart';

/// Makes the [AppLockController] available to Settings.
class AppLockScope extends InheritedNotifier<AppLockController> {
  const AppLockScope({
    super.key,
    required AppLockController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller, or null where app lock is not set up (for example in
  /// widget tests of single screens).
  static AppLockController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLockScope>()?.notifier;
}

/// Wraps the whole navigator. While app lock hides content, the navigator is
/// not painted, cannot be touched, focused or read by accessibility services,
/// does not animate, and Back is ignored; an opaque screen is shown instead.
/// Before the first unlock the navigator is not built at all, so no archive
/// is restored or contacted behind a startup lock.
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final AppLockController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final visible = controller.contentVisible;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (controller.mayBuildContent)
            ExcludeFocus(
              excluding: !visible,
              child: ExcludeSemantics(
                excluding: !visible,
                child: TickerMode(
                  enabled: visible,
                  child: Offstage(offstage: !visible, child: child),
                ),
              ),
            ),
          if (!visible) _LockSurface(controller: controller),
        ],
      );
    },
  );
}

class _LockSurface extends StatelessWidget {
  const _LockSurface({required this.controller});

  final AppLockController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = controller.phase;
    final prompting = controller.prompting || controller.busy;
    final message = controller.message;
    final interactive =
        phase == AppLockPhase.locked ||
        phase == AppLockPhase.authenticating ||
        phase == AppLockPhase.error;
    return Material(
      key: const Key('app-lock-surface'),
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                if (interactive) ...[
                  const SizedBox(height: 16),
                  Text(
                    'MailBurrow is locked',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    message,
                    key: const Key('app-lock-message'),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (phase == AppLockPhase.locked ||
                    phase == AppLockPhase.authenticating) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('app-lock-unlock'),
                    onPressed: prompting ? null : controller.unlock,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Unlock'),
                  ),
                ],
                if (phase == AppLockPhase.error) ...[
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('app-lock-retry'),
                    onPressed: prompting ? null : controller.retry,
                    child: const Text('Try again'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('app-lock-repair'),
                    onPressed: prompting ? null : controller.unlockAndRepair,
                    child: const Text('Unlock and keep app lock on'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String relockLabel(Duration relock) => switch (relock.inSeconds) {
  0 => 'Immediately',
  60 => 'After 1 minute',
  _ => 'After ${relock.inMinutes} minutes',
};

/// The app lock rows in Settings. Hidden where app lock is not set up.
class AppLockSettingsTiles extends StatelessWidget {
  const AppLockSettingsTiles({super.key});

  @override
  Widget build(BuildContext context) {
    final lock = AppLockScope.maybeOf(context);
    if (lock == null || lock.settings == null) return const SizedBox.shrink();
    final enabled = lock.enabled;
    final settings = lock.settings!;
    final idle = !lock.busy && !lock.prompting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('app-lock-switch'),
          title: const Text('App lock'),
          subtitle: const Text(
            'Ask for your fingerprint, face or device screen lock to open '
            'MailBurrow. Mail stays on your server either way.',
          ),
          value: enabled,
          onChanged: idle
              ? (on) => _report(context, on ? lock.enable() : lock.disable())
              : null,
        ),
        if (enabled)
          ListTile(
            key: const Key('app-lock-relock'),
            title: const Text('Lock after leaving'),
            subtitle: Text(relockLabel(settings.relockAfter)),
            enabled: idle,
            onTap: () => _chooseRelock(context, lock, settings.relockAfter),
          ),
      ],
    );
  }

  Future<void> _chooseRelock(
    BuildContext context,
    AppLockController lock,
    Duration current,
  ) async {
    final choice = await showDialog<Duration>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Lock after leaving'),
        children: [
          for (final option in AppLockSettings.relockChoices)
            ListTile(
              title: Text(relockLabel(option)),
              trailing: option == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, option),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    await _report(context, lock.setRelockAfter(choice));
  }

  Future<void> _report(BuildContext context, Future<String?> change) async {
    final message = await change;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
