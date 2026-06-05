// ignore_for_file: constant_identifier_names
import 'package:flutter/widgets.dart';
import 'package:flutter_highlight/theme_map.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/apache.dart';
import 'package:re_highlight/languages/applescript.dart';
import 'package:re_highlight/languages/arduino.dart';
import 'package:re_highlight/languages/awk.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/bnf.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/clojure.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/delphi.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/django.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/dust.dart';
import 'package:re_highlight/languages/ebnf.dart';
import 'package:re_highlight/languages/erlang.dart';
import 'package:re_highlight/languages/excel.dart';
import 'package:re_highlight/languages/fortran.dart';
import 'package:re_highlight/languages/glsl.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/haskell.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/julia.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lisp.dart';
import 'package:re_highlight/languages/llvm.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/matlab.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/nim.dart';
import 'package:re_highlight/languages/nix.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/ocaml.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/pgsql.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/stylus.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/vbscript.dart';
import 'package:re_highlight/languages/verilog.dart';
import 'package:re_highlight/languages/vim.dart';
import 'package:re_highlight/languages/vue.dart';
import 'package:re_highlight/languages/wasm.dart';
import 'package:re_highlight/languages/wren.dart';
import 'package:re_highlight/languages/x86asm.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// The theme of the code editor.
enum HighlightTheme {
  a11y_dark,
  a11y_light,
  agate,
  an_old_hope,
  androidstudio,
  arduino_light,
  arta,
  ascetic,
  atelier_cave_dark,
  atelier_cave_light,
  atelier_dune_dark,
  atelier_dune_light,
  atelier_estuary_dark,
  atelier_estuary_light,
  atelier_forest_dark,
  atelier_forest_light,
  atelier_heath_dark,
  atelier_heath_light,
  atelier_lakeside_dark,
  atelier_lakeside_light,
  atelier_plateau_dark,
  atelier_plateau_light,
  atelier_savanna_dark,
  atelier_savanna_light,
  atelier_seaside_dark,
  atelier_seaside_light,
  atelier_sulphurpool_dark,
  atelier_sulphurpool_light,
  atom_one_dark_reasonable,
  atom_one_dark,
  atom_one_light,
  brown_paper,
  codepen_embed,
  color_brewer,
  darcula,
  dark,
  defaultTheme,
  docco,
  dracula,
  far,
  foundation,
  github_gist,
  github,
  gml,
  googlecode,
  gradient_dark,
  grayscale,
  gruvbox_dark,
  gruvbox_light,
  hopscotch,
  hybrid,
  idea,
  ir_black,
  isbl_editor_dark,
  isbl_editor_light,
  kimbie_dark,
  kimbie_light,
  lightfair,
  magula,
  mono_blue,
  monokai_sublime,
  monokai,
  night_owl,
  nord,
  obsidian,
  ocean,
  paraiso_dark,
  paraiso_light,
  pojoaque,
  purebasic,
  qtcreator_dark,
  qtcreator_light,
  railscasts,
  rainbow,
  routeros,
  school_book,
  shades_of_purple,
  solarized_dark,
  solarized_light,
  sunburst,
  tomorrow_night_blue,
  tomorrow_night_bright,
  tomorrow_night_eighties,
  tomorrow_night,
  tomorrow,
  vs,
  vs2015,
  xcode,
  xt256,
  zenburn,
  ;

  /// Returns the corresponding theme colors map.
  Map<String, TextStyle>? get theme {
    return themeMap[themeMapKey];
  }

  /// Returns the corresponding key in flutter_highlight's theme map.
  String get themeMapKey {
    return switch (this) {
      HighlightTheme.defaultTheme => 'default',
      HighlightTheme.kimbie_dark => 'kimbie.dark',
      HighlightTheme.kimbie_light => 'kimbie.light',
      HighlightTheme.qtcreator_dark => 'qtcreator_dark',
      HighlightTheme.qtcreator_light => 'qtcreator_light',
      _ => name.replaceAll('_', '-'),
    };
  }

  static HighlightTheme? fromThemeMapKey(String? key) {
    if (key == null) return null;
    for (final theme in values) {
      if (theme.themeMapKey == key) return theme;
    }
    return null;
  }
}

/// Language names and suffixes for highlighting.
enum ProgLang {
  apache(['conf']),
  applescript(['applescript']),
  arduino(['ino']),
  awk(['awk']),
  bash(['sh', 'bash']),
  bnf(['bnf']),
  c(['c', 'h']),
  clojure(['clj']),
  cmake(['cmake']),
  cpp(['cpp', 'cc', 'cxx', 'hpp', 'hxx', 'hh']),
  csharp(['cs']),
  css(['css']),
  dart(['dart']),
  delphi(['pas']),
  diff(['diff']),
  django(['django']),
  dockerfile(null, ['Dockerfile']),
  dust(['dust']),
  ebnf(['ebnf']),
  erlang(['erl']),
  excel(['xlsx']),
  fortran(['f90', 'f', 'for', 'f77', 'f95']),
  glsl(['glsl']),
  go(['go']),
  gradle(['gradle']),
  graphql(['graphql']),
  groovy(['groovy']),
  haskell(['hs']),
  ini(['ini']),
  java(['java']),
  javascript(['js', 'jsx']),
  json(['json']),
  julia(['jl']),
  kotlin(['kt', 'kts']),
  latex(['tex']),
  less(['less']),
  lisp(['lisp']),
  llvm(['ll']),
  lua(['lua']),
  makefile(null, ['Makefile']),
  markdown(['md', 'markdown']),
  matlab(['m']),
  nginx(['conf']),
  nim(['nim']),
  nix(['nix']),
  objectivec(['m', 'mm']),
  ocaml(['ml', 'mli']),
  perl(['pl', 'pm']),
  pgsql(['sql']),
  php(['php']),
  plaintext(['txt']),
  powershell(['ps1']),
  properties(['properties']),
  protobuf(['proto']),
  python(['py']),
  r(['r']),
  ruby(['rb']),
  rust(['rs']),
  scss(['scss']),
  shell(['sh', 'bash', 'zsh']),
  sql(['sql']),
  stylus(['styl']),
  swift(['swift']),
  typescript(['ts', 'tsx']),
  vbscript(['vbs']),
  verilog(['v']),
  vim(['vim']),
  vue(['vue']),
  wasm(['wasm']),
  wren(['wren']),
  x86asm(['asm']),
  xml(['xml']),
  yaml(['yaml', 'yml']),
  ;

  /// Suffixes for the language.
  final List<String>? suffixes;
  
  /// Filenames for the language. Entire filename match.
  final List<String>? filenames;

  const ProgLang([this.suffixes, this.filenames]);

  /// Get the [Mode] for the language.
  Mode get mode => switch (this) {
        apache => langApache,
        applescript => langApplescript,
        arduino => langArduino,
        awk => langAwk,
        bash => langBash,
        bnf => langBnf,
        c => langC,
        clojure => langClojure,
        cmake => langCmake,
        cpp => langCpp,
        csharp => langCsharp,
        css => langCss,
        dart => langDart,
        delphi => langDelphi,
        diff => langDiff,
        django => langDjango,
        dockerfile => langDockerfile,
        dust => langDust,
        ebnf => langEbnf,
        erlang => langErlang,
        excel => langExcel,
        fortran => langFortran,
        glsl => langGlsl,
        go => langGo,
        gradle => langGradle,
        graphql => langGraphql,
        groovy => langGroovy,
        haskell => langHaskell,
        ini => langIni,
        java => langJava,
        javascript => langJavascript,
        json => langJson,
        julia => langJulia,
        kotlin => langKotlin,
        latex => langLatex,
        less => langLess,
        lisp => langLisp,
        llvm => langLlvm,
        lua => langLua,
        makefile => langMakefile,
        markdown => langMarkdown,
        matlab => langMatlab,
        nginx => langNginx,
        nim => langNim,
        nix => langNix,
        objectivec => langObjectivec,
        ocaml => langOcaml,
        perl => langPerl,
        pgsql => langPgsql,
        php => langPhp,
        plaintext => langPlaintext,
        powershell => langPowershell,
        properties => langProperties,
        protobuf => langProtobuf,
        python => langPython,
        r => langR,
        ruby => langRuby,
        rust => langRust,
        scss => langScss,
        shell => langShell,
        sql => langSql,
        stylus => langStylus,
        swift => langSwift,
        typescript => langTypescript,
        vbscript => langVbscript,
        verilog => langVerilog,
        vim => langVim,
        vue => langVue,
        wasm => langWasm,
        wren => langWren,
        x86asm => langX86Asm,
        xml => langXml,
        yaml => langYaml,
      };

  /// Returns the language mode for the given file name.
  static ProgLang? parseFileName(String? fileName) {
    if (fileName == null) return null;
    final name = fileName.split('/').last;
    // 1. Try filename match
    for (final e in ProgLang.values) {
      if (e.filenames != null && e.filenames!.contains(name)) {
        return e;
      }
    }
    // 2. Try suffix match
    final ext = name.split('.').length > 1 ? name.split('.').last : null;
    if (ext == null) return null;
    for (final e in ProgLang.values) {
      if (e.suffixes != null && e.suffixes!.contains(ext)) {
        return e;
      }
    }
    return null;
  }

  /// Returns the language modes map for editor.
  Map<String, CodeHighlightThemeMode> get editorLangs {
    final map = {
      name: CodeHighlightThemeMode(
        mode: mode,
      ),
    };
    // Add plaintext mode for all languages. Only if not already present.
    map.putIfAbsent(
      plaintext.name,
      () => CodeHighlightThemeMode(mode: langPlaintext),
    );
    return map;
  }

  /// Default language mode map. With plaintext mode.
  static final defaultLangModeMap = {
    plaintext.name: CodeHighlightThemeMode(mode: langPlaintext),
  };

  /// All languages with their corresponding modes.
  ///
  /// It's not reconmended to use this map directly, as it will cause performance issues.
  static final allLangModesMap = {
    for (final e in ProgLang.values)
      e.name: CodeHighlightThemeMode(
        mode: e.mode,
      ),
  };
}
