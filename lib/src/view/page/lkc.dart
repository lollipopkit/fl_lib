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

  /// A sign-in from the deep link lands while the page is open.
  void _onUser() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      // One after another: a future failing while another is awaited is an
      // unhandled error. Without the benefits the plans still show, unworded.
      final b = await _client.benefits().then<LkcBenefits?>(
        (b) => b,
        onError: (_) => null,
      );
      final p = _client.webCheckout ? await _client.plans() : const <LkcPlan>[];
      if (_client.signedIn) await _client.refresh();
      if (!mounted) return;
      setState(() {
        _benefits = b ?? _benefits;
        _plans = p;
      });
    } catch (e) {
      if (mounted) context._showLkcErr(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _client.user.value;
    return Scaffold(
      appBar: widget.args.embedded
          ? null
          : CustomAppBar(
              title: Text(l10n.lkcAccount),
              actions: [
                Btn.icon(
                  text: l10n.refresh,
                  icon: const Icon(Icons.refresh),
                  onTap: () => context._runLkc(_load),
                ),
              ],
            ),
      body: ValBuilder(
        listenable: _client.entitlements,
        builder: (_) => RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            children: [
              if (user == null) _buildSignIn() else _buildUser(user),
              for (final line in const [
                LkcLine.basic,
                LkcLine.storage,
                LkcLine.conduit,
              ])
                _buildLine(line),
              if (user != null) _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSignIn() {
    return CardX(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.lkcSignInTip),
            UIs.height13,
            if (_signingIn)
              SizedLoading.small
            else
              Btn.elevated(
                text: l10n.lkcSignInBrowser,
                icon: const Icon(Icons.open_in_browser),
                onTap: _signIn,
              ),
          ],
        ),
      ),
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

  Widget _buildUser(LkcUser user) {
    final avatar = user.avatar;
    return CardX(
      child: ListTile(
        leading: CircleAvatar(
          foregroundImage: avatar == null ? null : NetworkImage(avatar),
          child: Text(user.name.characters.firstOrNull ?? '?'),
        ),
        title: Text(user.name),
        subtitle: Text(
          user.id,
          style: UIs.text12Grey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.edit, size: 19),
        onTap: () => _editName(user),
      ),
    );
  }

  Future<void> _editName(LkcUser user) async {
    final ctrl = TextEditingController(text: user.name);
    final ok = await context.showRoundDialog<bool>(
      title: l10n.name,
      child: Input(
        controller: ctrl,
        autoFocus: true,
        onSubmitted: (_) => context.popDialog(true),
      ),
      actions: Btnx.cancelOk,
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || name == user.name || !mounted) return;
    await context._runLkc(() => _client.updateUser(name: name));
  }

  Widget _buildLine(LkcLine line) {
    final held = _client.entitlementOf(line);
    final tier = held?.plan ?? LkcBenefits.free;
    final benefits = _benefits?.lines(l10n, tier, line) ?? const <String>[];
    final onSale = [
      for (final plan in _plans ?? const <LkcPlan>[])
        if (plan.line == line && plan.stripe != null) plan,
    ];
    final signedIn = _client.signedIn;
    if (held == null && benefits.isEmpty && onSale.isEmpty) {
      return UIs.placeholder;
    }

    final status = held == null ? null : _statusOf(held);
    final summary = [
      if (signedIn) held == null ? l10n.lkcFreeTier : _planName(held.plan),
      ?status,
    ].join(' · ');
    return CardX(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(_lineName(line), style: UIs.text15Bold),
              subtitle: summary.isEmpty ? null : Text(summary),
            ),
            if (signedIn) ..._benefitTexts(benefits),
            for (final plan in onSale)
              if (plan.id != held?.plan) _buildPlan(plan, signedIn),
          ],
        ),
      ),
    );
  }

  Iterable<Widget> _benefitTexts(List<String> lines) => lines.map(
    (text) => Padding(
      padding: const EdgeInsets.fromLTRB(17, 0, 17, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(Icons.check, size: 15),
          ),
          const SizedBox(width: 7),
          Expanded(child: Text(text, style: UIs.text13)),
        ],
      ),
    ),
  );

  Widget _buildPlan(LkcPlan plan, bool signedIn) {
    final price = plan.stripe!;
    final formatted = _formatPrice(price);
    final lines =
        _benefits?.lines(l10n, plan.id, plan.line) ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 13),
        ListTile(
          title: Text(_planName(plan.id)),
          subtitle: Text(switch (plan.period) {
            LkcPeriod.year => l10n.lkcPerYear(formatted),
            _ => l10n.lkcPerMonth(formatted),
          }),
          trailing: signedIn
              ? Btn.text(
                  text: l10n.lkcSubscribe,
                  onTap: () =>
                      context._runLkc(() => _client.openCheckout(plan.id)),
                )
              : null,
        ),
        ..._benefitTexts(lines),
      ],
    );
  }

  Widget _buildActions() {
    final ents = _client.entitlements.value ?? const <LkcEntitlement>[];
    final webSubscribed = ents.any((e) => e.source == LkcSource.stripe);
    return CardX(
      child: Column(
        children: [
          if (_client.webCheckout && webSubscribed)
            ListTile(
              leading: const Icon(Icons.credit_card),
              title: Text(l10n.lkcManageSubscriptions),
              trailing: const Icon(Icons.open_in_new, size: 19),
              onTap: () => context._runLkc(_client.openPortal),
            ),
          ListTile(
            leading: const Icon(Icons.folder),
            title: Text(l10n.lkcFiles),
            trailing: const Icon(Icons.chevron_right),
            // Over the whole window from a page embedded in another: in its
            // pane it would draw a second title bar under the host's.
            onTap: () => LkcFilesPage.route.go(
              context,
              LkcPageArgs(_client),
              target: widget.args.embedded ? NavTarget.root : NavTarget.nearest,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(l10n.logout),
            onTap: _signOut,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(l10n.lkcDeleteAccount, style: UIs.textRed),
            onTap: _deleteAccount,
          ),
        ],
      ),
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
    if (store == null || !mounted) return;
    final ok = await context.showRoundDialog<bool>(
      title: '${l10n.lkcDeleteAccount}?',
      child: Text(
        [
          if (store) l10n.lkcStoreSubscriptionTip,
          l10n.lkcDeleteAccountTip,
        ].join('\n\n'),
      ),
      actions: Btnx.cancelRedOk,
    );
    if (ok != true || !mounted) return;
    await context._runLkc(_client.deleteAccount);
  }

  String? _statusOf(LkcEntitlement e) {
    return switch (e.status) {
      LkcStatus.pastDue => l10n.lkcPastDue,
      LkcStatus.paused => l10n.lkcPaused,
      _ => _dateOf(e),
    };
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

String _lineName(LkcLine line) => _title(line.name);

String _planName(String plan) => plan.split('.').map(_title).join(' ');

String _title(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
