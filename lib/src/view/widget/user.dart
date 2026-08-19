import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';

final class UserCard extends StatefulWidget {
  const UserCard({super.key});

  @override
  State<UserCard> createState() => _UserCardState();
}

final class _UserCardState extends State<UserCard> {
  final showTokenPaste = false.vn;

  @override
  Widget build(BuildContext context) {
    return UserApi.user.listenVal(_buildInner).cardx;
  }

  Widget _buildInner(User? user) {
    final child = user == null ? _buildLogin() : _buildUserInfo(user);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.fastEaseInToSlowEaseOut,
      switchOutCurve: Curves.fastEaseInToSlowEaseOut,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: InkWell(
        key: ValueKey(user == null ? 'user-card-login' : 'user-card-profile'),
        onTap: () {
          if (user != null) {
            UserPage.route.go(context);
          }
        },
        child: child,
      ),
    );
  }

  static const _github = Icon(MingCute.github_line);

  Widget _buildLogin() {
    return showTokenPaste.listenVal((loading) {
      return ListTile(
        leading: const Icon(MingCute.user_1_fill),
        title: Text(l10n.login),
        subtitle: Text(l10n.loginTip, style: UIs.textGrey),
        onTap: () async {
          if (loading) return;
          await UserApi.login();
          showTokenPaste.value = true;
          Future.delayed(const Duration(seconds: 30), () {
            if (showTokenPaste.value) {
              showTokenPaste.value = false;
            }
          });
        },
        trailing: loading ? _buildPasteToken() : _github,
      );
    });
  }

  Widget _buildPasteToken() {
    return ElevatedButton(
      onPressed: () async {
        final token = await Pfs.paste();
        if (!mounted || token == null || token.isEmpty) return;
        showTokenPaste.value = false;
        await context.showLoadingDialog(
          fn: () => UserApi.authenticate(token),
          onErr: (_, _) {
            if (mounted) showTokenPaste.value = true;
          },
        );
      },
      child: Text('${l10n.paste} Token'),
    );
  }

  Widget _buildUserInfo(User user) {
    return ListTile(
      leading: const UserAvatar(),
      title: Text(user.name, style: UIs.text15Bold),
      subtitle: Text('${user.oauth?.capitalize}', style: UIs.textGrey),
    );
  }
}

final class UserAvatar extends StatelessWidget {
  final void Function(ImagePageRet ret)? onRet;
  final bool? showLarge;

  const UserAvatar({super.key, this.onRet, this.showLarge = false});

  @override
  Widget build(BuildContext context) {
    final avatar = UserApi.user.value?.avatar;
    final showLarge = this.showLarge ?? avatar != null && onRet != null;
    return ImageCard(
      imageUrl: avatar ?? 'https://cdn.lpkt.cn/img/anon_avatar.jpg',
      showLarge: showLarge,
      heroTag: 'userAvatar',
      onRet: onRet,
      radius: BorderRadius.circular(7),
    );
  }
}
