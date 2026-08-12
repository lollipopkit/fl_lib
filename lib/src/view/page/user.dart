import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

final class UserPage extends StatefulWidget {
  const UserPage({super.key});

  static const route = AppRouteNoArg(page: UserPage.new, path: '/user');

  @override
  State<UserPage> createState() => _UserPageState();
}

final class _UserPageState extends State<UserPage> {
  @override
  Widget build(BuildContext context) {
    return UserApi.user.listenVal(
      (user) {
        if (user == null) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.user)),
            body: const UserCard(),
          );
        }
        return _buildUserInfo(user);
      },
    );
  }

  // Widget _buildUserInfo(User user) {
  //   return CustomScrollView(
  //     slivers: [
  //       SliverAppBar(
  //         title: Text(user.name),
  //         pinned: true,
  //       ),
  //       SliverPadding(
  //         padding: const EdgeInsets.all(17),
  //         sliver: SliverList(
  //           delegate: SliverChildListDelegate.fixed(<Widget>[
  //             const UserAvatar(),
  //             Btn.elevated(
  //               onTap: _onLogout,
  //               icon: const Icon(Icons.logout),
  //               text: l10n.logout,
  //             ),
  //             Btn.elevated(
  //               onTap: _onRename,
  //               icon: const Icon(BoxIcons.bx_rename),
  //               text: l10n.rename,
  //             ),
  //             Btn.elevated(
  //               onTap: _onDelete,
  //               icon: const Icon(Icons.delete),
  //               text: l10n.delete,
  //             ),
  //           ].joinWith(UIs.height13)),
  //         ),
  //       ),
  //     ],
  //   );
  // }

  Widget _buildUserInfo(User user) {
    return Scaffold(
      appBar: AppBar(title: Text(user.name)),
      body: Padding(
        padding: const EdgeInsets.all(17),
        child: ListView(
          children: <Widget>[
            const UserAvatar(),
            UIs.height13,
            Btn.elevated(
              onTap: _onLogout,
              icon: const Icon(Icons.logout),
              text: l10n.logout,
            ),
            Btn.elevated(
              onTap: _onRename,
              icon: const Icon(BoxIcons.bx_rename),
              text: l10n.rename,
            ),
            Btn.elevated(
              onTap: _onDelete,
              icon: const Icon(Icons.delete),
              text: l10n.delete,
            ),
          ].joinWith(UIs.height13),
        ),
      ),
    );
  }

  Future<void> _onLogout() async {
    final sure = await context.showRoundDialog(
      title: l10n.logout,
      actions: Btnx.oks,
    );
    if (sure != true) return;
    UserApi.logout(_onAnonyUserLogout);
    contextSafe?.pop();
  }

  Future<bool> _onAnonyUserLogout() async {
    final sure = await context.showRoundDialog(
      title: l10n.attention,
      child: Text(l10n.anonLoseDataTip),
      actions: Btnx.oks,
    );
    return sure == true;
  }

  void _onRename() async {
    final ctrl = TextEditingController(text: UserApi.user.value?.name);
    void onOk() async {
      context.popDialog();
      final name = ctrl.text;
      if (name.isEmpty) return;
      await context.showLoadingDialog(fn: () => UserApi.edit(name: name));
    }

    await context.showRoundDialog(
      title: l10n.rename,
      child: Input(
        controller: ctrl,
        label: l10n.name,
        icon: BoxIcons.bx_rename,
        onSubmitted: (p0) => onOk(),
      ),
      actions: Btn.ok(onTap: onOk).toList,
    );
  }

  void _onDelete() async {
    final sure = await context.showRoundDialog(
      title: l10n.delete,
      child: Text(l10n.delFmt(l10n.user, UserApi.user.value?.name ?? '???')),
      actions: [
        CountDownBtn(
          onTap: () => context.popDialog(true),
          text: l10n.ok,
          afterColor: Colors.red,
        ),
      ],
    );
    if (sure != true) return;

    UserApi.logout(_onAnonyUserLogout);
  }

  // void _onImageRet(ImagePageRet ret) async {
  //   if (ret.isDeleted) {
  //     await context.showLoadingDialog(fn: () async {
  //       await Apis.userEdit(avatar: '');
  //     });
  //   }
  // }
}
