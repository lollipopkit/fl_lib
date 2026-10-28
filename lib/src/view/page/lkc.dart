import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

final class LkcPageArgs {
  final LkcClient client;

  /// Shown inside a page that has a title bar of its own: no second one.
  final bool embedded;

  const LkcPageArgs(this.client, {this.embedded = false});
}

/// The LKC Cloud account: sign-in, the plans held and on sale, and the account itself.
///
/// Plans and prices are listed only where [LkcClient.webCheckout] is on: an
/// App Store app shows what the user holds and nothing it would sell.
final class LkcAccountPage extends StatefulWidget {
  final LkcPageArgs args;

  const LkcAccountPage({super.key, required this.args});

  static const route = AppRouteArg<void, LkcPageArgs>(
    page: LkcAccountPage.new,
    path: '/lkc/account',
  );

  @override
  State<LkcAccountPage> createState() => _LkcAccountPageState();
}

final class _LkcAccountPageState extends State<LkcAccountPage> {
  LkcClient get _client => widget.args.client;

  List<LkcPlan>? _plans;
  LkcBenefits? _benefits;
  LkcUsage? _usage;

  @override
  void initState() {
    super.initState();
    _client.user.addListener(_onUser);
    unawaited(_load());
  }

  @override
  void dispose() {
    _client.user.removeListener(_onUser);
    super.dispose();
  }

  void _onUser() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      // One after another: a future failing while another is awaited is an
      // unhandled error. The benefits and the catalog only word the page.
      final b = await _client.benefits().then<LkcBenefits?>(
        (b) => b,
        onError: (_) => null,
      );
      final p = await _client.plans().then<List<LkcPlan>?>(
        (p) => p,
        onError: (_) => null,
      );
      if (_client.signedIn) {
        await _client.refresh();
        await _loadUsage();
      }
      if (!mounted) return;
      setState(() {
        _benefits = b ?? _benefits;
        _plans = p ?? _plans;
      });
    } catch (e) {
      if (mounted) context._showLkcErr(e);
    }
  }

  /// Shown with the Storage plan; the page is whole without it.
  Future<void> _loadUsage() async {
    try {
      final usage = await _client.usage();
      if (mounted) setState(() => _usage = usage);
    } catch (e) {
      debugPrint('LKC usage: ${e.runtimeType}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _client.user.value;
    return Scaffold(
      appBar: widget.args.embedded
          ? null
          : CustomAppBar(title: Text(l10n.lkcAccount)),
      body: ValBuilder(
        listenable: _client.entitlements,
        builder: (_) => RefreshIndicator(
          onRefresh: _load,
          child: user == null ? _buildSignedOut() : _buildSignedIn(user),
        ),
      ),
    );
  }

  Widget _buildSignedOut() {
    final scheme = Theme.of(context).colorScheme;
    return _Column(
      children: [
        _LkcCard(
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Icon(
                  Icons.account_circle,
                  size: 40,
                  color: scheme.outlineVariant,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    l10n.lkcNotSignedIn,
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                if (_signingIn)
                  const SizedLoading(23)
                else
                  FilledButton(onPressed: _signIn, child: Text(l10n.login)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Not behind a dialog: the browser may take minutes, and leaving it is the way to cancel.
  bool _signingIn = false;

  Future<void> _signIn() async {
    setState(() => _signingIn = true);
    try {
      if (await _client.signIn() != null) await _load();
    } catch (e) {
      if (mounted) context._showLkcErr(e);
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Widget _buildSignedIn(LkcUser user) {
    final first = [
      _LkcProfileCard(user: user, client: _client),
      ?_buildLine(LkcLine.basic),
    ];
    final second = [
      ?_buildLine(LkcLine.storage),
      ?_buildLine(LkcLine.conduit),
      _buildActions(),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // Two columns once both fit at 330, as the settings pages do.
        if (box.maxWidth < 2 * 330 + 9 + 26) {
          return _Column(children: [...first, ...second]);
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 13),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 695),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _Stack(children: first)),
                      const SizedBox(width: 9),
                      Expanded(child: _Stack(children: second)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A line's section: what its plan grants, or nothing for a line neither
  /// held nor granting anything for free.
  Widget? _buildLine(LkcLine line) {
    final held = _client.entitlementOf(line);
    final tier = held?.plan ?? LkcBenefits.free;
    final items = line == LkcLine.conduit
        ? switch (_planOf(held?.plan)?.limits) {
            final LkcConduitLimits limits => lkcConduitItems(l10n, limits),
            null => const <LkcBenefitItem>[],
          }
        : _benefits?.items(l10n, tier, line) ?? const <LkcBenefitItem>[];
    final onSale = [
      if (_client.webCheckout)
        for (final plan in _plans ?? const <LkcPlan>[])
          if (plan.line == line && plan.stripe != null && plan.id != held?.plan)
            plan,
    ];
    if (held == null && items.isEmpty && onSale.isEmpty) return null;

    final rows = <Widget>[
      for (final item in items)
        item.kind == LkcBenefitKind.storage
            ? _buildStorage(item, tier)
            : _LkcTile(
                icon: _benefitIcon(item.kind),
                title: item.title,
                detail: item.detail,
              ),
      if (line == LkcLine.storage)
        _LkcTile(
          icon: Icons.folder_open,
          title: l10n.lkcFiles,
          trailing: const _Chevron(),
          onTap: _openFiles,
        ),
      for (final plan in onSale) _buildPlan(plan),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle(_lineName(line), _summaryOf(held)),
        if (rows.isNotEmpty) _LkcCard(child: _Rows(rows)),
      ],
    );
  }

  LkcPlan? _planOf(String? id) =>
      id == null ? null : _plans?.where((p) => p.id == id).firstOrNull;

  /// What the group title says of the plan held: its name past the line's,
  /// and when it renews or ends.
  String _summaryOf(LkcEntitlement? e) {
    if (e == null) return l10n.lkcFreeTier;
    final status = switch (e.status) {
      LkcStatus.pastDue => l10n.lkcPastDue,
      LkcStatus.paused => l10n.lkcPaused,
      _ => _dateOf(e),
    };
    final tier = e.plan.split('.').skip(1).map(_title).join(' ');
    return [if (tier.isNotEmpty) tier, ?status].join(' · ');
  }

  Widget _buildStorage(LkcBenefitItem item, String tier) {
    final theme = Theme.of(context);
    final muted = TextStyle(fontSize: 13, color: theme.colorScheme.outline);
    final usage = _usage;
    final quota = usage == null
        ? _benefits?.amount(tier, LkcBenefit.fileBytes)
        : usage.quotaBytes;
    final total = quota == null ? l10n.lkcUnlimited : lkcBytes(quota);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _LeadIcon(_benefitIcon(item.kind)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    Text(
                      usage == null
                          ? total
                          : '${lkcBytes(usage.bytes)} / $total',
                      style: muted.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (usage != null && quota != null && quota > 0) ...[
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      value: (usage.bytes / quota).clamp(0, 1).toDouble(),
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                Text(item.detail, style: muted),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlan(LkcPlan plan) {
    final formatted = _formatPrice(plan.stripe!);
    return _LkcTile(
      icon: Icons.upgrade,
      title: _planName(plan.id),
      detail: switch (plan.period) {
        LkcPeriod.year => l10n.lkcPerYear(formatted),
        _ => l10n.lkcPerMonth(formatted),
      },
      trailing: FilledButton.tonal(
        onPressed: () => context._runLkc(() => _client.openCheckout(plan.id)),
        child: Text(l10n.lkcSubscribe),
      ),
    );
  }

  void _openFiles() {
    // Over the whole window from a page embedded in another: in its pane it
    // would draw a second title bar under the host's.
    LkcFilesPage.route
        .go(
          context,
          LkcPageArgs(_client),
          target: widget.args.embedded ? NavTarget.root : NavTarget.nearest,
        )
        .then((_) => _loadUsage());
  }

  Widget _buildActions() {
    final error = Theme.of(context).colorScheme.error;
    final manageable =
        _client.webCheckout &&
        (_client.entitlements.value ?? const <LkcEntitlement>[]).any(
          (e) => e.source == LkcSource.stripe,
        );
    return _LkcCard(
      child: _Rows([
        if (manageable)
          _LkcTile(
            icon: Icons.credit_card,
            title: l10n.lkcManageSubscriptions,
            trailing: const _Chevron(icon: Icons.open_in_new),
            onTap: () => context._runLkc(_client.openPortal),
          ),
        _LkcTile(icon: Icons.logout, title: l10n.logout, onTap: _signOut),
        _LkcTile(
          icon: Icons.delete_forever,
          title: l10n.lkcDeleteAccount,
          color: error,
          onTap: _deleteAccount,
        ),
      ]),
    );
  }

  Future<void> _signOut() async {
    final ok = await context.showRoundDialog<bool>(
      title: '${l10n.logout}?',
      actions: Btnx.cancelOk,
    );
    if (ok == true) await _client.signOut();
  }

  Future<void> _deleteAccount() async {
    final store = await context._runLkc(_client.hasStoreSubscription);
    final name = _client.user.value?.name;
    if (store == null || name == null || !mounted) return;
    final ok = await context.showRoundDialog<bool>(
      title: l10n.lkcDeleteAccount,
      child: Text(
        [
          if (store) l10n.lkcStoreSubscriptionTip,
          l10n.lkcDeleteAccountConfirm(name),
        ].join('\n\n'),
      ),
      actions: [
        Btn.cancel(),
        Btn.text(
          text: l10n.delete,
          textStyle: TextStyle(color: Theme.of(context).colorScheme.error),
          onTap: () => context.popDialog(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    await context._runLkc(_client.deleteAccount);
  }

  /// When the plan renews or ends, as the web's `statusView` says it: a
  /// manual plan ending is a grant running out, nothing to warn of.
  String? _dateOf(LkcEntitlement e) {
    final end = e.periodEnd;
    if (end == null) return l10n.lkcNoEndDate;
    final date = _lkcDate(context, end);
    if (!e.cancelScheduled) return l10n.lkcRenewsOn(date);
    // A grant runs out; a paid plan set not to renew was canceled by the user.
    return e.source == LkcSource.manual
        ? l10n.lkcEndsOn(date)
        : l10n.lkcCancelsOn(date);
  }

  String _formatPrice(LkcPrice price) {
    final locale = Localizations.localeOf(context).toString();
    NumberFormat fmt;
    try {
      fmt = NumberFormat.simpleCurrency(
        locale: locale,
        name: price.currency.toUpperCase(),
      );
    } catch (_) {
      fmt = NumberFormat.simpleCurrency(name: price.currency.toUpperCase());
    }
    return fmt.format(price.amount / math.pow(10, fmt.decimalDigits ?? 2));
  }
}

/// The files stored in LKC Cloud, and how much of the quota they take.
final class LkcFilesPage extends StatefulWidget {
  final LkcPageArgs args;

  const LkcFilesPage({super.key, required this.args});

  static const route = AppRouteArg<void, LkcPageArgs>(
    page: LkcFilesPage.new,
    path: '/lkc/files',
  );

  @override
  State<LkcFilesPage> createState() => _LkcFilesPageState();
}

final class _LkcFilesPageState extends State<LkcFilesPage> {
  LkcClient get _client => widget.args.client;

  List<LkcFile>? _files;
  LkcUsage? _usage;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final list = await _client.files();
      final usage = await _client.usage();
      if (!mounted) return;
      setState(() {
        _files = list;
        _usage = usage;
      });
    } catch (e) {
      if (mounted) context._showLkcErr(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: CustomAppBar(
        title: Text(l10n.lkcFiles),
        actions: [
          Btn.icon(
            text: l10n.upload,
            icon: const Icon(Icons.upload),
            onTap: _upload,
          ),
          Btn.icon(
            text: l10n.refresh,
            icon: const Icon(Icons.refresh),
            onTap: () => context._runLkc(_load),
          ),
        ],
      ),
      body: files == null
          ? const Center(child: SizedLoading.medium)
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              children: [
                if (_usage case final usage?) _buildUsage(usage),
                if (files.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(37),
                    child: Center(child: Text(l10n.empty, style: UIs.textGrey)),
                  )
                else
                  CardX(
                    child: Column(children: files.map(_buildFile).toList()),
                  ),
              ],
            ),
    );
  }

  Widget _buildUsage(LkcUsage usage) {
    final quota = usage.quotaBytes;
    final files = l10n.lkcFileCount(usage.files);
    return CardX(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              quota == null
                  ? lkcBytes(usage.bytes)
                  : l10n.lkcUsageOf(lkcBytes(usage.bytes), lkcBytes(quota)),
            ),
            if (quota != null && quota > 0) ...[
              UIs.height7,
              LinearProgressIndicator(
                value: (usage.bytes / quota).clamp(0, 1).toDouble(),
              ),
            ],
            UIs.height7,
            Text(
              usage.quotaFiles == null ? files : '$files / ${usage.quotaFiles}',
              style: UIs.text12Grey,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFile(LkcFile file) {
    final date = _lkcDate(context, file.createdAt);
    return ListTile(
      title: Text(
        file.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('${lkcBytes(file.size)} · $date', style: UIs.text12Grey),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Btn.icon(
            text: l10n.download,
            icon: const Icon(Icons.download),
            onTap: () => _download(file),
          ),
          Btn.icon(
            text: l10n.delete,
            icon: const Icon(Icons.delete),
            onTap: () => _delete(file),
          ),
        ],
      ),
    );
  }

  Future<void> _download(LkcFile file) async {
    final link = await context._runLkc(() => _client.link(file.name));
    if (link == null) return;
    // The link signs the download: the browser saves it under its original name.
    await link.url.toString().launchUrl(mode: LaunchMode.externalApplication);
  }

  Future<void> _delete(LkcFile file) async {
    final ok = await context.showRoundDialog<bool>(
      title: l10n.delete,
      child: Text(l10n.askContinue('${l10n.delete} ${file.displayName}')),
      actions: Btnx.cancelRedOk,
    );
    if (ok != true || !mounted) return;
    await context._runLkc(() async {
      await _client.deleteFiles([file.name]);
      await _load();
    });
  }

  Future<void> _upload() async {
    final picked = await Pfs.pickFile();
    final path = picked?.path;
    if (picked == null || path == null || !mounted) return;
    final progress = ValueNotifier<double?>(null);
    unawaited(
      context.showRoundDialog(
        barrierDismiss: false,
        child: ValBuilder(
          listenable: progress,
          builder: (v) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(picked.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              UIs.height13,
              LinearProgressIndicator(value: v),
            ],
          ),
        ),
      ),
    );
    try {
      await _client.uploadFile(
        File(path),
        originalName: picked.name,
        onProgress: (sent, total) {
          if (total > 0) progress.value = sent / total;
        },
      );
      if (mounted) context.popDialog();
      await _load();
    } catch (e) {
      if (!mounted) return;
      context.popDialog();
      context._showLkcErr(e);
    } finally {
      progress.dispose();
    }
  }
}

extension on BuildContext {
  /// Run [fn] behind a loading dialog, an error told in the user's words.
  Future<T?> _runLkc<T>(Future<T> Function() fn) async {
    unawaited(
      showRoundDialog(child: SizedLoading.medium, barrierDismiss: false),
    );
    try {
      final ret = await fn();
      if (mounted) popDialog();
      return ret;
    } catch (e) {
      if (mounted) {
        popDialog();
        _showLkcErr(e);
      }
      return null;
    }
  }

  void _showLkcErr(Object? e) {
    if (e == null) return;
    final text = switch (e) {
      final LkcException e => e.text(l10n),
      _ => '$e',
    };
    showRoundDialog(title: l10n.fail, child: Text(text), actions: Btnx.oks);
  }
}

/// With its year: a plan's end is often a year or more away.
String _lkcDate(BuildContext context, DateTime d) {
  final locale = Localizations.localeOf(context).toString();
  try {
    return DateFormat.yMMMd(locale).format(d.toLocal());
  } catch (_) {
    return DateFormat.yMMMd().format(d.toLocal());
  }
}

/// The account's initial in a circle, for the row that leads to [LkcAccountPage].
final class LkcAvatar extends StatelessWidget {
  final LkcClient client;
  final double size;

  const LkcAvatar({super.key, required this.client, this.size = 32});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValBuilder(
      listenable: client.user,
      builder: (user) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Text(
          _initial(user?.name),
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w500,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

/// Who is signed in and the lines they hold, for the row that leads to [LkcAccountPage].
String lkcAccountSummary(LkcClient client) {
  final user = client.user.value;
  if (user == null) return l10n.lkcNotSignedIn;
  final lines = [
    for (final e in client.entitlements.value ?? const <LkcEntitlement>[])
      _lineName(e.line),
  ];
  return [user.name, if (lines.isNotEmpty) lines.join(', ')].join(' · ');
}

String _initial(String? name) {
  final c = name?.trim().characters.firstOrNull;
  return c == null ? '?' : c.toUpperCase();
}

/// The user's name, editable in place, and their id to copy.
final class _LkcProfileCard extends StatefulWidget {
  final LkcUser user;
  final LkcClient client;

  const _LkcProfileCard({required this.user, required this.client});

  @override
  State<_LkcProfileCard> createState() => _LkcProfileCardState();
}

final class _LkcProfileCardState extends State<_LkcProfileCard> {
  TextEditingController? _draft;
  bool _copied = false;

  @override
  void dispose() {
    _draft?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _draft?.text.trim() ?? '';
    if (name.isNotEmpty && name != widget.user.name) {
      await context._runLkc(() => widget.client.updateUser(name: name));
    }
    if (!mounted) return;
    setState(() {
      _draft?.dispose();
      _draft = null;
    });
  }

  void _copy() {
    Pfs.copy(widget.user.id);
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final draft = _draft;
    final muted = scheme.outline;
    return _LkcCard(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            LkcAvatar(client: widget.client, size: 48),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (draft == null)
                    Text(
                      widget.user.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    TextField(
                      controller: draft,
                      autofocus: true,
                      onSubmitted: (_) => _save(),
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHigh,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 5,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(7),
                          borderSide: BorderSide(color: scheme.outlineVariant),
                        ),
                      ),
                    ),
                  const SizedBox(height: 3),
                  InkWell(
                    onTap: _copy,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.user.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: muted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Icon(
                          _copied ? Icons.check : Icons.copy,
                          size: 14,
                          color: muted,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (draft == null)
              Btn.icon(
                text: l10n.name,
                icon: const Icon(Icons.edit, size: 20),
                onTap: () => setState(
                  () => _draft = TextEditingController(text: widget.user.name),
                ),
              )
            else
              Btn.icon(
                text: l10n.ok,
                icon: Icon(Icons.check, size: 20, color: scheme.primary),
                onTap: _save,
              ),
          ],
        ),
      ),
    );
  }
}

/// The page's single column, centered and no wider than the settings pages.
final class _Column extends StatelessWidget {
  final List<Widget> children;

  const _Column({required this.children});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 13),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 695),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: _Stack(children: children),
            ),
          ),
        ),
      ],
    );
  }
}

/// Sections one under another, 13 apart.
final class _Stack extends StatelessWidget {
  final List<Widget> children;

  const _Stack({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const SizedBox(height: 13),
          child,
        ],
      ],
    );
  }
}

final class _LkcCard extends StatelessWidget {
  final Widget child;

  const _LkcCard({required this.child});

  @override
  Widget build(BuildContext context) =>
      CardX(margin: EdgeInsets.zero, child: child);
}

/// Rows of a card, a hairline between each two.
final class _Rows extends StatelessWidget {
  final List<Widget> rows;

  const _Rows(this.rows);

  @override
  Widget build(BuildContext context) {
    final hairline = Theme.of(context).colorScheme.outlineVariant
        .withValues(alpha: 0.35);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) Container(height: 1, color: hairline),
          row,
        ],
      ],
    );
  }
}

/// A section's name, a rule, and what it says of the plan held.
final class _GroupTitle extends StatelessWidget {
  final String title;
  final String trailing;

  const _GroupTitle(this.title, this.trailing);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 11, color: scheme.outline);
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 4, 3, 7),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: muted.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(child: Container(height: 1, color: scheme.outlineVariant)),
          const SizedBox(width: 9),
          Text(trailing, style: muted),
        ],
      ),
    );
  }
}

final class _LkcTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? detail;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;

  const _LkcTile({
    required this.icon,
    required this.title,
    this.detail,
    this.trailing,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail = this.detail;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        child: Row(
          children: [
            _LeadIcon(icon, color: color),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: TextStyle(fontSize: 15, color: color)),
                  if (detail != null)
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.outline,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

final class _LeadIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const _LeadIcon(this.icon, {this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 24,
    child: Icon(
      icon,
      size: 22,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

final class _Chevron extends StatelessWidget {
  final IconData icon;

  const _Chevron({this.icon = Icons.chevron_right});

  @override
  Widget build(BuildContext context) => Icon(
    icon,
    size: 18,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}

IconData _benefitIcon(LkcBenefitKind kind) => switch (kind) {
  LkcBenefitKind.backups => Icons.backup,
  LkcBenefitKind.relay => Icons.swap_calls,
  LkcBenefitKind.uptime => Icons.monitor_heart,
  LkcBenefitKind.sync => Icons.sync,
  LkcBenefitKind.storage => Icons.cloud,
  LkcBenefitKind.shareLinks => Icons.link,
  LkcBenefitKind.credit => Icons.toll,
  LkcBenefitKind.concurrency => Icons.layers,
};

String _lineName(LkcLine line) => _title(line.name);

String _planName(String plan) => plan.split('.').map(_title).join(' ');

String _title(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
