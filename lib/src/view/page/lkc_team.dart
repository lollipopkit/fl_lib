part of 'lkc.dart';

/// The account's teams: unlocking the account key, each team's members and
/// keys, and what an admin's device does for them. Every key handed out is
/// checked in Rust; this page asks the person to compare fingerprints
/// wherever that is the only check there is.
final class LkcTeamsPage extends StatefulWidget {
  final LkcPageArgs args;

  const LkcTeamsPage({super.key, required this.args});

  static const route = AppRouteArg<void, LkcPageArgs>(
    page: LkcTeamsPage.new,
    path: '/lkc/teams',
  );

  @override
  State<LkcTeamsPage> createState() => _LkcTeamsPageState();
}

/// A team as the list shows it: what homebase lists, and what this device
/// checked of it (or why it could not).
final class _TeamEntry {
  final LkcTeam team;
  final LkcTeamStatus? status;
  final LkcTeamError? error;

  const _TeamEntry(this.team, {this.status, this.error});

  bool get stopped => error?.kind == LkcTeamErrorKind.untrusted || error?.kind == LkcTeamErrorKind.crypto;
}

final class _LkcTeamsPageState extends State<LkcTeamsPage> {
  LkcClient get _client => widget.args.client;
  late final _account = LkcTeamAccount(_client);

  LkcTeamKeys? _keys;

  /// Whether a device of the account made its key: asked for, else set.
  bool? _hasKey;
  Object? _openFailed;
  List<_TeamEntry> _teams = const [];
  String? _selected;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    if (_openFailed != null) setState(() => _openFailed = null);
    try {
      final keys = await _account.open();
      if (keys != null) {
        _keys = keys;
        await _load();
        return;
      }
      final has = await (await _client.teams()).hasAccountKey();
      if (mounted) setState(() => _hasKey = has);
    } catch (e) {
      if (mounted) setState(() => _openFailed = e);
    }
  }

  Future<void> _load() async {
    final keys = _keys;
    if (keys == null || _loading) return;
    setState(() => _loading = true);
    try {
      final teams = await (await _client.teams()).list();
      final entries = <_TeamEntry>[];
      for (final t in teams) {
        if (!t.approved) {
          entries.add(_TeamEntry(t));
          continue;
        }
        try {
          entries.add(_TeamEntry(t, status: await keys.status(team: t.id)));
        } on LkcTeamError catch (e) {
          if (e.kind == LkcTeamErrorKind.accountKeyReplaced) {
            await _account.forget();
            if (mounted) setState(() => _keys = null);
            await _open();
            if (mounted) context.showSnackBar(l10n.lkcTeamKeyReplaced);
            return;
          }
          entries.add(_TeamEntry(t, error: e));
        }
      }
      if (mounted) setState(() => _teams = entries);
    } catch (e) {
      if (mounted) context._showTeamErr(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  _TeamEntry? get _entry => _teams.where((e) => e.team.id == _selected).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    return Scaffold(
      appBar: CustomAppBar(
        title: Text(l10n.lkcTeams),
        actions: [
          if (keys != null) ...[
            Btn.icon(icon: const Icon(Icons.link, size: 18), onTap: _join),
            Btn.icon(icon: const Icon(Icons.add, size: 18), onTap: _create),
            Btn.icon(icon: const Icon(Icons.lock_outline, size: 18), onTap: _lock),
          ],
        ],
      ),
      body: Stack(
        children: [
          if (keys == null)
            switch ((_hasKey, _openFailed)) {
              (final bool has, _) => _Unlock(hasKey: has, onUnlock: _unlock),
              (null, final Object e) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 13,
                  children: [Text(_teamErrText(e), textAlign: TextAlign.center), Btn.text(text: l10n.retry, onTap: _open)],
                ),
              ),
              _ => const Center(child: SizedLoading(23)),
            }
          else
            _buildTeams(),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _loading ? 1 : 0,
              duration: _kFade,
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTeams() {
    return LayoutBuilder(
      builder: (context, box) {
        final split = box.maxWidth >= AdaptivePanes.kSplitWidth;
        final entry = _entry;
        final list = RefreshIndicator(onRefresh: _load, child: _buildList());
        if (!split) {
          if (entry == null) return list;
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (popped, _) {
              if (!popped) setState(() => _selected = null);
            },
            child: _TeamDetail(
              client: _client,
              entry: entry,
              keys: _keys!,
              onBack: () => setState(() => _selected = null),
              onChanged: _load,
            ),
          );
        }
        final hairline = Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 330, child: list),
            Container(width: 1, color: hairline),
            Expanded(
              child: entry == null
                  ? Center(child: Icon(Icons.group, size: 56, color: Theme.of(context).colorScheme.outlineVariant))
                  : _TeamDetail(key: ValueKey(entry.team.id), client: _client, entry: entry, keys: _keys!, onChanged: _load),
            ),
          ],
        );
      },
    );
  }

  Widget _buildList() {
    final scheme = Theme.of(context).colorScheme;
    if (_teams.isEmpty && !_loading) {
      return ListView(
        children: [
          const SizedBox(height: 60),
          Icon(Icons.group, size: 56, color: scheme.outlineVariant),
          const SizedBox(height: 9),
          Center(child: Text(l10n.lkcTeamNone, style: TextStyle(color: scheme.outline))),
          const SizedBox(height: 13),
          Center(
            child: FilledButton.tonalIcon(onPressed: _create, icon: const Icon(Icons.group_add), label: Text(l10n.lkcTeamNew)),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 26),
      children: [
        for (final e in _teams)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: CardX(
              color: e.team.id == _selected ? scheme.secondaryContainer : null,
              child: InkWell(
                onTap: () => setState(() => _selected = e.team.id),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: _TeamSummary(entry: e),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _unlock(String password) async {
    final keys = await context._runTeam(() async => (await _account.unlock(password)).$1);
    if (keys == null || !mounted) return;
    setState(() => _keys = keys);
    await _load();
  }

  Future<void> _lock() async {
    await _account.forget();
    if (!mounted) return;
    setState(() {
      _keys = null;
      _teams = const [];
      _selected = null;
      _hasKey = true;
    });
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    final name = await context.showSheet<String>(
      title: l10n.lkcTeamNew,
      child: Input(controller: ctrl, autoFocus: true, label: l10n.lkcTeamName, onSubmitted: (v) => context.popSheet(v.trim())),
      actions: [Btn.cancel(), Btn.ok(onTap: () => context.popSheet(ctrl.text.trim()))],
    );
    if (name == null || name.isEmpty || !mounted) return;
    final id = await context._runTeam(() async => (await _client.teams()).create(name: name));
    if (id == null || !mounted) return;
    setState(() => _selected = id);
    await _load();
  }

  Future<void> _join() async {
    final ctrl = TextEditingController();
    final link = await context.showSheet<String>(
      title: l10n.lkcTeamJoin,
      child: Input(controller: ctrl, autoFocus: true, label: l10n.lkcTeamJoinLink, onSubmitted: (v) => context.popSheet(v.trim())),
      actions: [Btn.cancel(), Btn.ok(onTap: () => context.popSheet(ctrl.text.trim()))],
    );
    if (link == null || link.isEmpty || !mounted) return;
    final (token, secret) = _parseInvite(link);
    if (token == null) {
      context.showSnackBar(l10n.fail);
      return;
    }
    final joined = await context._runTeam(() => _keys!.join(token: token, secret: secret));
    if (joined == null || !mounted) return;
    setState(() => _selected = joined.teamId);
    await _load();
  }
}

/// The token and the fragment of an invite link (`…/teams/join/{token}#{secret}`).
(String?, String?) _parseInvite(String link) {
  final hash = link.indexOf('#');
  final secret = hash < 0 ? null : link.substring(hash + 1);
  final path = hash < 0 ? link : link.substring(0, hash);
  final token = path.split('/').where((s) => s.isNotEmpty).lastOrNull;
  return (token, secret == null || secret.isEmpty ? null : secret);
}

/// Opening the account key: set the first time on any device, asked for after.
final class _Unlock extends StatefulWidget {
  final bool hasKey;
  final Future<void> Function(String password) onUnlock;

  const _Unlock({required this.hasKey, required this.onUnlock});

  @override
  State<_Unlock> createState() => _UnlockState();
}

final class _UnlockState extends State<_Unlock> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _pw.text;
    if (!widget.hasKey) {
      final error = pw.length < 8 ? l10n.lkcTeamPasswordShort : (pw != _pw2.text ? l10n.lkcTeamPasswordMismatch : null);
      setState(() => _error = error);
      if (error != null) return;
    }
    await widget.onUnlock(pw);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final set = !widget.hasKey;
    return ListView(
      padding: const EdgeInsets.all(13),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _LkcCard(
              child: Padding(
                padding: const EdgeInsets.all(17),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 13,
                  children: [
                    Text(
                      set ? l10n.lkcTeamSetKeyPassword : l10n.lkcTeamUnlockTitle,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    if (set) Text(l10n.lkcTeamSetKeyPasswordTip, style: TextStyle(color: scheme.onSurfaceVariant)),
                    Input(
                      controller: _pw,
                      autoFocus: true,
                      obscureText: true,
                      type: TextInputType.visiblePassword,
                      label: l10n.lkcTeamKeyPassword,
                      icon: Icons.key,
                      onSubmitted: (_) => set ? null : _submit(),
                    ),
                    if (set)
                      Input(
                        controller: _pw2,
                        obscureText: true,
                        type: TextInputType.visiblePassword,
                        label: l10n.lkcTeamRepeat,
                        icon: Icons.key,
                        onSubmitted: (_) => _submit(),
                      ),
                    if (_error != null) Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12)),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(onPressed: _submit, child: Text(l10n.lkcTeamUnlock)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A team's name, its epoch and size, and what needs attention.
final class _TeamSummary extends StatelessWidget {
  final _TeamEntry entry;

  const _TeamSummary({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = entry.team;
    final s = entry.status;
    final keyed = s?.members.where((m) => m.approved && m.keyed).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 7,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Text(l10n.lkcTeamEpoch(t.epoch), style: _caption(scheme)),
          ],
        ),
        Text(
          [l10n.lkcTeamMemberCount(t.memberCount), if (keyed != null) l10n.lkcTeamKeyedCount(keyed)].join(' · '),
          style: _caption(scheme),
        ),
        if (_flags(entry).isNotEmpty) Wrap(spacing: 5, runSpacing: 5, children: _flags(entry)),
      ],
    );
  }
}

List<Widget> _flags(_TeamEntry e) {
  final s = e.status;
  return [
    if (!e.team.approved) _Chip(Icons.hourglass_top, l10n.lkcTeamWaitingApproval, _Tone.warn),
    if (e.stopped) _Chip(Icons.gpp_bad, l10n.lkcTeamStopped, _Tone.err),
    if (e.error?.kind == LkcTeamErrorKind.unkeyed) _Chip(Icons.hourglass_top, l10n.lkcTeamAwaitingKey, _Tone.warn),
    if (s != null) ...[
      if (s.epoch == 0) _Chip(Icons.pending, l10n.lkcTeamFirstKeyDue, _Tone.warn),
      if (s.rotationNeeded) _Chip(Icons.autorenew, l10n.lkcTeamRotationNeeded, _Tone.warn),
      if (s.members.any((m) => m.approved && !m.keyed) && s.epoch > 0) _Chip(Icons.hourglass_top, l10n.lkcTeamMembersAwaitingKey, _Tone.warn),
      if (s.members.any((m) => m.changed)) _Chip(Icons.change_circle, l10n.lkcTeamKeyChanges, _Tone.err),
      if (!s.migrated) _Chip(Icons.sync, l10n.lkcTeamMigrating, _Tone.idle),
    ],
  ];
}

enum _Tone { ok, warn, err, idle, role }

/// A state in words, with its icon: 7px radius, outlined unless a role.
final class _Chip extends StatelessWidget {
  final IconData? icon;
  final String text;
  final _Tone tone;

  const _Chip(this.icon, this.text, this.tone);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final color = switch (tone) {
      _Tone.ok => dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D),
      _Tone.warn => dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
      _Tone.err => scheme.error,
      _Tone.idle => scheme.outline,
      _Tone.role => scheme.onSecondaryContainer,
    };
    final role = tone == _Tone.role;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: role ? scheme.secondaryContainer : null,
        border: role ? null : Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 3,
        children: [
          if (icon != null) Icon(icon, size: 13, color: color),
          Text(text, style: TextStyle(fontSize: 11, color: color, height: 1)),
        ],
      ),
    );
  }
}

TextStyle _caption(ColorScheme scheme) =>
    TextStyle(fontSize: 12, color: scheme.outline, fontFeatures: const [FontFeature.tabularFigures()]);

String _roleText(String role) => switch (role) {
  'owner' => l10n.lkcTeamRoleOwner,
  'admin' => l10n.lkcTeamRoleAdmin,
  _ => l10n.lkcTeamRoleMember,
};

bool _manages(String role) => role == 'owner' || role == 'admin';

/// A fingerprint's five groups in a monospace face, those differing from
/// [other] marked.
final class _Fingerprint extends StatelessWidget {
  final String value;
  final String? other;
  final double size;

  const _Fingerprint(this.value, {this.other, this.size = 15});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = value.split(' ');
    final theirs = other?.split(' ');
    return Wrap(
      spacing: 9,
      runSpacing: 2,
      children: [
        for (final (i, g) in mine.indexed)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: theirs != null && (i >= theirs.length || theirs[i] != g) ? scheme.tertiaryContainer : null,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              g,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Menlo', 'Consolas', 'Roboto Mono'],
                fontSize: size,
                letterSpacing: 0.6,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }
}

/// A labelled fingerprint on a raised surface.
final class _FingerprintCard extends StatelessWidget {
  final String label;
  final String value;
  final String? other;

  const _FingerprintCard(this.label, this.value, {this.other});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(7)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 3,
        children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 11, color: scheme.outline, letterSpacing: 0.9)),
          _Fingerprint(value, other: other, size: other == null ? 15 : 13),
        ],
      ),
    );
  }
}

/// One team: its state, its members, and what this account may do in it.
final class _TeamDetail extends StatefulWidget {
  final LkcClient client;
  final _TeamEntry entry;
  final LkcTeamKeys keys;
  final VoidCallback? onBack;
  final Future<void> Function() onChanged;

  const _TeamDetail({super.key, required this.client, required this.entry, required this.keys, this.onBack, required this.onChanged});

  @override
  State<_TeamDetail> createState() => _TeamDetailState();
}

final class _TeamDetailState extends State<_TeamDetail> {
  LkcTeam get _team => widget.entry.team;
  LkcTeamStatus? get _status => widget.entry.status;
  LkcTeamKeys get _keys => widget.keys;
  bool get _admin => _manages(_status?.role ?? _team.role);
  bool get _owner => (_status?.role ?? _team.role) == 'owner';

  Future<void> _after(Future<void> Function() fn, {String? done}) async {
    final ok = await context._runTeam(() async {
      await fn();
      return true;
    });
    if (ok == true) {
      await widget.onChanged();
      if (done != null && mounted) context.showSnackBar(done);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _status;
    final e = widget.entry;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 26),
      children: [
        Row(
          children: [
            if (widget.onBack != null) Btn.icon(icon: const Icon(Icons.arrow_back, size: 18), onTap: widget.onBack!),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 9, 9, 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 5,
                  children: [
                    Text(_team.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                    Text(
                      [
                        l10n.lkcTeamEpoch(s?.epoch ?? _team.epoch),
                        if (s != null) s.migrated ? l10n.lkcTeamMigrated : l10n.lkcTeamMigrating,
                        l10n.lkcTeamMemberCount(_team.memberCount),
                      ].join(' · '),
                      style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        ..._banners(e, s).map((b) => Padding(padding: const EdgeInsets.only(bottom: 4), child: b)),
        if (s != null) ...[
          _actions(s),
          _GroupLabel(l10n.lkcTeamMemberCount(s.members.length)),
          _LkcCard(
            child: _Rows([
              for (final m in s.members) _MemberRow(member: m, me: m.userId == _client.user.value?.id, onTap: () => _openMember(m)),
            ]),
          ),
        ],
      ],
    );
  }

  LkcClient get _client => widget.client;

  List<Widget> _banners(_TeamEntry e, LkcTeamStatus? s) {
    final error = e.error;
    return [
      if (e.stopped)
        _Banner(
          icon: Icons.gpp_bad,
          title: l10n.lkcTeamUntrusted,
          error: true,
          action: (l10n.lkcTeamRefetch, widget.onChanged),
        ),
      if (error != null && !_bannered.contains(error.kind))
        _Banner(icon: Icons.error_outline, title: _teamErrText(error), error: true, action: (l10n.retry, widget.onChanged)),
      if (error?.kind == LkcTeamErrorKind.unkeyed) _Banner(icon: Icons.hourglass_top, title: l10n.lkcTeamAwaitingKey),
      if (error?.kind == LkcTeamErrorKind.signingKeyChanged)
        _Banner(
          icon: Icons.change_circle,
          title: l10n.lkcTeamKeyChangedTitle(error!.users.firstOrNull ?? ''),
          action: (l10n.lkcTeamCompare, () => _acceptChange(error.users.first, error.signingKey!, null, error.fingerprint)),
        ),
      if (error?.kind == LkcTeamErrorKind.recoveryEpoch)
        _Banner(
          icon: Icons.restart_alt,
          title: l10n.lkcTeamRecoveryTitle(error!.users.firstOrNull ?? ''),
          error: true,
          action: (l10n.lkcTeamCompare, () => _acceptRecovery(error)),
        ),
      if (s != null && s.epoch == 0 && _admin)
        _Banner(icon: Icons.fingerprint, title: l10n.lkcTeamFirstKey, action: (l10n.lkcTeamMakeFirstKey, () => _firstKey(s))),
      if (s != null && s.rotationNeeded && _admin)
        _Banner(icon: Icons.autorenew, title: l10n.lkcTeamRotationNeeded, action: (l10n.lkcTeamRotate, _rotate)),
      if (s != null && s.epoch > 0 && !s.mayCommit && _admin) _Banner(icon: Icons.info_outline, title: l10n.lkcTeamPromotionNeeded),
      if (s != null && s.skippedEpochs.isNotEmpty)
        _Banner(icon: Icons.history, title: l10n.lkcTeamSkippedEpochs(s.skippedEpochs.length)),
    ];
  }

  Widget _actions(LkcTeamStatus s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        spacing: 4,
        children: [
          _ActionTile(Icons.person_add, l10n.lkcTeamInvite, _admin && s.epoch > 0 ? _invite : null),
          _ActionTile(Icons.autorenew, l10n.lkcTeamRotate, _admin && s.epoch > 0 ? _rotate : null),
          _ActionTile(Icons.logout, l10n.lkcTeamLeave, _owner ? null : _leave),
        ],
      ),
    );
  }

  Future<void> _openMember(LkcMember m) async {
    final me = m.userId == _client.user.value?.id;
    final fp = m.fingerprint;
    final act = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 0, 7, 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 2,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 0, 13, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 5,
                  children: [
                    Text(me ? '${m.name} (${l10n.lkcTeamMe})' : m.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    Wrap(spacing: 5, runSpacing: 5, children: _memberChips(m)),
                  ],
                ),
              ),
              if (fp != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(7, 0, 7, 7),
                  child: m.changed && m.previousFingerprint != null
                      ? Column(
                          spacing: 7,
                          children: [
                            _FingerprintCard(l10n.lkcTeamPrevious, m.previousFingerprint!, other: fp),
                            _FingerprintCard(l10n.lkcTeamCurrent, fp, other: m.previousFingerprint),
                          ],
                        )
                      : _FingerprintCard(l10n.lkcTeamFingerprint, fp),
                ),
              if (!me && m.changed) _sheetTile(ctx, Icons.change_circle, l10n.lkcTeamKeyChangedTitle(m.name), 'change'),
              if (!me && !m.compared && !m.changed && fp != null) _sheetTile(ctx, Icons.fingerprint, l10n.lkcTeamCompare, 'compare'),
              if (!me && fp != null && m.approved && !m.keyed && _admin && (_status?.epoch ?? 0) > 0) _sheetTile(ctx, Icons.key, l10n.lkcTeamGrant, 'grant'),
              if (!me && !m.approved && _admin) _sheetTile(ctx, Icons.how_to_reg, l10n.lkcTeamApprove, 'approve'),
              if (!me && fp != null && _owner && m.approved && m.role == 'member') _sheetTile(ctx, Icons.arrow_upward, l10n.lkcTeamPromote, 'promote'),
              if (!me && _owner && m.role == 'admin') _sheetTile(ctx, Icons.arrow_downward, l10n.lkcTeamDemote, 'demote'),
              if (!me && fp != null && _owner && m.approved) _sheetTile(ctx, Icons.swap_horiz, l10n.lkcTeamTransfer, 'transfer'),
              if (!me && _admin && m.role != 'owner') _sheetTile(ctx, Icons.person_remove, l10n.lkcTeamRemove, 'remove', destructive: true),
            ],
          ),
        ),
      ),
    );
    if (act == null || !mounted) return;
    final team = _team.id;
    switch (act) {
      case 'change':
        await _acceptChange(m.userId, m.signingKey!, m.previousFingerprint, fp);
      case 'compare':
        if (await _gate(m, l10n.lkcTeamCompare, l10n.lkcTeamCompared) && mounted) {
          await _after(() => _keys.markCompared(team: team, userId: m.userId, fingerprint: fp!));
        }
      case 'grant':
        if (await _gate(m, l10n.lkcTeamGrant, l10n.lkcTeamGrant) && mounted) {
          await _after(() => _keys.grant(team: team, userId: m.userId, fingerprint: fp!), done: l10n.lkcTeamHoldsKey);
        }
      case 'approve':
        await _after(() => _keys.approve(team: team, userId: m.userId));
      case 'promote':
        if (await _gate(m, l10n.lkcTeamPromote, l10n.lkcTeamPromote) && mounted) {
          await _after(() => _keys.setRole(team: team, userId: m.userId, role: 'admin', fingerprint: fp!));
        }
      case 'demote':
        await _after(() => _keys.setRole(team: team, userId: m.userId, role: 'member', fingerprint: ''));
      case 'transfer':
        if (await _gate(m, l10n.lkcTeamTransfer, l10n.lkcTeamTransfer, note: l10n.lkcTeamTransferConfirm(m.name)) && mounted) {
          await _after(() => _keys.transfer(team: team, userId: m.userId, fingerprint: fp!));
        }
      case 'remove':
        final ok = await context.showSheet<bool>(
          title: l10n.lkcTeamRemove,
          child: Text(l10n.lkcTeamRemoveConfirm(m.name)),
          actions: Btnx.cancelRedOk,
        );
        if (ok == true && mounted) await _after(() => _keys.removeMember(team: team, userId: m.userId));
    }
  }

  Widget _sheetTile(BuildContext ctx, IconData icon, String title, String act, {bool destructive = false}) {
    final color = destructive ? Theme.of(ctx).colorScheme.error : null;
    return _LkcTile(icon: icon, title: title, color: color, onTap: () => Navigator.of(ctx).pop(act));
  }

  /// Asks the person to compare [m]'s fingerprint before [action]; true once
  /// they tick that it matches.
  Future<bool> _gate(LkcMember m, String title, String action, {String? note}) async {
    var ok = false;
    final res = await context.showSheet<bool>(
      title: title,
      childBuilder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 13,
          children: [
            if (note != null) Text(note),
            _FingerprintCard(m.name, m.fingerprint!),
            CheckboxListTile(
              value: ok,
              onChanged: (v) => set(() => ok = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.lkcTeamComparedCheck(m.name), style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
      actionsBuilder: (ctx) => [
        Btn.cancel(),
        Btn.text(text: action, onTap: () => ctx.popSheet(true)),
      ],
    );
    // The tick is the confirmation: an OK without it confirms nothing.
    return res == true && ok;
  }

  Future<void> _acceptChange(String userId, String signingKey, String? before, String? now) async {
    final name = _status?.members.where((m) => m.userId == userId).firstOrNull?.name ?? userId;
    final res = await context.showSheet<bool>(
      title: l10n.lkcTeamKeyChangedTitle(name),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 13,
        children: [
          Text(l10n.lkcTeamKeyChangedTip),
          if (before != null) _FingerprintCard(l10n.lkcTeamPrevious, before, other: now),
          if (now != null) _FingerprintCard(l10n.lkcTeamCurrent, now, other: before),
        ],
      ),
      actions: [
        Btn.text(text: l10n.lkcTeamDontTrust, onTap: () => context.popSheet(false)),
        // Nothing to compare: not taken.
        if (now != null) Btn.text(text: l10n.lkcTeamTrustNew, onTap: () => context.popSheet(true)),
      ],
    );
    if (res != true || !mounted) return;
    await _after(() async {
      await _keys.acceptSigningKey(userId: userId, signingKey: signingKey);
      // Their current keys only: a change met in an older record is of keys
      // since replaced.
      final current = _status?.members.where((m) => m.userId == userId).firstOrNull?.fingerprint;
      if (now != null && now == current) await _keys.markCompared(team: _team.id, userId: userId, fingerprint: now);
    });
  }

  /// The owner's new start, under a key compared with them first.
  Future<void> _acceptRecovery(LkcTeamError error) async {
    final owner = error.users.first;
    final (epoch, signingKey, fp) = (error.epoch!, error.signingKey!, error.fingerprint);
    final name = _status?.members.where((m) => m.userId == owner).firstOrNull?.name ?? owner;
    final res = await context.showSheet<bool>(
      title: l10n.lkcTeamRecoveryTitle(name),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 13,
        children: [Text(l10n.lkcTeamRecoveryTip), if (fp != null) _FingerprintCard(l10n.lkcTeamCurrent, fp)],
      ),
      actions: [
        Btn.text(text: l10n.lkcTeamDontTrust, onTap: () => context.popSheet(false)),
        if (fp != null) Btn.text(text: l10n.lkcTeamAcceptRecovery, onTap: () => context.popSheet(true)),
      ],
    );
    if (res != true || !mounted) return;
    await _after(() => _keys.acceptRecovery(team: _team.id, epoch: epoch, userId: owner, signingKey: signingKey));
  }

  /// Every other member's fingerprint compared, then the team's first key.
  Future<void> _firstKey(LkcTeamStatus s) async {
    final others = s.members.where((m) => m.approved && m.userId != _client.user.value?.id && m.fingerprint != null).toList();
    final confirmed = await _compareAll(others, l10n.lkcTeamMakeFirstKey);
    if (confirmed == null || !mounted) return;
    await _after(() => _keys.commitFirst(team: _team.id, confirmed: confirmed), done: l10n.lkcTeamRotated(1));
  }

  /// The fingerprints of [members] the person ticked, or null when cancelled.
  Future<List<String>?> _compareAll(List<LkcMember> members, String action) async {
    if (members.isEmpty) return const [];
    final ticked = <String>{};
    return context.showSheet<List<String>>(
      title: l10n.lkcTeamCompare,
      childBuilder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckboxListTile(
                  value: ticked.length == members.length,
                  onChanged: (v) => set(() => v == true ? ticked.addAll(members.map((m) => m.userId)) : ticked.clear()),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(l10n.lkcTeamAllMatch, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                for (final m in members)
                  CheckboxListTile(
                    value: ticked.contains(m.userId),
                    onChanged: (v) => set(() => v == true ? ticked.add(m.userId) : ticked.remove(m.userId)),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(m.name),
                    subtitle: _Fingerprint(m.fingerprint!, size: 13),
                  ),
              ],
            ),
          ),
        ),
      ),
      actionsBuilder: (ctx) => [
        Btn.cancel(),
        Btn.text(
          text: action,
          onTap: () => ctx.popSheet([for (final m in members) if (ticked.contains(m.userId)) m.fingerprint!]),
        ),
      ],
    );
  }

  Future<void> _rotate() async {
    final ok = await context.showSheet<bool>(
      title: l10n.lkcTeamRotate,
      child: Text(l10n.lkcTeamRotateConfirm),
      actions: Btnx.cancelOk,
    );
    if (ok != true || !mounted) return;
    await _rotateWith(const []);
  }

  Future<void> _rotateWith(List<String> confirmed) async {
    final team = _team.id;
    final progress = ValueNotifier(l10n.lkcTeamRotating);
    VoidCallback? close;
    final shown = context.showSheet(
      dismissible: false,
      onShown: (c) => close = c,
      child: ValueListenableBuilder(
        valueListenable: progress,
        builder: (_, text, _) => Row(spacing: 13, children: [const SizedLoading(23), Expanded(child: Text(text))]),
      ),
    );
    Object? failure;
    String? done;
    try {
      final epoch = await _keys.rotate(team: team, confirmed: confirmed);
      progress.value = l10n.lkcTeamReencrypting;
      final r = await _keys.reencrypt(team: team);
      done = switch (r.outcome) {
        LkcReencrypted.migrated => l10n.lkcTeamRotated(epoch),
        LkcReencrypted.snapshotNeeded => l10n.lkcTeamSnapshotNeeded,
        LkcReencrypted.unreadable => l10n.lkcTeamUnreadable(r.unreadable.length),
      };
    } catch (e) {
      failure = e;
    }
    close?.call();
    // Once the sheet is gone: its exit still listens.
    await shown;
    progress.dispose();
    if (!mounted) return;
    if (failure case LkcTeamError(kind: LkcTeamErrorKind.unconfirmed, :final users)) {
      // Read again: they may have joined after the status shown.
      final status = await context._runTeam(() => _keys.status(team: team));
      if (status == null || !mounted) return;
      final members = status.members.where((m) => users.contains(m.userId) && m.fingerprint != null).toList();
      if (members.length < users.length) {
        context._showTeamErr(failure);
        return;
      }
      final more = await _compareAll(members, l10n.lkcTeamRotate);
      if (more != null && mounted) await _rotateWith([...confirmed, ...more]);
      return;
    }
    if (failure != null) {
      context._showTeamErr(failure);
      return;
    }
    await widget.onChanged();
    if (mounted && done != null) context.showSnackBar(done);
  }

  Future<void> _invite() async {
    var days = 7.0, uses = 1.0, keyed = true;
    final go = await context.showSheet<bool>(
      title: l10n.lkcTeamInvite,
      childBuilder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.lkcTeamInviteDays, style: _caption(Theme.of(ctx).colorScheme)),
            Row(
              children: [
                Expanded(child: Slider(value: days, min: 1, max: 7, divisions: 6, onChanged: (v) => set(() => days = v))),
                SizedBox(width: 64, child: Text(l10n.lkcTeamDays(days.round()), textAlign: TextAlign.end)),
              ],
            ),
            Text(l10n.lkcTeamInviteUses, style: _caption(Theme.of(ctx).colorScheme)),
            Row(
              children: [
                Expanded(child: Slider(value: uses, min: 1, max: 100, divisions: 99, onChanged: (v) => set(() => uses = v))),
                SizedBox(width: 64, child: Text('${uses.round()}', textAlign: TextAlign.end)),
              ],
            ),
            RadioGroup<bool>(
              groupValue: keyed,
              onChanged: (v) => set(() => keyed = v ?? true),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    value: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.lkcTeamInviteWithKey),
                  ),
                  RadioListTile<bool>(
                    value: false,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.lkcTeamInviteWithoutKey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [Btn.cancel(), Btn.text(text: l10n.lkcTeamCreateLink, onTap: () => context.popSheet(true))],
    );
    if (go != true || !mounted) return;
    final link = await context._runTeam(
      () => _keys.createInvite(team: _team.id, uses: uses.round(), days: days.round(), keyed: keyed),
    );
    if (link == null || !mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final until = DateTime.tryParse(link.expiresAt);
    await context.showSheet<void>(
      title: l10n.lkcTeamInviteLink,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 13,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(color: scheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(7)),
            child: SelectableText(link.url, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
          if (until != null) Text(l10n.lkcTeamInviteTerms(_lkcDate(context, until), uses.round()), style: _caption(scheme)),
          if (link.secret != null) _Banner(icon: Icons.warning_amber, title: l10n.lkcTeamInviteSecretTip),
        ],
      ),
      actions: [
        Btn.text(
          text: l10n.copy,
          onTap: () {
            Clipboard.setData(ClipboardData(text: link.url));
            context.showSnackBar(l10n.success);
          },
        ),
        Btn.ok(),
      ],
    );
  }

  Future<void> _leave() async {
    final ok = await context.showSheet<bool>(
      title: l10n.lkcTeamLeave,
      child: Text(l10n.lkcTeamLeaveConfirm(_team.name)),
      actions: Btnx.cancelRedOk,
    );
    if (ok != true || !mounted) return;
    await _after(() => _keys.leave(team: _team.id));
  }
}

List<Widget> _memberChips(LkcMember m) => [
  _Chip(null, _roleText(m.role), _Tone.role),
  if (!m.approved)
    _Chip(Icons.hourglass_top, l10n.lkcTeamWaitingApproval, _Tone.warn)
  else if (m.changed)
    _Chip(Icons.change_circle, l10n.lkcTeamKeyChanged, _Tone.err)
  else if (m.keyed)
    _Chip(Icons.key, l10n.lkcTeamHoldsKey, _Tone.ok)
  else
    _Chip(Icons.hourglass_top, l10n.lkcTeamAwaitingKey, _Tone.warn),
  if (m.compared) _Chip(Icons.verified_user, l10n.lkcTeamCompared, _Tone.ok) else _Chip(Icons.shield_outlined, l10n.lkcTeamNotCompared, _Tone.idle),
];

final class _MemberRow extends StatelessWidget {
  final LkcMember member;
  final bool me;
  final VoidCallback onTap;

  const _MemberRow({required this.member, required this.me, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = member;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        child: Row(
          spacing: 9,
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: me ? scheme.primaryContainer : scheme.surfaceContainerHighest,
              child: Text(
                m.name.characters.take(2).toString(),
                style: TextStyle(fontSize: 13, color: me ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 3,
                children: [
                  Text(me ? '${m.name} (${l10n.lkcTeamMe})' : m.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Wrap(spacing: 5, runSpacing: 5, children: _memberChips(m)),
                ],
              ),
            ),
            const _Chevron(),
          ],
        ),
      ),
    );
  }
}

final class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  const _ActionTile(this.icon, this.text, this.onTap);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: CardX(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 7),
              child: Column(
                spacing: 5,
                children: [
                  Icon(icon, color: scheme.primary),
                  Text(text, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _Banner extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool error;
  final (String, Future<void> Function())? action;

  const _Banner({required this.icon, required this.title, this.error = false, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = error ? scheme.onErrorContainer : scheme.onSurface;
    final action = this.action;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 13,
        children: [
          Icon(icon, color: error ? fg : scheme.onSurfaceVariant),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
                if (action != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: action.$2, child: Text(action.$1, style: TextStyle(color: error ? fg : null))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _GroupLabel extends StatelessWidget {
  final String text;

  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(17, 13, 17, 3),
    child: Text(text.toUpperCase(), style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline, letterSpacing: 0.9)),
  );
}

extension on BuildContext {
  Future<T?> _runTeam<T>(Future<T> Function() fn) async {
    // The sheet closes itself, whether or not this context is still here.
    final (ret, err) = await showLoadingSheet(fn: fn, timeout: null, showErr: false);
    if (err != null) {
      if (mounted) _showTeamErr(err);
      return null;
    }
    return ret;
  }

  void _showTeamErr(Object? e) {
    if (e == null) return;
    showSheet(title: l10n.fail, child: Text(_teamErrText(e)), actions: Btnx.oks);
  }
}

String _teamErrText(Object e) => switch (e) {
  LkcTeamError(kind: LkcTeamErrorKind.wrongPassphrase) => l10n.lkcTeamWrongPassword,
  LkcTeamError(kind: LkcTeamErrorKind.promotionNeeded) => l10n.lkcTeamPromotionNeeded,
  LkcTeamError(kind: LkcTeamErrorKind.accountKeyReplaced) => l10n.lkcTeamKeyReplaced,
  LkcTeamError(kind: LkcTeamErrorKind.untrusted || LkcTeamErrorKind.crypto) => l10n.lkcTeamUntrusted,
  LkcTeamError(kind: LkcTeamErrorKind.unconfirmed, :final users) => l10n.lkcTeamUnconfirmed(users.join(', ')),
  LkcTeamError(kind: LkcTeamErrorKind.noRecipient, :final users) => l10n.lkcTeamNoRecipient(users.join(', ')),
  LkcTeamError(:final detail) => detail,
  final LkcException e => e.text(l10n),
  _ => '$e',
};

/// What a team's own banner shows ([_TeamDetailState._banners]); any other
/// error gets the general one.
const _bannered = {
  LkcTeamErrorKind.untrusted,
  LkcTeamErrorKind.crypto,
  LkcTeamErrorKind.unkeyed,
  LkcTeamErrorKind.signingKeyChanged,
  LkcTeamErrorKind.recoveryEpoch,
};
