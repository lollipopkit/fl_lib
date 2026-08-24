library;

// =============================================================================
// Resources
// =============================================================================
// UI constants, themes, syntax highlighting, and other resource definitions

export 'src/res/highlights.dart';
export 'src/res/misc.dart';
export 'src/res/ui.dart';

// =============================================================================
// Core Framework
// =============================================================================
// Foundation functionality including initialization, extensions, utilities,
// backend services, storage, synchronization, and platform abstractions

// --- Initialization & App Setup ---
// Library initialization, app updates, build info, and routing
export 'src/core/build.dart';
export 'src/core/init.dart';
export 'src/core/route/route.dart';
export 'src/core/update.dart';

// --- Extensions ---
// Dart/Flutter type extensions for enhanced APIs and convenience methods
export 'src/core/ext/color.dart';
export 'src/core/ext/ctx/color.dart';
export 'src/core/ext/ctx/common.dart';
export 'src/core/ext/ctx/dialog.dart';
export 'src/core/ext/ctx/l10n.dart';
export 'src/core/ext/ctx/snackbar.dart';
export 'src/core/ext/datetime.dart';
export 'src/core/ext/duration.dart';
export 'src/core/ext/enum.dart';
export 'src/core/ext/file.dart';
export 'src/core/ext/image.dart';
export 'src/core/ext/iter.dart';
export 'src/core/ext/locale.dart';
export 'src/core/ext/num.dart';
export 'src/core/ext/obj.dart';
export 'src/core/ext/order.dart';
export 'src/core/ext/string.dart';
export 'src/core/ext/theme_data.dart';
export 'src/core/ext/uint8list.dart';
export 'src/core/ext/secondary_tap.dart';
export 'src/core/ext/widget.dart';

// --- Mixins ---
// Reusable mixins for common patterns like after-layout callbacks
export 'src/core/mixin/after_layout.dart';
export 'src/core/mixin/global_ref.dart';

// --- Utilities ---
// Platform abstractions, UI helpers, crypto, localization, and common functions
export 'src/core/utils/crypto.dart';
export 'src/core/utils/font.dart';
export 'src/core/utils/func.dart';
export 'src/core/utils/id.dart';
export 'src/core/utils/keyboard.dart';
export 'src/core/utils/locale.dart';
export 'src/core/utils/markdown.dart';
export 'src/core/utils/platform/arch.dart';
export 'src/core/utils/platform/auth.dart';
export 'src/core/utils/platform/base.dart';
export 'src/core/utils/platform/path.dart';
export 'src/core/utils/responsive.dart';
export 'src/core/utils/ui.dart';
export 'src/core/utils/window_state.dart';

// --- Backend & HTTP ---
// HTTP client, API abstractions, and file caching
export 'src/core/backend/api.dart';
export 'src/core/backend/file/cached.dart';

// --- Storage ---
// Data persistence with secure storage, preferences, and database interfaces
export 'src/core/store/iface.dart';
export 'src/core/store/secure.dart';

// --- Synchronization ---
// Cloud sync base classes and implementations (iCloud, WebDAV)
export 'src/core/sync/base.dart';

// --- Other Core ---
// Logging, app links, HTTP overrides, and other core functionality
export 'src/core/app_link.dart';
export 'src/core/dio.dart';
export 'src/core/http_override.dart';
export 'src/core/logger.dart';

// =============================================================================
// Providers
// =============================================================================
// Riverpod providers for state management and dependency injection

export 'src/provider/app.dart';
export 'src/provider/debug.dart';

// =============================================================================
// Models
// =============================================================================
// Data models, business logic, error handling, and serialization

export 'src/model/async_queue.dart';
export 'src/model/backend/user.dart';
export 'src/model/brightness_related.dart';
export 'src/model/err.dart';
export 'src/model/json.dart';
export 'src/model/notify.dart';
export 'src/model/provider.dart';
export 'src/model/result.dart';
export 'src/model/rnode.dart';
export 'src/model/update.dart';

// =============================================================================
// Views
// =============================================================================
// UI components including complete pages and reusable widgets

// --- Pages ---
// Complete page implementations for common use cases
export 'src/view/page/debug.dart';
export 'src/view/page/editor/code.dart';
export 'src/view/page/editor/json_list.dart';
export 'src/view/page/editor/kv.dart';
export 'src/view/page/editor/plain.dart';
export 'src/view/page/file.dart';
export 'src/view/page/image.dart';
export 'src/view/page/intro.dart';
export 'src/view/page/local_auth.dart';
export 'src/view/page/scan.dart';
export 'src/view/page/search.dart';
export 'src/view/page/user.dart';

// --- Widgets ---
// Reusable UI components and specialized widgets
export 'src/view/widget/adaptive_list.dart';
export 'src/view/widget/context_menu.dart';
export 'src/view/widget/appbar.dart';
export 'src/view/widget/auto_hide.dart';
export 'src/view/widget/avg.dart';
export 'src/view/widget/btn/btn.dart';
export 'src/view/widget/btn/count_down_btn.dart';
export 'src/view/widget/card.dart';
export 'src/view/widget/choice.dart';
export 'src/view/widget/code/ctx_menu.dart';
export 'src/view/widget/code/find_panel.dart';
export 'src/view/widget/color_picker.dart';
export 'src/view/widget/dispose_with.dart';
export 'src/view/widget/error.dart';
export 'src/view/widget/empty_pane.dart';
export 'src/view/widget/page_columns.dart';
export 'src/view/widget/page_issue.dart';
export 'src/view/widget/exit_confirm.dart';
export 'src/view/widget/fade_in.dart';
export 'src/view/widget/future_widget.dart';
export 'src/view/widget/hide_on_scroll.dart';
export 'src/view/widget/hover.dart';
export 'src/view/widget/img/compare.dart';
export 'src/view/widget/img/image.dart';
export 'src/view/widget/input.dart';
export 'src/view/widget/list.dart';
export 'src/view/widget/loading.dart';
export 'src/view/widget/markdown.dart';
export 'src/view/widget/adaptive_panes.dart';
export 'src/view/widget/adaptive_side_list.dart';
export 'src/view/widget/hairline.dart';
export 'src/view/widget/pane.dart';
export 'src/view/widget/nested_navigator.dart';
export 'src/view/widget/overlay.dart';
export 'src/view/widget/overlay_flight.dart';
export 'src/view/widget/popup_menu.dart';
export 'src/view/widget/qr/qr.dart';
export 'src/view/widget/qr/share_btn.dart';
export 'src/view/widget/row.dart';
export 'src/view/widget/side_bar.dart';
export 'src/view/widget/session_tab_bar.dart';
export 'src/view/widget/session_tabs.dart';
export 'src/view/widget/slide_trans.dart';
export 'src/view/widget/spotlight.dart';
export 'src/view/widget/split.dart';
export 'src/view/widget/store/store_field.dart';
export 'src/view/widget/store/store_switch.dart';
export 'src/view/widget/switch_indicator.dart';
export 'src/view/widget/tag.dart';
export 'src/view/widget/text.dart';
export 'src/view/widget/tile/card_tile.dart';
export 'src/view/widget/tile/expand_tile.dart';
export 'src/view/widget/tile/tiles.dart';
export 'src/view/widget/toast/toast.dart';
export 'src/view/widget/turnstile.dart';
export 'src/view/widget/user.dart';
export 'src/view/widget/val_builder.dart';
export 'src/view/widget/virtual_window_frame.dart';

