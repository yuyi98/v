// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module compiler

import (
	os
	strings
	filepath
	v.pref
	v.builder
)

pub const (
	Version = '0.1.25'
)

const (
	supported_platforms = ['windows', 'mac', 'macos', 'linux', 'freebsd', 'openbsd', 'netbsd',
		'dragonfly', 'android', 'js', 'solaris', 'haiku', 'linux_or_macos']
)

enum Pass {
	// A very short pass that only looks at imports in the beginning of
	// each file
	imports
	// First pass, only parses and saves declarations (fn signatures,
	// consts, types).
	// Skips function bodies.
	// We need this because in V things can be used before they are
	// declared.
	decl
	// Second pass, parses function bodies and generates C or machine code.
	main
}

pub struct V {
pub mut:
	mod_file_cacher     &ModFileCacher // used during lookup for v.mod to support @VROOT
	out_name_c          string // name of the temporary C file
	files               []string // all V files that need to be parsed and compiled
	compiled_dir        string // contains filepath.abs() of the dir of the final file beeing compiled, or the dir itself when doing `v .`
	table               &Table // table with types, vars, functions etc
	cgen                &CGen // C code generator
	//x64                 &x64.Gen
	pref                &pref.Preferences // all the preferences and settings extracted to a struct for reusability
	parsers             []Parser // file parsers
	vgen_buf            strings.Builder // temporary buffer for generated V code (.str() etc)
	file_parser_idx     map[string]int // map absolute file path to v.parsers index
	gen_parser_idx      map[string]int
	cached_mods         []string
	module_lookup_paths []string

	v_fmt_all           bool   // << input set by cmd/tools/vfmt.v
	v_fmt_file          string // << file given by the user from cmd/tools/vfmt.v
	v_fmt_file_result   string // >> file with formatted output generated by vlib/compiler/vfmt.v
}

pub fn new_v(pref &pref.Preferences) &V {
	rdir := filepath.abs(pref.path)

	mut out_name_c := get_vtmp_filename(pref.out_name, '.tmp.c')
	if pref.is_so {
		out_name_c = get_vtmp_filename(pref.out_name, '.tmp.so.c')
	}

	mut vgen_buf := strings.new_builder(1000)
	vgen_buf.writeln('module vgen\nimport strings')
	compiled_dir:=if os.is_dir(rdir) { rdir } else { filepath.dir(rdir) }

	return &V{
		mod_file_cacher: new_mod_file_cacher()
		compiled_dir:compiled_dir// if os.is_dir(rdir) { rdir } else { filepath.dir(rdir) }
		table: new_table(pref.obfuscate)
		out_name_c: out_name_c
		cgen: new_cgen(out_name_c)
		//x64: x64.new_gen(out_name)
		pref: pref
		vgen_buf: vgen_buf
	}
}

// Should be called by main at the end of the compilation process, to cleanup
pub fn (v &V) finalize_compilation() {
	// TODO remove
	if v.pref.autofree {
		/*
		println('started freeing v struct')
		v.table.typesmap.free()
		v.table.obf_ids.free()
		v.cgen.lines.free()
		free(v.cgen)
		for _, f in v.table.fns {
			//f.local_vars.free()
			f.args.free()
			//f.defer_text.free()
		}
		v.table.fns.free()
		free(v.table)
		//for p in parsers {}
		println('done!')
		*/
	}
}

pub fn (v mut V) add_parser(parser Parser) int {
	pidx := v.parsers.len
	v.parsers << parser
	file_path := if filepath.is_abs(parser.file_path) { parser.file_path } else { filepath.abs(parser.file_path) }
	v.file_parser_idx[file_path] = pidx
	return pidx
}

pub fn (v &V) get_file_parser_index(file string) ?int {
	file_path := if filepath.is_abs(file) { file } else { filepath.abs(file) }
	if file_path in v.file_parser_idx {
		return v.file_parser_idx[file_path]
	}
	return error('parser for "$file" not found')
}

// find existing parser or create new one. returns v.parsers index
pub fn (v mut V) parse(file string, pass Pass) int {
	// println('parse($file, $pass)')
	pidx := v.get_file_parser_index(file) or {
		mut p := v.new_parser_from_file(file)
		p.parse(pass)
		// if p.pref.autofree {		p.scanner.text.free()		free(p.scanner)	}
		return v.add_parser(p)
	}
	// println('matched ' + v.parsers[pidx].file_path + ' with $file')
	v.parsers[pidx].parse(pass)
	// if v.parsers[i].pref.autofree {	v.parsers[i].scanner.text.free()	free(v.parsers[i].scanner)	}
	return pidx
}

pub fn (v mut V) compile() {
	//println('compile()')
	// Emily: Stop people on linux from being able to build with msvc
	if os.user_os() != 'windows' && v.pref.ccompiler == 'msvc' {
		verror('Cannot build with msvc on ${os.user_os()}')
	}
	mut cgen := v.cgen
	cgen.genln('// Generated by V')
	if v.pref.is_verbose {
		println('all .v files before:')
		println(v.files)
	}
	v.add_v_files_to_compile()
	if v.pref.is_verbose {
		println('all .v files:')
		println(v.files)
	}
	/*
	if v.pref.is_debug {
		println('\nparsers:')
		for q in v.parsers {
			println(q.file_name)
		}
		println('\nfiles:')
		for q in v.files {
			println(q)
		}
	}
	*/

	// First pass (declarations)
	for file in v.files {
		v.parse(file, .decl)
	}
	// Main pass
	cgen.pass = .main
	if v.pref.is_debug {
		$if js {
			cgen.genln('const VDEBUG = 1;\n')
		} $else {
			cgen.genln('#define VDEBUG (1)')
		}
	}
	if v.pref.prealloc {
		cgen.genln('#define VPREALLOC (1)')
	}
	if v.pref.os == .js {
		cgen.genln('#define _VJS (1) ')
	}
	v_hash := vhash()
	$if js {
		cgen.genln('const V_COMMIT_HASH = "$v_hash";\n')
	} $else {
		cgen.genln('#ifndef V_COMMIT_HASH')
		cgen.genln('#define V_COMMIT_HASH "$v_hash"')
		cgen.genln('#endif')
	}
	q := cgen.nogen // TODO hack
	cgen.nogen = false
	$if js {
		cgen.genln(js_headers)
	} $else {
		if !v.pref.is_bare {
			cgen.genln('#include <inttypes.h>') // int64_t etc
		}
		else {
			cgen.genln('#include <stdint.h>')
		}

		if v.pref.compile_defines_all.len > 0 {
			cgen.genln('')
			cgen.genln('// All custom defines      : ' + v.pref.compile_defines_all.join(','))
			cgen.genln('// Turned ON custom defines: ' + v.pref.compile_defines.join(','))
			for cdefine in v.pref.compile_defines {
				cgen.genln('#define CUSTOM_DEFINE_${cdefine}')
			}
			cgen.genln('//')
			cgen.genln('')
		}

		cgen.genln(c_builtin_types)

		if !v.pref.is_bare {
			cgen.genln(c_headers)
		}
		else {
			cgen.genln(bare_c_headers)
		}
	}
	v.generate_hotcode_reloading_declarations()
	// We need the cjson header for all the json decoding that will be done in
	// default mode
	imports_json := 'json' in v.table.imports
	if v.pref.build_mode == .default_mode {
		if imports_json {
			cgen.genln('#include "cJSON.h"')
		}
	}
	if v.pref.build_mode == .default_mode {
		// If we declare these for all modes, then when running `v a.v` we'll get
		// `/usr/bin/ld: multiple definition of 'total_m'`
		$if !js {
			cgen.genln('int g_test_oks = 0;')
			cgen.genln('int g_test_fails = 0;')
		}
		if imports_json {
			cgen.genln('
#define js_get(object, key) cJSON_GetObjectItemCaseSensitive((object), (key))
')
		}
	}
	if '-debug_alloc' in os.args {
		cgen.genln('#define DEBUG_ALLOC 1')
	}
	if v.pref.is_live && v.pref.os != .windows {
		cgen.includes << '#include <dlfcn.h>'
	}
	// cgen.genln('/*================================== FNS =================================*/')
	cgen.genln('// this line will be replaced with definitions')
	mut defs_pos := cgen.lines.len - 1
	if defs_pos == -1 {
		defs_pos = 0
	}
	cgen.nogen = q
	for i, file in v.files {
		v.parse(file, .main)
		// if p.pref.autofree {		p.scanner.text.free()		free(p.scanner)	}
		// Format all files (don't format automatically generated vlib headers)
		// if !v.pref.nofmt && !file.contains('/vlib/') {
		// new vfmt is not ready yet
		// }
	}
	// add parser generated V code (str() methods etc)
	mut vgen_parser := v.new_parser_from_string(v.vgen_buf.str())
	// free the string builder which held the generated methods
	v.vgen_buf.free()
	vgen_parser.is_vgen = true
	// v.add_parser(vgen_parser)
	vgen_parser.parse(.main)
	// Generate .vh if we are building a module
	if v.pref.build_mode == .build_module {
		generate_vh(v.pref.path)
	}
	// All definitions
	mut def := strings.new_builder(10000) // Avoid unnecessary allocations
	def.writeln(cgen.const_defines.join_lines())
	$if !js {
		def.writeln(cgen.includes.join_lines())
		def.writeln(cgen.typedefs.join_lines())
		def.writeln(v.type_definitions())
		if !v.pref.is_bare {
			def.writeln('\nstring _STR(const char*, ...);\n')
			def.writeln('\nstring _STR_TMP(const char*, ...);\n')
		}
		def.writeln(cgen.fns.join_lines()) // fn definitions
		def.writeln(v.interface_table())
	} $else {
		def.writeln(v.type_definitions())
	}
	def.writeln(cgen.consts.join_lines())
	def.writeln(cgen.thread_args.join_lines())
	if v.pref.is_prof {
		def.writeln('; // Prof counters:')
		def.writeln(v.prof_counters())
	}
	cgen.lines[defs_pos] = def.str()
	v.generate_init()
	v.generate_main()
	v.generate_hot_reload_code()
	if v.pref.is_verbose {
		v.log('flags=')
		for flag in v.get_os_cflags() {
			println(' * ' + flag.format())
		}
	}
	$if js {
		cgen.genln('main__main();')
	}
	cgen.save()
	v.cc()
	//println(v.table.imports)
	//println(v.table.modules)
}

pub fn (v mut V) compile2() {
	if os.user_os() != 'windows' && v.pref.ccompiler == 'msvc' {
		verror('Cannot build with msvc on ${os.user_os()}')
	}
	//cgen.genln('// Generated by V')
	println('compile2()')
	if v.pref.is_verbose {
		println('all .v files before:')
		println(v.files)
	}
	// v1 compiler files
	//v.add_v_files_to_compile()
	//v.files << v.dir
	// v2 compiler
	v.files << v.get_builtin_files()
	v.files << v.get_user_files()
	v.set_module_lookup_paths()
	if v.pref.is_verbose {
		println('all .v files:')
		println(v.files)
	}
	mut b := v.new_v2()
	b.build_c(v.files, v.pref.out_name)
	v.cc()
}

pub fn (v mut V) compile_x64() {
	$if !linux {
		println('v -x64 can only generate Linux binaries for now')
		println('You are not on a Linux system, so you will not ' + 'be able to run the resulting executable')
	}
	//v.files << v.v_files_from_dir(filepath.join(v.pref.vlib_path,'builtin','bare'))
	v.files << v.pref.path
	v.set_module_lookup_paths()
	mut b := v.new_v2()
	// move all this logic to v2
	b.build_x64(v.files, v.pref.out_name)
}

// make v2 from v1
fn (v &V) new_v2() builder.Builder {
	mut b := builder.new_builder(v.pref)
	b = { b|
		os: v.pref.os,
		module_path: v_modules_path,
		compiled_dir: v.compiled_dir,
		module_search_paths: v.module_lookup_paths
	}
	return b
}

fn (v mut V) generate_init() {
	$if js {
		return
	}
	if v.pref.build_mode == .build_module {
		nogen := v.cgen.nogen
		v.cgen.nogen = false
		consts_init_body := v.cgen.consts_init.join_lines()
		init_fn_name := mod_gen_name(v.pref.mod) + '__init_consts'
		v.cgen.genln('void ${init_fn_name}();\nvoid ${init_fn_name}() {\n$consts_init_body\n}')
		v.cgen.nogen = nogen
	}
	if v.pref.build_mode == .default_mode {
		mut call_mod_init := ''
		mut call_mod_init_consts := ''
		if 'builtin' in v.cached_mods {
			v.cgen.genln('void builtin__init_consts();')
			call_mod_init_consts += 'builtin__init_consts();\n'
		}
		for mod in v.table.imports {
			init_fn_name := mod_gen_name(mod) + '__init'
			if v.table.known_fn(init_fn_name) {
				call_mod_init += '${init_fn_name}();\n'
			}
			if mod in v.cached_mods {
				v.cgen.genln('void ${init_fn_name}_consts();')
				call_mod_init_consts += '${init_fn_name}_consts();\n'
			}
		}
		consts_init_body := v.cgen.consts_init.join_lines()
		if v.pref.is_bare {
			// vlib can't have init_consts()
			v.cgen.genln('
          void init() {
                $call_mod_init_consts
                $consts_init_body
                builtin__init();
                $call_mod_init
          }
      ')
		}
		if !v.pref.is_bare && !v.pref.is_so {
			// vlib can't have `init_consts()`
			v.cgen.genln('void init() {
#if VPREALLOC
g_m2_buf = malloc(50 * 1000 * 1000);
g_m2_ptr = g_m2_buf;
puts("allocated 50 mb");
#endif
$call_mod_init_consts
$consts_init_body
builtin__init();
$call_mod_init
}')
			// _STR function can't be defined in vlib
			v.cgen.genln('
string _STR(const char *fmt, ...) {
	va_list argptr;
	va_start(argptr, fmt);
	size_t len = vsnprintf(0, 0, fmt, argptr) + 1;
	va_end(argptr);
	byte* buf = malloc(len);
	va_start(argptr, fmt);
	vsprintf((char *)buf, fmt, argptr);
	va_end(argptr);
#ifdef DEBUG_ALLOC
	puts("_STR:");
	puts(buf);
#endif
	return tos2(buf);
}

string _STR_TMP(const char *fmt, ...) {
	va_list argptr;
	va_start(argptr, fmt);
	//size_t len = vsnprintf(0, 0, fmt, argptr) + 1;
	va_end(argptr);
	va_start(argptr, fmt);
	vsprintf((char *)g_str_buf, fmt, argptr);
	va_end(argptr);
#ifdef DEBUG_ALLOC
	//puts("_STR_TMP:");
	//puts(g_str_buf);
#endif
	return tos2(g_str_buf);
}

')
		}
	}
}

pub fn (v mut V) generate_main() {
	mut cgen := v.cgen
	$if js {
		return
	}
	if v.pref.is_vlines {
		// After this point, the v files are compiled.
		// The rest is auto generated code, which will not have
		// different .v source file/line numbers.
		lines_so_far := cgen.lines.join('\n').count('\n') + 5
		cgen.genln('')
		cgen.genln('// Reset the file/line numbers')
		cgen.lines << '#line $lines_so_far "${cescaped_path(filepath.abs(cgen.out_path))}"'
		cgen.genln('')
	}
	// Make sure the main function exists
	// Obviously we don't need it in libraries
	if v.pref.build_mode != .build_module {
		if !v.table.main_exists() && !v.pref.is_test {
			// It can be skipped in single file programs
			// But make sure that there's some code outside of main()
			if (v.pref.is_script && cgen.fn_main.trim_space() != '') || v.pref.is_repl {
				// println('Generating main()...')
				v.gen_main_start(true)
				cgen.genln('$cgen.fn_main;')
				v.gen_main_end('return 0')
			}
			else if v.v_fmt_file=='' && !v.pref.is_repl {
				verror('function `main` is not declared in the main module\nPlease add: \nfn main(){\n}\n... to your main program .v file, and try again.')
			}
		}
		else if v.pref.is_test {
			if v.table.main_exists() {
				verror('test files cannot have function `main`')
			}
			test_fn_names := v.table.all_test_function_names()
			if test_fn_names.len == 0 {
				verror('test files need to have at least one test function')
			}
			// Generate a C `main`, which calls every single test function
			v.gen_main_start(false)
			if v.pref.is_stats {
				cgen.genln('BenchedTests bt = main__start_testing(${test_fn_names.len},tos3("$v.pref.path"));')
			}
			for tfname in test_fn_names {
				if v.pref.is_stats {
					cgen.genln('BenchedTests_testing_step_start(&bt, tos3("$tfname"));')
				}
				cgen.genln('${tfname}();')
				if v.pref.is_stats {
					cgen.genln('BenchedTests_testing_step_end(&bt);')
				}
			}
			if v.pref.is_stats {
				cgen.genln('BenchedTests_end_testing(&bt);')
			}
			v.gen_main_end('return g_test_fails > 0')
		}
		else if v.table.main_exists() && !v.pref.is_so {
			v.gen_main_start(true)
			cgen.genln('  main__main();')
			if !v.pref.is_bare {
				cgen.genln('#if VPREALLOC')
				cgen.genln('free(g_m2_buf);')
				cgen.genln('puts("freed mem buf");')
				cgen.genln('#endif')
			}
			v.gen_main_end('return 0')
		}
	}
}

pub fn (v mut V) gen_main_start(add_os_args bool) {
	if v.pref.os == .windows {
		if 'glfw' in v.table.imports {
			// GUI application
			v.cgen.genln('int WINAPI wWinMain(HINSTANCE instance, HINSTANCE prev_instance, LPWSTR cmd_line, int show_cmd) { ')
			v.cgen.genln('    typedef LPWSTR*(WINAPI *cmd_line_to_argv)(LPCWSTR, int*);')
			v.cgen.genln('    HMODULE shell32_module = LoadLibrary(L"shell32.dll");')
			v.cgen.genln('    cmd_line_to_argv CommandLineToArgvW = (cmd_line_to_argv)GetProcAddress(shell32_module, "CommandLineToArgvW");')
			v.cgen.genln('    int argc;')
			v.cgen.genln('    wchar_t** argv = CommandLineToArgvW(cmd_line, &argc);')
		} else {
			// Console application
			v.cgen.genln('int wmain(int argc, wchar_t* argv[], wchar_t* envp[]) { ')
		}
	} else {
		v.cgen.genln('int main(int argc, char** argv) { ')
	}
	v.cgen.genln('  init();')
	if add_os_args && 'os' in v.table.imports {
		if v.pref.os == .windows {
			v.cgen.genln('  os__args = os__init_os_args_wide(argc, argv);')
		} else {
			v.cgen.genln('  os__args = os__init_os_args(argc, (byteptr*)argv);')
		}
	}
	v.generate_hotcode_reloading_main_caller()
	v.cgen.genln('')
}

pub fn (v mut V) gen_main_end(return_statement string) {
	v.cgen.genln('')
	v.cgen.genln('  $return_statement;')
	v.cgen.genln('}')
}

pub fn (v &V) v_files_from_dir(dir string) []string {
	mut res := []string
	if !os.exists(dir) {
		if dir == 'compiler' && os.is_dir('vlib') {
			println('looks like you are trying to build V with an old command')
			println('use `v -o v cmd/v` instead of `v -o v compiler`')
		}
		verror("$dir doesn't exist")
	}
	else if !os.is_dir(dir) {
		verror("$dir isn't a directory")
	}
	mut files := os.ls(dir)or{
		panic(err)
	}
	if v.pref.is_verbose {
		println('v_files_from_dir ("$dir")')
	}
	files.sort()
	for file in files {
		if !file.ends_with('.v') && !file.ends_with('.vh') {
			continue
		}
		if file.ends_with('_test.v') {
			continue
		}
		if (file.ends_with('_win.v') || file.ends_with('_windows.v')) && v.pref.os != .windows {
			continue
		}
		if (file.ends_with('_lin.v') || file.ends_with('_linux.v')) && v.pref.os != .linux {
			continue
		}
		if (file.ends_with('_mac.v') || file.ends_with('_darwin.v')) && v.pref.os != .mac {
			continue
		}
		if file.ends_with('_nix.v') && v.pref.os == .windows {
			continue
		}
		if file.ends_with('_js.v') && v.pref.os != .js {
			continue
		}
		if file.ends_with('_c.v') && v.pref.os == .js {
			continue
		}
		if v.pref.compile_defines_all.len > 0 && file.contains('_d_') {
			mut allowed := false
			for cdefine in v.pref.compile_defines {
				file_postfix := '_d_${cdefine}.v'
				if file.ends_with(file_postfix) {
					allowed = true
					break
				}
			}
			if !allowed {
				continue
			}
		}
		res << filepath.join(dir,file)
	}
	return res
}

// Parses imports, adds necessary libs, and then user files
pub fn (v mut V) add_v_files_to_compile() {
	v.set_module_lookup_paths()
	mut builtin_files := v.get_builtin_files()
	if v.pref.is_bare {
		// builtin_files = []
	}
	// Builtin cache exists? Use it.
	if v.pref.is_cache {
		builtin_vh := filepath.join(v_modules_path,'vlib','builtin.vh')
		if os.exists(builtin_vh) {
			v.cached_mods << 'builtin'
			builtin_files = [builtin_vh]
		}
	}
	if v.pref.is_verbose {
		v.log('v.add_v_files_to_compile > builtin_files: $builtin_files')
	}
	// Parse builtin imports
	for file in builtin_files {
		// add builtins first
		v.files << file
		mut p := v.new_parser_from_file(file)
		p.parse(.imports)
		// if p.pref.autofree {		p.scanner.text.free()		free(p.scanner)	}
		v.add_parser(p)
	}
	// Parse user imports
	for file in v.get_user_files() {
		mut p := v.new_parser_from_file(file)
		p.parse(.imports)
		if p.v_script {
			v.log('imports0:')
			println(v.table.imports)
			println(v.files)
			p.register_import('os', 0)
			p.table.imports << 'os'
			p.table.register_module('os')
		}
		// if p.pref.autofree {		p.scanner.text.free()		free(p.scanner)	}
		v.add_parser(p)
	}
	// Parse lib imports
	v.parse_lib_imports()
	if v.pref.is_verbose {
		v.log('imports:')
		println(v.table.imports)
	}
	// resolve deps and add imports in correct order
	imported_mods := v.resolve_deps().imports()
	for mod in imported_mods {
		if mod == 'builtin' || mod == 'main' {
			// builtin already added
			// main files will get added last
			continue
		}
		// use cached built module if exists
		if v.pref.vpath != '' && v.pref.build_mode != .build_module && !mod.contains('vweb') {
			mod_path := mod.replace('.', filepath.separator)
			vh_path := '$v_modules_path${filepath.separator}vlib${filepath.separator}${mod_path}.vh'
			if v.pref.is_cache && os.exists(vh_path) {
				eprintln('using cached module `$mod`: $vh_path')
				v.cached_mods << mod
				v.files << vh_path
				continue
			}
		}
		// standard module
		vfiles := v.get_imported_module_files(mod)
		for file in vfiles {
			v.files << file
		}
	}
	// add remaining main files last
	for p in v.parsers {
		if p.mod != 'main' {
			continue
		}
		if p.is_vgen {
			continue
		}
		v.files << p.file_path
	}
}

pub fn (v &V) get_builtin_files() []string {
	// .vh cache exists? Use it
	if v.pref.is_bare {
		return v.v_files_from_dir(filepath.join(v.pref.vlib_path,'builtin','bare'))
	}
	$if js {
		return v.v_files_from_dir(filepath.join(v.pref.vlib_path,'builtin','js'))
	}
	return v.v_files_from_dir(filepath.join(v.pref.vlib_path,'builtin'))
}

// get user files
pub fn (v &V) get_user_files() []string {
	mut dir := v.pref.path
	v.log('get_v_files($dir)')
	// Need to store user files separately, because they have to be added after
	// libs, but we dont know	which libs need to be added yet
	mut user_files := []string

    // See cmd/tools/preludes/README.md for more info about what preludes are
	vroot := filepath.dir(pref.vexe_path())
	preludes_path := filepath.join(vroot,'cmd','tools','preludes')
	if v.pref.is_live {
		user_files << filepath.join(preludes_path,'live_main.v')
	}
	if v.pref.is_solive {
		user_files << filepath.join(preludes_path,'live_shared.v')
	}
	if v.pref.is_test {
		user_files << filepath.join(preludes_path,'tests_assertions.v')
	}
	if v.pref.is_test && v.pref.is_stats {
		user_files << filepath.join(preludes_path,'tests_with_stats.v')
	}

	is_test := dir.ends_with('_test.v')
	mut is_internal_module_test := false
	if is_test {
		tcontent := os.read_file(dir)or{
			panic('$dir does not exist')
		}
		if tcontent.contains('module ') && !tcontent.contains('module main') {
			is_internal_module_test = true
		}
	}
	if is_internal_module_test {
		// v volt/slack_test.v: compile all .v files to get the environment
		single_test_v_file := filepath.abs(dir)
		if v.pref.is_verbose {
			v.log('> Compiling an internal module _test.v file $single_test_v_file .')
			v.log('> That brings in all other ordinary .v files in the same module too .')
		}
		user_files << single_test_v_file
		dir = filepath.basedir(single_test_v_file)
	}
	if dir.ends_with('.v') || dir.ends_with('.vsh') {
		single_v_file := dir
		// Just compile one file and get parent dir
		user_files << single_v_file
		if v.pref.is_verbose {
			v.log('> just compile one file: "${single_v_file}"')
		}
	}
	else {
		if v.pref.is_verbose {
			v.log('> add all .v files from directory "${dir}" ...')
		}
		// Add .v files from the directory being compiled
		files := v.v_files_from_dir(dir)
		for file in files {
			user_files << file
		}
	}
	if user_files.len == 0 {
		println('No input .v files')
		exit(1)
	}
	if v.pref.is_verbose {
		v.log('user_files: $user_files')
	}
	return user_files
}

// get module files from already parsed imports
fn (v &V) get_imported_module_files(mod string) []string {
	mut files := []string
	for p in v.parsers {
		if p.mod == mod {
			files << p.file_path
		}
	}
	return files
}

// parse deps from already parsed builtin/user files
pub fn (v mut V) parse_lib_imports() {
	mut done_imports := []string
	for i in 0 .. v.parsers.len {
		for _, mod in v.parsers[i].import_table.imports {
			if mod in done_imports {
				continue
			}
			import_path := v.parsers[i].find_module_path(mod) or {
				v.parsers[i].error_with_token_index('cannot import module "$mod" (not found)\n$err', v.parsers[i].import_table.get_import_tok_idx(mod))
				break
			}
			vfiles := v.v_files_from_dir(import_path)
			if vfiles.len == 0 {
				v.parsers[i].error_with_token_index('cannot import module "$mod" (no .v files in "$import_path")', v.parsers[i].import_table.get_import_tok_idx(mod))
			}
			// Add all imports referenced by these libs
			for file in vfiles {
				pidx := v.parse(file, .imports)
				p_mod := v.parsers[pidx].mod
				if p_mod != mod {
					v.parsers[pidx].error_with_token_index('bad module definition: ${v.parsers[pidx].file_path} imports module "$mod" but $file is defined as module `$p_mod`', 0)
				}
			}
			done_imports << mod
		}
	}
}


pub fn (v &V) log(s string) {
	if !v.pref.is_verbose {
		return
	}
	println(s)
}

pub fn verror(s string) {
	println('V error: $s')
	os.flush()
	exit(1)
}

pub fn vhash() string {
	mut buf := [50]byte
	buf[0] = 0
	C.snprintf(charptr(buf), 50, '%s', C.V_COMMIT_HASH)
	return tos_clone(buf)
}

pub fn cescaped_path(s string) string {
	return s.replace('\\', '\\\\')
}

pub fn os_from_string(os string) pref.OS {
	match os {
		'linux' {
			return .linux
		}
		'windows' {
			return .windows
		}
		'mac' {
			return .mac
		}
		'macos' {
			return .mac
		}
		'freebsd' {
			return .freebsd
		}
		'openbsd' {
			return .openbsd
		}
		'netbsd' {
			return .netbsd
		}
		'dragonfly' {
			return .dragonfly
		}
		'js' {
			return .js
		}
		'solaris' {
			return .solaris
		}
		'android' {
			return .android
		}
		'msvc' {
			// notice that `-os msvc` became `-cc msvc`
			verror('use the flag `-cc msvc` to build using msvc')
		}
		'haiku' {
			return .haiku
		}
		'linux_or_macos' {
			return .linux
		}
		else {
			panic('bad os $os')
		}}
	// println('bad os $os') // todo panic?
	return .linux
}

//
pub fn set_vroot_folder(vroot_path string) {
	// Preparation for the compiler module:
	// VEXE env variable is needed so that compiler.vexe_path()
	// can return it later to whoever needs it:
	vname := if os.user_os() == 'windows' { 'v.exe' } else { 'v' }
	os.setenv('VEXE', filepath.abs([vroot_path, vname].join(filepath.separator)), true)
}
