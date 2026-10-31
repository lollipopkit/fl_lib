// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class LibLocalizationsZh extends LibLocalizations {
  LibLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get about => '关于';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1 然后 $action2？';
  }

  @override
  String get active => '活动';

  @override
  String get add => '添加';

  @override
  String get addr => '地址';

  @override
  String agoFmt(String time) {
    return '$time前';
  }

  @override
  String get ai => 'AI';

  @override
  String get all => '所有';

  @override
  String get anonLoseDataTip => '当前以匿名登录，继续操作会导致数据丢失';

  @override
  String get apiEndpoint => 'API 接口地址';

  @override
  String get apiKey => 'API 密钥';

  @override
  String get apiProtocol => 'API 协议';

  @override
  String get app => '应用';

  @override
  String get ascending => '升序';

  @override
  String get askAiModel => '模型';

  @override
  String askContinue(Object msg) {
    return '$msg，继续吗？';
  }

  @override
  String get attention => '注意';

  @override
  String get authRequired => '需要认证';

  @override
  String get auto => '自动';

  @override
  String get available => '可用';

  @override
  String get background => '背景';

  @override
  String get backup => '备份';

  @override
  String get battery => '电池';

  @override
  String get bioAuth => '生物认证';

  @override
  String get blurRadius => '模糊半径';

  @override
  String get bright => '亮';

  @override
  String get browsing => '浏览中';

  @override
  String get cancel => '取消';

  @override
  String get cancelled => '已取消';

  @override
  String get capacity => '容量';

  @override
  String get checkUpdate => '检查更新';

  @override
  String get clear => '清除';

  @override
  String get clearHistory => '清空历史';

  @override
  String get click => '点击';

  @override
  String get clipboard => '剪切板';

  @override
  String get clone => '克隆';

  @override
  String get close => '关闭';

  @override
  String get cmd => '命令';

  @override
  String get configured => '已配置';

  @override
  String get confirm => '确认';

  @override
  String get conn => '连接';

  @override
  String get container => '容器';

  @override
  String get content => '内容';

  @override
  String get convert => '转换';

  @override
  String get copy => '复制';

  @override
  String get create => '创建';

  @override
  String get current => '当前';

  @override
  String get custom => '自定义';

  @override
  String get defaultLabel => '默认';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki/主页#自定义命令';

  @override
  String get cut => '剪切';

  @override
  String get dark => '暗';

  @override
  String get day => '天';

  @override
  String get decode => '解码';

  @override
  String get decompress => '解压缩';

  @override
  String delFmt(Object id, Object type) {
    return '删除 $type（$id）？';
  }

  @override
  String get delay => '延迟';

  @override
  String get delete => '删除';

  @override
  String get descending => '降序';

  @override
  String get description => '描述';

  @override
  String get device => '设备';

  @override
  String get disabled => '已禁用';

  @override
  String get enabled => '已启用';

  @override
  String get disconnected => '已断开连接';

  @override
  String get disk => '磁盘';

  @override
  String get doc => '文档';

  @override
  String get done => '完成';

  @override
  String get dontShowAgain => '不再提示';

  @override
  String get download => '下载';

  @override
  String get duration => '持续时间';

  @override
  String get edit => '编辑';

  @override
  String get editor => '编辑器';

  @override
  String get empty => '空';

  @override
  String get emulator => '模拟器';

  @override
  String get encode => '编码';

  @override
  String get error => '错误';

  @override
  String get example => '示例';

  @override
  String get execute => '执行';

  @override
  String get exit => '退出';

  @override
  String get exitConfirmTip => '再次返回以退出';

  @override
  String get exitDirectly => '直接退出';

  @override
  String get experimentalFeature => '实验功能';

  @override
  String get export => '导出';

  @override
  String get fail => '失败';

  @override
  String get feedback => '反馈';

  @override
  String get file => '文件';

  @override
  String get fold => '折叠';

  @override
  String get folder => '文件夹';

  @override
  String get followSystem => '跟随系统';

  @override
  String get font => '字体';

  @override
  String get fontSize => '字体大小';

  @override
  String get force => '强制';

  @override
  String get foregroundService => '前台服务';

  @override
  String get format => '格式';

  @override
  String get found => '已找到';

  @override
  String get gateway => '网关';

  @override
  String get general => '通用';

  @override
  String get goBackQ => '返回？';

  @override
  String get goto => '转到';

  @override
  String get hideTitleBar => '隐藏标题栏';

  @override
  String get highlight => '代码高亮';

  @override
  String get host => '主机';

  @override
  String get hour => '时';

  @override
  String get image => '图片';

  @override
  String get import => '导入';

  @override
  String get inactive => '未激活';

  @override
  String get init => '初始化';

  @override
  String get inner => '内置';

  @override
  String get install => '安装';

  @override
  String get invalid => '无效';

  @override
  String get invalidUrl => '无效的 URL';

  @override
  String get justNow => '刚刚';

  @override
  String get key => '键';

  @override
  String get language => '语言';

  @override
  String get license => '许可证';

  @override
  String get lkcAccount => '账号';

  @override
  String get lkcBenefitBackups => '备份';

  @override
  String lkcBenefitBackupsAppBytes(String size) {
    return '每个 app 最大 $size';
  }

  @override
  String lkcBenefitBackupsDetail(String kept, String limit) {
    return '$kept，$limit';
  }

  @override
  String get lkcBenefitBackupsLatest => '每个 app 只保留最新一次';

  @override
  String get lkcBenefitBackupsNoLimit => '不限容量';

  @override
  String lkcBenefitBackupsRolling(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 份',
    );
    return '每个 app 滚动保留 $_temp0';
  }

  @override
  String get lkcBenefitBackupsRollingUnlimited => '每个 app 不限滚动备份份数';

  @override
  String lkcBenefitBackupsTotalBytes(String size) {
    return '所有 app 共享 $size';
  }

  @override
  String get lkcBenefitRelay => 'Relay、tailnet 和推送';

  @override
  String lkcBenefitRelayDetail(String rate) {
    return '不限流量，中转速率 $rate，不保证可用';
  }

  @override
  String get lkcBenefitRelayUnlimited => '不限流量和速率，不保证可用';

  @override
  String get lkcBenefitShareLinks => '文件分享链接';

  @override
  String get lkcBenefitShareLinksDetail => '带有效期';

  @override
  String lkcBenefitStorageDetail(String file) {
    return '单个文件最大 $file';
  }

  @override
  String get lkcBenefitSync => '多设备同步';

  @override
  String get lkcBenefitSyncDetail => '实时，端到端加密';

  @override
  String get lkcBenefitUptime => '外部宕机检测';

  @override
  String lkcBenefitUptimeDetail(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '每 $minutes 分钟',
      one: '每分钟',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个目标',
    );
    return '$_temp0检测一次，最多 $_temp1';
  }

  @override
  String lkcBenefitUptimeTargets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个目标',
    );
    return '最多 $_temp0';
  }

  @override
  String get lkcBenefitUptimeTargetsUnlimited => '不限目标数';

  @override
  String lkcBenefitUptimeUnlimited(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '每 $minutes 分钟',
      one: '每分钟',
    );
    return '$_temp0检测一次，不限目标数';
  }

  @override
  String lkcCancelsOn(String date) {
    return '将于 $date 取消';
  }

  @override
  String get lkcConduitConcurrency => '并发';

  @override
  String lkcConduitConcurrencyDetail(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个请求',
    );
    return '同时处理 $_temp0';
  }

  @override
  String get lkcConduitCredit => '额度';

  @override
  String lkcConduitCreditMonthly(String credit) {
    return '每月 $credit';
  }

  @override
  String lkcConduitCreditWeekly(String credit) {
    return '每周 $credit';
  }

  @override
  String get lkcDeleteAccount => '删除账号';

  @override
  String lkcDeleteAccountConfirm(String name) {
    return '$name 及其订阅将被删除，且无法撤销。';
  }

  @override
  String lkcEndsOn(String date) {
    return '$date 结束';
  }

  @override
  String lkcFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
    );
    return '$_temp0';
  }

  @override
  String get lkcFiles => '文件';

  @override
  String get lkcFreeTier => '免费';

  @override
  String get lkcManageSubscriptions => '管理订阅';

  @override
  String get lkcNoEndDate => '无结束日期';

  @override
  String get lkcNotSignedIn => '未登录';

  @override
  String get lkcPastDue => '付款逾期';

  @override
  String get lkcPaused => '已暂停';

  @override
  String lkcPerMonth(String price) {
    return '$price / 月';
  }

  @override
  String lkcPerYear(String price) {
    return '$price / 年';
  }

  @override
  String get lkcReasonAlreadySubscribed => '这条产品线已有订阅，请在账单门户中更改。';

  @override
  String get lkcReasonBadPurchaseToken => '购买凭证无效。';

  @override
  String get lkcReasonBadPushToken => '推送令牌无效。';

  @override
  String get lkcReasonBadQuery => '查询参数无效。';

  @override
  String get lkcReasonBadSignature => '签名无效。';

  @override
  String get lkcReasonBadTransaction => '交易无效。';

  @override
  String get lkcReasonBenefitInvalid => '有权益重复，或不属于对应的计划。';

  @override
  String get lkcReasonCodeCheckout => '这种结账方式不能使用兑换码。';

  @override
  String get lkcReasonCodeCurrency => '兑换码的货币与价格不一致。';

  @override
  String get lkcReasonCodeCurrencyNeeded => '固定金额需要填写货币。';

  @override
  String get lkcReasonCodeDiscountPeriods => '折扣不赠送周期。';

  @override
  String get lkcReasonCodeDuration => '请选择折扣适用的付款。';

  @override
  String get lkcReasonCodeExpired => '兑换码已过期。';

  @override
  String get lkcReasonCodeFormat => '兑换码须为 4 到 32 个字母、数字或短横线。';

  @override
  String get lkcReasonCodeGrantOff => '赠送计划不能带折扣。';

  @override
  String get lkcReasonCodeGrantPeriods => '赠送持续 1 到 120 个周期。';

  @override
  String get lkcReasonCodeGrantPlan => '赠送只能是一个计划。';

  @override
  String get lkcReasonCodeInactive => '兑换码已失效。';

  @override
  String get lkcReasonCodeIsDiscount => '这是折扣码，请在订阅时使用。';

  @override
  String get lkcReasonCodeIsGrant => '这个兑换码赠送计划，请直接兑换。';

  @override
  String get lkcReasonCodeKind => '兑换码的类型不能更改。';

  @override
  String get lkcReasonCodeLimit => '兑换次数上限必须是正整数。';

  @override
  String get lkcReasonCodeLineHeld => '这条产品线已有订阅，无法兑换。';

  @override
  String get lkcReasonCodeMonths => '循环折扣持续 1 到 36 个月。';

  @override
  String get lkcReasonCodeNewOnly => '兑换码仅限新订阅用户使用。';

  @override
  String get lkcReasonCodeNotStarted => '兑换码尚未生效。';

  @override
  String get lkcReasonCodeOff => '折扣须为 1 到 100 的百分比，或大于零的固定金额。';

  @override
  String get lkcReasonCodePlan => '兑换码不适用于这个计划。';

  @override
  String get lkcReasonCodePlans => '请选择兑换码适用的计划。';

  @override
  String get lkcReasonCodeRedeemed => '兑换码已被使用，请改为停用。';

  @override
  String get lkcReasonCodeTaken => '兑换码已存在。';

  @override
  String get lkcReasonCodeTries => '尝试次数过多，请稍后再试。';

  @override
  String get lkcReasonCodeUnknown => '兑换码不存在。';

  @override
  String get lkcReasonCodeUsed => '你已经用过这个兑换码。';

  @override
  String get lkcReasonCodeUsedUp => '兑换码已被用完。';

  @override
  String get lkcReasonCodeWindow => '开始时间必须早于过期时间。';

  @override
  String get lkcReasonDeleteAdmin => '删除管理员前，请先在 IdP 移除其管理员角色。';

  @override
  String get lkcReasonDeleteSelf => '请在账号页面删除你自己的账号。';

  @override
  String get lkcReasonFileExists => '已有同名文件。';

  @override
  String get lkcReasonFileName => '文件名或目录名不合法。';

  @override
  String get lkcReasonFileQuota => '上传后会超出存储配额。';

  @override
  String get lkcReasonSyncUnavailable => '当前套餐不含同步。';

  @override
  String get lkcReasonSyncQuota => '同步文件会超出套餐的空间。';

  @override
  String get lkcReasonSyncDailyLimit => '今日同步流量已用完，明天恢复。';

  @override
  String get lkcReasonFileTooLarge => '文件过大。';

  @override
  String get lkcReasonForeignTransaction => '交易属于其他应用或环境。';

  @override
  String get lkcReasonGrantGone => '这项赠送的计划已经结束。';

  @override
  String get lkcReasonGrantHeld => '该用户在这条产品线已有赠送的计划，请更改那一项。';

  @override
  String get lkcReasonGrantInPast => '结束时间必须在未来。';

  @override
  String get lkcReasonManualProvider => '手动不是支付渠道。';

  @override
  String get lkcReasonNoCustomer => '没有可管理的网页订阅。';

  @override
  String get lkcReasonNoSwitch => '这个产品线没有可切换的网页订阅。';

  @override
  String get lkcReasonNoUser => '用户不存在。';

  @override
  String get lkcReasonPriceArchived => '在售价格在其支付渠道中已归档。';

  @override
  String get lkcReasonPriceMissing => '在售价格在其支付渠道中不存在。';

  @override
  String get lkcReasonPriceNotFixed => '在售价格没有固定金额。';

  @override
  String get lkcReasonPricePeriod => '在售价格的计费周期与计划不一致。';

  @override
  String get lkcReasonProductId => '产品 ID 为空或包含首尾空格。';

  @override
  String get lkcReasonProductInUse => '有生效订阅的产品不能更改计划。';

  @override
  String get lkcReasonProductPlans => '一个产品只能对应一个计划。';

  @override
  String get lkcReasonPurchaseAccount => '购买属于其他账号。';

  @override
  String get lkcReasonPushAccount => '推送账号不符。';

  @override
  String get lkcReasonSamePlan => '你已经在使用这个套餐。';

  @override
  String get lkcReasonSoldTwice => '每个计划在每个支付渠道只能有一个在售价格。';

  @override
  String get lkcReasonSwitchSync => '已保存，但 Stripe 的套餐切换设置没有更新成功，请再保存一次。';

  @override
  String get lkcReasonTestPurchase => '不接受测试购买。';

  @override
  String get lkcReasonTransactionAccount => '交易属于其他账号。';

  @override
  String get lkcReasonUnavailable => '暂不可用。';

  @override
  String get lkcReasonUnknownPackage => '未知的应用包。';

  @override
  String get lkcReasonUploadSize => '文件没有完整上传，请重新上传。';

  @override
  String get lkcReasonUploadUnknown => '上传已过期，请重新上传。';

  @override
  String get lkcReasonUserGone => '该用户已不存在。';

  @override
  String lkcRenewsOn(String date) {
    return '$date 续订';
  }

  @override
  String get lkcStoreSubscriptionTip =>
      '你有一项通过 App Store 或 Google Play 计费的订阅。请先在商店中取消：删除账号不会停止该订阅。';

  @override
  String get lkcSubscribe => '订阅';

  @override
  String get lkcUnlimited => '不限';

  @override
  String lkcUsageOf(String used, String quota) {
    return '$used / $quota';
  }

  @override
  String get loadingEllipsis => '...';

  @override
  String get local => '本地';

  @override
  String get location => '位置';

  @override
  String get log => '日志';

  @override
  String get login => '登录';

  @override
  String get loginTip => '无需注册，免费使用';

  @override
  String get logout => '登出';

  @override
  String get logs => '日志';

  @override
  String get loss => '丢包率';

  @override
  String get manual => '手动';

  @override
  String get max => '最大';

  @override
  String get memory => '内存';

  @override
  String get menuHelp => '帮助';

  @override
  String get menuInfo => '信息';

  @override
  String get menuNavigate => '导航';

  @override
  String get menuQuit => '退出';

  @override
  String get menuSettings => '设置';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get migrateCfg => '配置迁移';

  @override
  String get migrateCfgTip => '为了适应所需的新配置';

  @override
  String get milliseconds => '毫秒';

  @override
  String get min => '最小';

  @override
  String get minute => '分';

  @override
  String get mission => '任务';

  @override
  String get mode => '模式';

  @override
  String get more => '更多';

  @override
  String get moveDown => '下移';

  @override
  String get moveUp => '上移';

  @override
  String get ms => '毫秒';

  @override
  String get name => '名称';

  @override
  String get net => '网络';

  @override
  String get network => '网络';

  @override
  String get next => '下一个';

  @override
  String get node => '节点';

  @override
  String get none => '无';

  @override
  String get notAvailable => '不可用';

  @override
  String notExistFmt(Object file) {
    return '$file 不存在';
  }

  @override
  String get note => '备注';

  @override
  String get ok => '好';

  @override
  String get opacity => '透明度';

  @override
  String get open => '打开';

  @override
  String get optional => '可选';

  @override
  String get paste => '粘贴';

  @override
  String get path => '路径';

  @override
  String get permission => '权限';

  @override
  String get permissionDenied => '权限不足。';

  @override
  String get pingAvg => '平均:';

  @override
  String get pkg => '包管理';

  @override
  String get port => '端口';

  @override
  String get portForward => '端口映射';

  @override
  String get preview => '预览';

  @override
  String get previous => '上一个';

  @override
  String get primaryColorSeed => '主题色种子';

  @override
  String get process => '进程';

  @override
  String get prune => '修剪';

  @override
  String get pwd => '密码';

  @override
  String get pwdTip => '长度6-32，可以是英文的字母、数字、标点';

  @override
  String get read => '读取';

  @override
  String get ready => '就绪';

  @override
  String get reboot => '重启';

  @override
  String get reconnecting => '重连中...';

  @override
  String get redo => '重做';

  @override
  String get refresh => '刷新';

  @override
  String get register => '注册';

  @override
  String get remote => '远程';

  @override
  String get rename => '重命名';

  @override
  String get replace => '替换';

  @override
  String get replaceAll => '替换全部';

  @override
  String get reset => '重置';

  @override
  String get restart => '重启';

  @override
  String get restore => '恢复';

  @override
  String get result => '结果';

  @override
  String get retry => '重试';

  @override
  String get route => '路由';

  @override
  String get run => '运行';

  @override
  String get running => '运行中';

  @override
  String get save => '保存';

  @override
  String get saveFailed => '保存失败';

  @override
  String get saved => '已保存';

  @override
  String get search => '搜索';

  @override
  String get second => '秒';

  @override
  String get select => '选择';

  @override
  String get sensors => '传感器';

  @override
  String get sequence => '顺序';

  @override
  String get server => '服务器';

  @override
  String get servers => '服务器';

  @override
  String get setting => '设置';

  @override
  String get share => '分享';

  @override
  String get shutdown => '关机';

  @override
  String get size => '大小';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return '内容过大，仅显示前 $bytes';
  }

  @override
  String get snippet => '代码片段';

  @override
  String get softWrap => '自动换行';

  @override
  String get sort => '排序';

  @override
  String get sortByName => '按名称';

  @override
  String get source => '来源';

  @override
  String get speed => '速度';

  @override
  String get start => '开始';

  @override
  String get stat => '统计';

  @override
  String get stats => '统计';

  @override
  String get stop => '停止';

  @override
  String get stopped => '已停止';

  @override
  String get storage => '存储';

  @override
  String get success => '成功';

  @override
  String get sudoPassword => 'sudo 密码';

  @override
  String sudoPwdTitle(Object pwd) {
    return 'sudo $pwd';
  }

  @override
  String get suspend => '挂起';

  @override
  String get switch_ => '切换';

  @override
  String get switcher => '切换器';

  @override
  String get sync => '同步';

  @override
  String get system => '系统';

  @override
  String get tag => '标签';

  @override
  String get tapToAuth => '点击以认证';

  @override
  String get temperature => '温度';

  @override
  String get terminal => '终端';

  @override
  String get test => '测试';

  @override
  String get textScaler => '字体缩放';

  @override
  String get theme => '主题';

  @override
  String get themeMode => '主题模式';

  @override
  String get thinking => '思考中';

  @override
  String get time => '时间';

  @override
  String get timedOut => '执行超时';

  @override
  String get timeout => '超时';

  @override
  String get times => '次';

  @override
  String get total => '总共';

  @override
  String get totalAttempts => '总次数';

  @override
  String get traffic => '流量';

  @override
  String get ttl => 'TTL';

  @override
  String get type => '类型';

  @override
  String get undo => '撤销';

  @override
  String get unknown => '未知';

  @override
  String get unsupported => '不支持';

  @override
  String get update => '更新';

  @override
  String get upload => '上传';

  @override
  String get uptime => '启动时长';

  @override
  String get used => '已使用';

  @override
  String get user => '用户';

  @override
  String get valid => '有效';

  @override
  String get value => '值';

  @override
  String versionHasUpdate(Object build) {
    return '找到新版本：v1.0.$build, 点击更新';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return '当前：v1.0.$build，点击检查更新';
  }

  @override
  String versionUpdated(Object build) {
    return '当前：v1.0.$build, 已是最新版本';
  }

  @override
  String get view => '查看';

  @override
  String get viewErr => '查看错误';

  @override
  String get write => '写入';

  @override
  String get yesterday => '昨天';

  @override
  String durationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 天',
    );
    return '$_temp0';
  }

  @override
  String durationHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 小时',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 分钟',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 秒',
    );
    return '$_temp0';
  }

  @override
  String get appearanceSettings => '外观';

  @override
  String get appearancePreset => '主题方案';

  @override
  String get appearanceThemeSchemaRange => '支持的主题 schema';

  @override
  String get appearanceThemeInstall => '安装主题';

  @override
  String get appearanceThemeStore => '主题商店';

  @override
  String get appearanceInvalidTheme => '主题包或目录无效';

  @override
  String get themeStoreRefreshFailed => '无法读取主题目录。';

  @override
  String themeStoreDeleteTheme(String name) {
    return '删除“$name”？其文件将从本机移除。如果它正在使用中，应用将返回默认主题。';
  }

  @override
  String themeStoreUpdatedFmt(String ago) {
    return '$ago更新';
  }

  @override
  String get themeStoreUpdatedJustNow => '刚刚更新';

  @override
  String get themeStoreSortInUse => '在用优先';

  @override
  String themeStoreMakeOwnFmt(String doc) {
    return '如果你想制作自己的主题，欢迎查看[主题制作指南]($doc)，感谢你的贡献！';
  }

  @override
  String appearanceThemeNeedsNewerApp(String version) {
    return '需要更新版本的 App：$version';
  }

  @override
  String get appearanceFontFamilies => '界面字体列表';

  @override
  String get appearanceFontFamiliesTip => '每行一个字体名称，按顺序 fallback。';

  @override
  String get appearanceFontImport => '导入界面字体文件';

  @override
  String get appearanceIcons => 'App 内图标';

  @override
  String get appearanceCorners => '圆角';

  @override
  String get appearanceCardCorners => '卡片圆角';

  @override
  String get appearanceTileCorners => 'Tile 圆角';

  @override
  String get appearanceButtonCorners => '按钮圆角';

  @override
  String appearanceThemeModeLocked(String mode) {
    return '此主题仅支持$mode。如需切换模式，请选择其他主题。';
  }

  @override
  String get caseSensitive => '区分大小写';

  @override
  String get flashlight => '手电筒';

  @override
  String get regex => '正则表达式';

  @override
  String get showPwd => '显示密码';

  @override
  String existsFmt(String name) {
    return '$name 已存在';
  }

  @override
  String tooLargeFmt(String size) {
    return '超过 $size';
  }

  @override
  String get appearanceIconPack => '图标包';

  @override
  String get appearanceIconPackTheme => '主题自带图标';

  @override
  String get themeStoreThemes => '主题';

  @override
  String get themeStoreIconPacks => '图标包';

  @override
  String themeStoreDeleteIconPack(String name) {
    return '删除“$name”？其文件将从本机移除。如果它正在使用中，应用将改用主题自带的图标。';
  }
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class LibLocalizationsZhTw extends LibLocalizationsZh {
  LibLocalizationsZhTw() : super('zh_TW');

  @override
  String get about => '關於';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1 然後 $action2？';
  }

  @override
  String get active => '使用中';

  @override
  String get add => '添加';

  @override
  String get addr => '位址';

  @override
  String agoFmt(String time) {
    return '$time前';
  }

  @override
  String get ai => 'AI';

  @override
  String get all => '所有';

  @override
  String get anonLoseDataTip => '目前為匿名登入，繼續操作可能會導致資料遺失。';

  @override
  String get apiEndpoint => 'API 介面位址';

  @override
  String get apiKey => 'API 金鑰';

  @override
  String get apiProtocol => 'API 協議';

  @override
  String get app => '應用';

  @override
  String get ascending => '遞增';

  @override
  String get askAiModel => '模型';

  @override
  String askContinue(Object msg) {
    return '$msg，是否繼續？';
  }

  @override
  String get attention => '注意';

  @override
  String get authRequired => '需要身份驗證';

  @override
  String get auto => '自動';

  @override
  String get available => '可用';

  @override
  String get background => '背景';

  @override
  String get backup => '備份';

  @override
  String get battery => '電池';

  @override
  String get bioAuth => '生物識別驗證';

  @override
  String get blurRadius => '模糊半徑';

  @override
  String get bright => '亮';

  @override
  String get browsing => '瀏覽中';

  @override
  String get cancel => '取消';

  @override
  String get cancelled => '已取消';

  @override
  String get capacity => '容量';

  @override
  String get checkUpdate => '檢查更新';

  @override
  String get clear => '清除';

  @override
  String get clearHistory => '清除紀錄';

  @override
  String get click => '點擊';

  @override
  String get clipboard => '剪貼簿';

  @override
  String get clone => '複製';

  @override
  String get close => '關閉';

  @override
  String get cmd => '指令';

  @override
  String get configured => '已設定';

  @override
  String get confirm => '確認';

  @override
  String get conn => '連線';

  @override
  String get container => '容器';

  @override
  String get content => '內容';

  @override
  String get convert => '轉換';

  @override
  String get copy => '複製';

  @override
  String get create => '建立';

  @override
  String get current => '目前';

  @override
  String get custom => '自訂';

  @override
  String get defaultLabel => '預設';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki/主页#自定义命令';

  @override
  String get cut => '剪下';

  @override
  String get dark => '暗';

  @override
  String get day => '天';

  @override
  String get decode => '解碼';

  @override
  String get decompress => '解壓縮';

  @override
  String delFmt(Object id, Object type) {
    return '確定要刪除 $type（$id）嗎？';
  }

  @override
  String get delay => '延遲';

  @override
  String get delete => '刪除';

  @override
  String get descending => '遞減';

  @override
  String get description => '描述';

  @override
  String get device => '裝置';

  @override
  String get disabled => '已停用';

  @override
  String get enabled => '已啟用';

  @override
  String get disconnected => '已中斷連線';

  @override
  String get disk => '磁碟';

  @override
  String get doc => '說明文件';

  @override
  String get done => '完成';

  @override
  String get dontShowAgain => '不再顯示';

  @override
  String get download => '下載';

  @override
  String get duration => '持續時間';

  @override
  String get edit => '編輯';

  @override
  String get editor => '編輯器';

  @override
  String get empty => '空';

  @override
  String get emulator => '模擬器';

  @override
  String get encode => '編碼';

  @override
  String get error => '錯誤';

  @override
  String get example => '範例';

  @override
  String get execute => '執行';

  @override
  String get exit => '退出';

  @override
  String get exitConfirmTip => '再按一次返回鍵以退出應用程式';

  @override
  String get exitDirectly => '直接退出';

  @override
  String get experimentalFeature => '實驗功能';

  @override
  String get export => '匯出';

  @override
  String get fail => '失敗';

  @override
  String get feedback => '反饋';

  @override
  String get file => '檔案';

  @override
  String get fold => '摺疊';

  @override
  String get folder => '資料夾';

  @override
  String get followSystem => '跟隨系統';

  @override
  String get font => '字體';

  @override
  String get fontSize => '字型大小';

  @override
  String get force => '強制';

  @override
  String get foregroundService => '前景服務';

  @override
  String get format => '格式';

  @override
  String get found => '找到';

  @override
  String get gateway => '閘道';

  @override
  String get general => '通用';

  @override
  String get goBackQ => '返回？';

  @override
  String get goto => '前往';

  @override
  String get hideTitleBar => '隱藏標題欄';

  @override
  String get highlight => '程式碼標記';

  @override
  String get host => '主機';

  @override
  String get hour => '時';

  @override
  String get image => '圖片';

  @override
  String get import => '匯入';

  @override
  String get inactive => '未啟用';

  @override
  String get init => '初始化';

  @override
  String get inner => '內建';

  @override
  String get install => '安裝';

  @override
  String get invalid => '無效';

  @override
  String get invalidUrl => '無效的網址';

  @override
  String get justNow => '剛剛';

  @override
  String get key => '鍵';

  @override
  String get language => '語言';

  @override
  String get license => '授權';

  @override
  String get lkcAccount => '帳號';

  @override
  String get lkcBenefitBackups => '備份';

  @override
  String lkcBenefitBackupsAppBytes(String size) {
    return '每個 app 最大 $size';
  }

  @override
  String lkcBenefitBackupsDetail(String kept, String limit) {
    return '$kept，$limit';
  }

  @override
  String get lkcBenefitBackupsLatest => '每個 app 只保留最新一次';

  @override
  String get lkcBenefitBackupsNoLimit => '不限容量';

  @override
  String lkcBenefitBackupsRolling(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 份',
    );
    return '每個 app 滾動保留 $_temp0';
  }

  @override
  String get lkcBenefitBackupsRollingUnlimited => '每個 app 不限滾動備份份數';

  @override
  String lkcBenefitBackupsTotalBytes(String size) {
    return '所有 app 共用 $size';
  }

  @override
  String get lkcBenefitRelay => 'Relay、tailnet 和推播';

  @override
  String lkcBenefitRelayDetail(String rate) {
    return '不限流量，中繼速率 $rate，不保證可用';
  }

  @override
  String get lkcBenefitRelayUnlimited => '不限流量與速率，不保證可用';

  @override
  String get lkcBenefitShareLinks => '檔案分享連結';

  @override
  String get lkcBenefitShareLinksDetail => '附有效期限';

  @override
  String lkcBenefitStorageDetail(String file) {
    return '單一檔案最大 $file';
  }

  @override
  String get lkcBenefitSync => '多裝置同步';

  @override
  String get lkcBenefitSyncDetail => '即時，端對端加密';

  @override
  String get lkcBenefitUptime => '外部停機偵測';

  @override
  String lkcBenefitUptimeDetail(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '每 $minutes 分鐘',
      one: '每分鐘',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 個目標',
    );
    return '$_temp0偵測一次，最多 $_temp1';
  }

  @override
  String lkcBenefitUptimeTargets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 個目標',
    );
    return '最多 $_temp0';
  }

  @override
  String get lkcBenefitUptimeTargetsUnlimited => '不限目標數';

  @override
  String lkcBenefitUptimeUnlimited(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '每 $minutes 分鐘',
      one: '每分鐘',
    );
    return '$_temp0偵測一次，不限目標數';
  }

  @override
  String lkcCancelsOn(String date) {
    return '將於 $date 取消';
  }

  @override
  String get lkcConduitConcurrency => '並行數';

  @override
  String lkcConduitConcurrencyDetail(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 個請求',
    );
    return '同時處理 $_temp0';
  }

  @override
  String get lkcConduitCredit => '額度';

  @override
  String lkcConduitCreditMonthly(String credit) {
    return '每月 $credit';
  }

  @override
  String lkcConduitCreditWeekly(String credit) {
    return '每週 $credit';
  }

  @override
  String get lkcDeleteAccount => '刪除帳號';

  @override
  String lkcDeleteAccountConfirm(String name) {
    return '$name 及其訂閱將被刪除，且無法復原。';
  }

  @override
  String lkcEndsOn(String date) {
    return '$date 結束';
  }

  @override
  String lkcFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 個檔案',
    );
    return '$_temp0';
  }

  @override
  String get lkcFiles => '檔案';

  @override
  String get lkcFreeTier => '免費';

  @override
  String get lkcManageSubscriptions => '管理訂閱';

  @override
  String get lkcNoEndDate => '無結束日期';

  @override
  String get lkcNotSignedIn => '未登入';

  @override
  String get lkcPastDue => '付款逾期';

  @override
  String get lkcPaused => '已暫停';

  @override
  String lkcPerMonth(String price) {
    return '$price / 月';
  }

  @override
  String lkcPerYear(String price) {
    return '$price / 年';
  }

  @override
  String get lkcReasonAlreadySubscribed => '這條產品線已有訂閱，請在帳單入口網站中變更。';

  @override
  String get lkcReasonBadPurchaseToken => '購買憑證無效。';

  @override
  String get lkcReasonBadPushToken => '推播權杖無效。';

  @override
  String get lkcReasonBadQuery => '查詢參數無效。';

  @override
  String get lkcReasonBadSignature => '簽章無效。';

  @override
  String get lkcReasonBadTransaction => '交易無效。';

  @override
  String get lkcReasonBenefitInvalid => '有權益重複，或不屬於對應的方案。';

  @override
  String get lkcReasonCodeCheckout => '這種結帳方式不能使用兌換碼。';

  @override
  String get lkcReasonCodeCurrency => '兌換碼的幣別與價格不一致。';

  @override
  String get lkcReasonCodeCurrencyNeeded => '固定金額需要填寫幣別。';

  @override
  String get lkcReasonCodeDiscountPeriods => '折扣不贈送週期。';

  @override
  String get lkcReasonCodeDuration => '請選擇折扣適用的付款。';

  @override
  String get lkcReasonCodeExpired => '兌換碼已過期。';

  @override
  String get lkcReasonCodeFormat => '兌換碼須為 4 到 32 個字母、數字或連字號。';

  @override
  String get lkcReasonCodeGrantOff => '贈送方案不能附帶折扣。';

  @override
  String get lkcReasonCodeGrantPeriods => '贈送持續 1 到 120 個週期。';

  @override
  String get lkcReasonCodeGrantPlan => '贈送只能是一個方案。';

  @override
  String get lkcReasonCodeInactive => '兌換碼已失效。';

  @override
  String get lkcReasonCodeIsDiscount => '這是折扣碼，請在訂閱時使用。';

  @override
  String get lkcReasonCodeIsGrant => '這個兌換碼贈送方案，請直接兌換。';

  @override
  String get lkcReasonCodeKind => '兌換碼的類型不能變更。';

  @override
  String get lkcReasonCodeLimit => '兌換次數上限必須是正整數。';

  @override
  String get lkcReasonCodeLineHeld => '這條產品線已有訂閱，無法兌換。';

  @override
  String get lkcReasonCodeMonths => '循環折扣持續 1 到 36 個月。';

  @override
  String get lkcReasonCodeNewOnly => '兌換碼僅限新訂閱者使用。';

  @override
  String get lkcReasonCodeNotStarted => '兌換碼尚未生效。';

  @override
  String get lkcReasonCodeOff => '折扣須為 1 到 100 的百分比，或大於零的固定金額。';

  @override
  String get lkcReasonCodePlan => '兌換碼不適用於這個方案。';

  @override
  String get lkcReasonCodePlans => '請選擇兌換碼適用的方案。';

  @override
  String get lkcReasonCodeRedeemed => '兌換碼已被使用，請改為停用。';

  @override
  String get lkcReasonCodeTaken => '兌換碼已存在。';

  @override
  String get lkcReasonCodeTries => '嘗試次數過多，請稍後再試。';

  @override
  String get lkcReasonCodeUnknown => '兌換碼不存在。';

  @override
  String get lkcReasonCodeUsed => '你已經用過這個兌換碼。';

  @override
  String get lkcReasonCodeUsedUp => '兌換碼已被用完。';

  @override
  String get lkcReasonCodeWindow => '開始時間必須早於到期時間。';

  @override
  String get lkcReasonDeleteAdmin => '刪除管理員前，請先在 IdP 移除其管理員角色。';

  @override
  String get lkcReasonDeleteSelf => '請在帳號頁面刪除你自己的帳號。';

  @override
  String get lkcReasonFileExists => '已有同名檔案。';

  @override
  String get lkcReasonFileName => '檔案名稱或目錄名稱不合法。';

  @override
  String get lkcReasonFileQuota => '上傳後會超出儲存空間配額。';

  @override
  String get lkcReasonSyncUnavailable => '目前方案不含同步。';

  @override
  String get lkcReasonSyncQuota => '同步檔案會超出方案的空間。';

  @override
  String get lkcReasonSyncDailyLimit => '今日同步流量已用完，明天恢復。';

  @override
  String get lkcReasonFileTooLarge => '檔案過大。';

  @override
  String get lkcReasonForeignTransaction => '交易屬於其他應用程式或環境。';

  @override
  String get lkcReasonGrantGone => '這項贈送的方案已經結束。';

  @override
  String get lkcReasonGrantHeld => '該使用者在這條產品線已有贈送的方案，請變更那一項。';

  @override
  String get lkcReasonGrantInPast => '結束時間必須在未來。';

  @override
  String get lkcReasonManualProvider => '手動不是付款管道。';

  @override
  String get lkcReasonNoCustomer => '沒有可管理的網頁訂閱。';

  @override
  String get lkcReasonNoSwitch => '這條產品線沒有可切換的網頁訂閱。';

  @override
  String get lkcReasonNoUser => '使用者不存在。';

  @override
  String get lkcReasonPriceArchived => '販售中的價格在其付款管道中已封存。';

  @override
  String get lkcReasonPriceMissing => '販售中的價格在其付款管道中不存在。';

  @override
  String get lkcReasonPriceNotFixed => '販售中的價格沒有固定金額。';

  @override
  String get lkcReasonPricePeriod => '販售中的價格計費週期與方案不一致。';

  @override
  String get lkcReasonProductId => '產品 ID 為空或包含前後空白。';

  @override
  String get lkcReasonProductInUse => '有生效訂閱的產品不能變更方案。';

  @override
  String get lkcReasonProductPlans => '一個產品只能對應一個方案。';

  @override
  String get lkcReasonPurchaseAccount => '購買屬於其他帳號。';

  @override
  String get lkcReasonPushAccount => '推播帳號不符。';

  @override
  String get lkcReasonSamePlan => '你已經在使用這個方案。';

  @override
  String get lkcReasonSoldTwice => '每個方案在每個付款管道只能有一個販售中的價格。';

  @override
  String get lkcReasonSwitchSync => '已儲存，但 Stripe 的方案切換設定未能更新，請再儲存一次。';

  @override
  String get lkcReasonTestPurchase => '不接受測試購買。';

  @override
  String get lkcReasonTransactionAccount => '交易屬於其他帳號。';

  @override
  String get lkcReasonUnavailable => '暫時無法使用。';

  @override
  String get lkcReasonUnknownPackage => '未知的應用程式套件。';

  @override
  String get lkcReasonUploadSize => '檔案未完整上傳，請重新上傳。';

  @override
  String get lkcReasonUploadUnknown => '上傳已過期，請重新上傳。';

  @override
  String get lkcReasonUserGone => '該使用者已不存在。';

  @override
  String lkcRenewsOn(String date) {
    return '$date 續訂';
  }

  @override
  String get lkcStoreSubscriptionTip =>
      '你有一項透過 App Store 或 Google Play 計費的訂閱。請先在商店中取消：刪除帳號不會停止該訂閱。';

  @override
  String get lkcSubscribe => '訂閱';

  @override
  String get lkcUnlimited => '不限';

  @override
  String lkcUsageOf(String used, String quota) {
    return '$used / $quota';
  }

  @override
  String get loadingEllipsis => '...';

  @override
  String get local => '本機';

  @override
  String get location => '位置';

  @override
  String get log => '日誌';

  @override
  String get login => '登入';

  @override
  String get loginTip => '無需註冊，免費使用。';

  @override
  String get logout => '登出';

  @override
  String get logs => '日誌';

  @override
  String get loss => '丟包率';

  @override
  String get manual => '手動';

  @override
  String get max => '最大';

  @override
  String get memory => '記憶體';

  @override
  String get menuHelp => '說明';

  @override
  String get menuInfo => '資訊';

  @override
  String get menuNavigate => '導覽';

  @override
  String get menuQuit => '結束';

  @override
  String get menuSettings => '設定';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get migrateCfg => '配置遷移';

  @override
  String get migrateCfgTip => '為了適應所需的新設定';

  @override
  String get milliseconds => '毫秒';

  @override
  String get min => '最小';

  @override
  String get minute => '分';

  @override
  String get mission => '任務';

  @override
  String get mode => '模式';

  @override
  String get more => '更多';

  @override
  String get moveDown => '下移';

  @override
  String get moveUp => '上移';

  @override
  String get ms => '毫秒';

  @override
  String get name => '名稱';

  @override
  String get net => '網路';

  @override
  String get network => '網路';

  @override
  String get next => '下一項';

  @override
  String get node => '節點';

  @override
  String get none => '無';

  @override
  String get notAvailable => '不可用';

  @override
  String notExistFmt(Object file) {
    return '$file 不存在';
  }

  @override
  String get note => '備註';

  @override
  String get ok => '好';

  @override
  String get opacity => '透明度';

  @override
  String get open => '開啟';

  @override
  String get optional => '選填';

  @override
  String get paste => '貼上';

  @override
  String get path => '路徑';

  @override
  String get permission => '權限';

  @override
  String get permissionDenied => '權限不足。';

  @override
  String get pingAvg => '平均:';

  @override
  String get pkg => '套件管理';

  @override
  String get port => '埠';

  @override
  String get portForward => '連接埠轉發';

  @override
  String get preview => '預覽';

  @override
  String get previous => '上一項';

  @override
  String get primaryColorSeed => '主要色調種子';

  @override
  String get process => '處理程序';

  @override
  String get prune => '修剪';

  @override
  String get pwd => '密碼';

  @override
  String get pwdTip => '密碼長度6-32位，支援英文字母、數字及標點符號';

  @override
  String get read => '讀取';

  @override
  String get ready => '就緒';

  @override
  String get reboot => '重新開機';

  @override
  String get reconnecting => '重連中...';

  @override
  String get redo => '重做';

  @override
  String get refresh => '重新整理';

  @override
  String get register => '註冊';

  @override
  String get remote => '遠端';

  @override
  String get rename => '重命名';

  @override
  String get replace => '替換';

  @override
  String get replaceAll => '全部替換';

  @override
  String get reset => '重設';

  @override
  String get restart => '重新啟動';

  @override
  String get restore => '恢復';

  @override
  String get result => '結果';

  @override
  String get retry => '重試';

  @override
  String get route => '路由';

  @override
  String get run => '執行';

  @override
  String get running => '運作中';

  @override
  String get save => '儲存';

  @override
  String get saveFailed => '儲存失敗';

  @override
  String get saved => '已儲存';

  @override
  String get search => '搜尋';

  @override
  String get second => '秒';

  @override
  String get select => '選擇';

  @override
  String get sensors => '感應器';

  @override
  String get sequence => '順序';

  @override
  String get server => '伺服器';

  @override
  String get servers => '伺服器';

  @override
  String get setting => '設定';

  @override
  String get share => '分享';

  @override
  String get shutdown => '關機';

  @override
  String get size => '大小';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return '內容過大，僅顯示前 $bytes';
  }

  @override
  String get snippet => '程式片段';

  @override
  String get softWrap => '軟換行';

  @override
  String get sort => '排序';

  @override
  String get sortByName => '依名稱';

  @override
  String get source => '來源';

  @override
  String get speed => '速度';

  @override
  String get start => '開始';

  @override
  String get stat => '統計';

  @override
  String get stats => '統計';

  @override
  String get stop => '停止';

  @override
  String get stopped => '已停止';

  @override
  String get storage => '儲存';

  @override
  String get success => '成功';

  @override
  String get sudoPassword => 'sudo 密碼';

  @override
  String sudoPwdTitle(Object pwd) {
    return 'sudo $pwd';
  }

  @override
  String get suspend => '暫停';

  @override
  String get switch_ => '切換';

  @override
  String get switcher => '切換器';

  @override
  String get sync => '同步';

  @override
  String get system => '系統';

  @override
  String get tag => '標籤';

  @override
  String get tapToAuth => '點擊進行身份驗證';

  @override
  String get temperature => '溫度';

  @override
  String get terminal => '終端機';

  @override
  String get test => '測試';

  @override
  String get textScaler => '字型縮放';

  @override
  String get theme => '主題';

  @override
  String get themeMode => '主題模式';

  @override
  String get thinking => '思考中';

  @override
  String get time => '時間';

  @override
  String get timedOut => '執行逾時';

  @override
  String get timeout => '超時';

  @override
  String get times => '次';

  @override
  String get total => '總共';

  @override
  String get totalAttempts => '總次數';

  @override
  String get traffic => '流量';

  @override
  String get ttl => 'TTL';

  @override
  String get type => '類型';

  @override
  String get undo => '復原';

  @override
  String get unknown => '未知';

  @override
  String get unsupported => '不支援';

  @override
  String get update => '更新';

  @override
  String get upload => '上傳';

  @override
  String get uptime => '運作時間';

  @override
  String get used => '已使用';

  @override
  String get user => '使用者';

  @override
  String get valid => '有效';

  @override
  String get value => '值';

  @override
  String versionHasUpdate(Object build) {
    return '發現新版本：v1.0.$build，點擊更新';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return '目前版本：v1.0.$build，點擊檢查更新';
  }

  @override
  String versionUpdated(Object build) {
    return '目前版本：v1.0.$build，已是最新版本';
  }

  @override
  String get view => '檢視';

  @override
  String get viewErr => '查看錯誤';

  @override
  String get write => '寫入';

  @override
  String get yesterday => '昨天';

  @override
  String durationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 天',
    );
    return '$_temp0';
  }

  @override
  String durationHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 小時',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 分鐘',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 秒',
    );
    return '$_temp0';
  }

  @override
  String get appearanceSettings => '外觀';

  @override
  String get appearancePreset => '主題方案';

  @override
  String get appearanceThemeSchemaRange => '支援的主題 schema';

  @override
  String get appearanceThemeInstall => '安裝主題';

  @override
  String get appearanceThemeStore => '主題商店';

  @override
  String get appearanceInvalidTheme => '主題套件或目錄無效';

  @override
  String get themeStoreRefreshFailed => '無法讀取主題目錄。';

  @override
  String themeStoreDeleteTheme(String name) {
    return '刪除「$name」？其檔案將從本機移除。如果它正在使用中，應用程式將回到預設主題。';
  }

  @override
  String themeStoreUpdatedFmt(String ago) {
    return '$ago更新';
  }

  @override
  String get themeStoreUpdatedJustNow => '剛剛更新';

  @override
  String get themeStoreSortInUse => '在用優先';

  @override
  String themeStoreMakeOwnFmt(String doc) {
    return '如果你想製作自己的主題，歡迎查看[主題製作指南]($doc)，感謝你的貢獻！';
  }

  @override
  String appearanceThemeNeedsNewerApp(String version) {
    return '需要較新版本的 App：$version';
  }

  @override
  String get appearanceFontFamilies => '介面字型列表';

  @override
  String get appearanceFontFamiliesTip => '每行一個字型名稱，依序 fallback。';

  @override
  String get appearanceFontImport => '匯入介面字型檔案';

  @override
  String get appearanceIcons => 'App 內圖示';

  @override
  String get appearanceCorners => '圓角';

  @override
  String get appearanceCardCorners => '卡片圓角';

  @override
  String get appearanceTileCorners => 'Tile 圓角';

  @override
  String get appearanceButtonCorners => '按鈕圓角';

  @override
  String appearanceThemeModeLocked(String mode) {
    return '此主題僅支援$mode。如需切換模式，請選擇其他主題。';
  }

  @override
  String get caseSensitive => '區分大小寫';

  @override
  String get flashlight => '手電筒';

  @override
  String get regex => '正規表示式';

  @override
  String get showPwd => '顯示密碼';

  @override
  String existsFmt(String name) {
    return '$name 已存在';
  }

  @override
  String tooLargeFmt(String size) {
    return '超過 $size';
  }

  @override
  String get appearanceIconPack => '圖示包';

  @override
  String get appearanceIconPackTheme => '主題內建圖示';

  @override
  String get themeStoreThemes => '主題';

  @override
  String get themeStoreIconPacks => '圖示包';

  @override
  String themeStoreDeleteIconPack(String name) {
    return '刪除「$name」？其檔案將從本機移除。如果它正在使用中，應用程式將改用主題內建的圖示。';
  }
}
