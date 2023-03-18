--mod-version:3

-- LSP style snippet parser
-- shamelessly 'inspired by' (stolen from) LuaSnip
-- https://github.com/L3MON4D3/LuaSnip/blob/master/lua/luasnip/util/parser/neovim_parser.lua

local core     = require 'core'
local common   = require 'core.common'
local Doc      = require 'core.doc'
local system   = require 'system'
local regex    = require 'regex'
local snippets = require 'plugins.snippets'

local json do
	local ok, j = pcall(require, 'plugins.json')
	if not ok then
		local extra_paths = { 'lsp', 'lintplus' }
		for _, p in ipairs(extra_paths) do
			ok, j = pcall(require, 'plugins.' .. p .. '.json')
			if ok then break end
		end
	end
	json = ok and j
end


local B = snippets.builder

local LAST_CONVERTED_ID = { }


-- node factories

local variables = {
	-- LSP
	TM_SELECTED_TEXT = function(ctx) return ctx.selection end,
	TM_CURRENT_LINE  = function(ctx) return ctx.doc.lines[ctx.line] end,
	TM_CURRENT_WORD  = function(ctx) return ctx.partial end,
	TM_LINE_INDEX    = function(ctx) return ctx.line - 1 end,
	TM_LINE_NUMBER   = function(ctx) return ctx.line end,
	TM_FILENAME      = function(ctx) return ctx.doc.filename:match('[^/%\\]*$') or '' end,
	TM_FILENAME_BASE = function(ctx) return ctx.doc.filename:match('([^/%\\]*)%.%w*$') or ctx.doc.filename end,
	TM_DIRECTORY     = function(ctx) return ctx.doc.filename:match('([^/%\\]*)[/%\\].*$') or '' end,
	TM_FILEPATH      = function(ctx) return common.dirname(ctx.doc.abs_filename) or '' end,
	-- VSCode
	RELATIVE_FILEPATH = function(ctx) return core.normalize_to_project_dir(ctx.doc.filename) end,
	-- ?
	-- https://github.com/lite-xl/lite-xl/blob/master/data/core/commands/doc.lua#L243
	CLIPBOARD         = function() return system.get_clipboard() end,
	-- ??
	WORKSPACE_NAME    = function(ctx) return end,
	WORKSPACE_FOLDER  = function(ctx) return end,
	CURSOR_INDEX      = function(ctx) return ctx.col - 1 end,
	CURSOR_NUMBER     = function(ctx) return ctx.col end,
	-- os.date() is a strftime() delegate
	-- https://www.lua.org/manual/5.4/manual.html#pdf-os.date
	-- https://en.cppreference.com/w/c/chrono/strftime
	CURRENT_YEAR             = function() return os.date('%G') end,
	CURRENT_YEAR_SHORT       = function() return os.date('%g') end,
	CURRENT_MONTH            = function() return os.date('%m') end,
	CURRENT_MONTH_NAME       = function() return os.date('%B') end,
	CURRENT_MONTH_NAME_SHORT = function() return os.date('%b') end,
	CURRENT_DATE             = function() return os.date('%d') end,
	CURRENT_DAY_NAME         = function() return os.date('%A') end,
	CURRENT_DAY_NAME_SHORT   = function() return os.date('%a') end,
	CURRENT_HOUR             = function() return os.date('%H') end,
	CURRENT_MINUTE           = function() return os.date('%M') end,
	CURRENT_SECOND           = function() return os.date('%S') end,
	CURRENT_SECONDS_UNIX     = function() return os.time() end,
	RANDOM                   = function() return string.format('%06d', math.random(999999)) end,
	RANDOM_HEX               = function() return string.format('%06x', math.random(0xFFFFFF)) end
	-- https://code.visualstudio.com/docs/editor/userdefinedsnippets#_variables
	-- UUID
	-- BLOCK_COMMENT_START
	-- BLOCK_COMMENT_END
	-- BLOCK_COMMENT_END
}

local formatters; formatters = {
	downcase   = string.lower,
	upcase     = string.upper,
	capitalize = function(str)
		return str:sub(1, 1):upper() .. str:sub(2)
	end,
	pascalcase = function(str)
		local t = { }
		for s in str:gmatch('%w+') do
			table.insert(t, formatters.capitalize(s))
		end
		return table.concat(t)
	end,
	camelcase  = function(str)
		str = formatters.pascalcase(str)
		return str:sub(1, 1):lower() .. str:sub(2)
	end
}

local function to_text(v, _s)
	return v.esc
end

local function format_fn(v, _s)
	local id = tonumber(v[2])

	-- $1 | ${1}
	if #v < 4 then
		return function(captures)
			return captures[id] or ''
		end
	end

	-- ${1:...}
	local t = v[3][2][1] -- token after the ':' | (else when no token)
	local i = v[3][2][2] -- formatter | if | (else when no if)
	local e = v[3][2][4] -- (else when if)

	if t == '/' then
		local f = formatters[i]
		return function(captures)
			local c = captures[id]
			return c and f(c) or ''
		end
	elseif t == '+' then
		return function(captures)
			return captures[id] and i or ''
		end
	elseif t == '?' then
		return function(captures)
			return captures[id] and i or e
		end
	elseif t == '-' then
		return function(captures)
			return captures[id] or i
		end
	else
		return function(captures)
			return captures[id] or t
		end
	end
end

local function transform_fn(v, _s)
	local reg = regex.compile(v[2], v[#v])
	local fmt = v[4]

	if type(fmt) ~= 'table' then
		return function(str)
			return reg:gsub(str, '')
		end
	end

	local t = { }
	for _, f in ipairs(fmt) do
		if type(f) == 'string' then
			table.insert(t, f)
		else
			break
		end
	end

	if #t == #fmt then
		t = table.concat(t)
		return function(str)
			return reg:gsub(str, t)
		end
	end

	return function(str)
		local captures = { reg:match(str) }
		for k, v in ipairs(captures) do
			if type(v) ~= 'string' then
				captures[k] = nil
			end
		end
		local t = { }
		for _, f in ipairs(fmt) do
			if type(f) == 'string' then
				table.insert(t, f)
			else
				table.insert(t, f(captures))
			end
		end
		return table.concat(t)
	end
end

local function text_node(v, _s)
	return B.static(v.esc)
end

local function variable_node(v, _s)
	-- lsp/vscode spec:
	-- > When a variable isn’t set, its default or the empty string is inserted.
	-- > When a variable is unknown (that is, its name isn’t defined) the name of
	-- > the variable is inserted and it is transformed into a placeholder.
	-- whatever that means, just convert to tabstop w/ default or transform

	local name = v[2]
	local var = variables[name]

	local id
	if not var then
		if not _s._converted_variables then
			id = os.time()
			_s._converted_variables = { [name] = id, [LAST_CONVERTED_ID] = id }
		else
			id = _s._converted_variables[name]
			if not id then
				id = _s._converted_variables[LAST_CONVERTED_ID] + 1
				_s._converted_variables[name] = id
				_s._converted_variables[LAST_CONVERTED_ID] = id
			end
		end
	end

	if #v ~= 4 then
		return var and B.static(var) or B.user(id, name)
	end

	if type(v[3]) == 'table' then
		-- vscode accepts empty default -> var name
		return var and B.static(var) or B.user(id, v[3][2] or name)
	end

	if not var then
		return B.user(id, nil, v[3])
	end

	return type(var) ~= 'function' and B.static(var) or B.static(function(ctx)
		return v[3](var(ctx))
	end)
end

local function tabstop_node(v, _s)
	local t = v[3] and v[3] ~= '}' and v[3] or nil
	return B.user(tonumber(v[2]), nil, t)
end

local function choice_node(v, _s)
	local id = tonumber(v[2])
	local c = { [v[4]] = true }
	if #v == 6 then
		for _, _c in ipairs(v[5]) do
			c[_c[2]] = true
		end
	end
	_s:choice(id, c)
	return B.user(id)
end

local function placeholder_node(v, _s)
	local id = tonumber(v[2])
	_s:default(id, v[4])
	return B.user(id)
end

local function build_snippet(v, _s)
	for _, n in ipairs(v) do _s:add(n) end
	return _s:ok()
end


-- parser metatable

local P do
	local mt = {
		__call = function(mt, parser, converter)
			return setmetatable({ parser = parser, converter = converter }, mt)
		end,
		-- allows 'lazy arguments'; i.e can use a yet to be defined rule in a previous rule
		__index = function(t, k)
			return function(...) return t[k](...) end
		end
	}

	P = setmetatable({
		__call = function(t, str, at, _s)
			local r = t.parser(str, at, _s)
			if r.ok and t.converter then
				r.value = t.converter(r.value, _s)
			end
			return r
		end
	}, mt)
end


-- utils

local function toset(t)
	local r = { }
	for _, v in pairs(t or { }) do
		r[v] = true
	end
	return r
end

local function fail(at)
	return { at = at }
end

local function ok(at, v)
	return { ok = true, at = at, value = v }
end


-- base + combinators

local function token(t)
	return function(str, at)
		local to = at + #t
		return t == str:sub(at, to - 1) and ok(to, t) or fail(at)
	end
end

local function consume(stops, escapes)
	stops, escapes = toset(stops), toset(escapes)
	return function(str, at)
		local to = at
		local raw, esc = { }, { }
		local c = str:sub(to, to)
		while to <= #str and not stops[c] do
			if c == '\\' then
				table.insert(raw, c)
				to = to + 1
				c = str:sub(to, to)
				if not stops[c] and not escapes[c] then
					table.insert(esc, '\\')
				end
			end
			table.insert(raw, c)
			table.insert(esc, c)
			to = to + 1
			c = str:sub(to, to)
		end
		return to ~= at and ok(to, { raw = table.concat(raw), esc = table.concat(esc) }) or fail(at)
	end
end

local function pattern(p)
	return function(str, at)
		local r = str:match('^' .. p, at)
		return r and ok(at + #r, r) or fail(at)
	end
end

local function maybe(p)
	return function(str, at, ...)
		local r = p(str, at, ...)
		return ok(r.at, r.value)
	end
end

local function rep(p)
	return function(str, at, ...)
		local v, to, r = { }, at, ok(at)
		while to <= #str and r.ok do
			table.insert(v, r.value)
			to = r.at
			r = p(str, to, ...)
		end
		return #v > 0 and ok(to, v) or fail(at)
	end
end

local function any(...)
	local t = { ... }
	return function(str, at, ...)
		for _, p in ipairs(t) do
			local r = p(str, at, ...)
			if r.ok then return r end
		end
		return fail(at)
	end
end

local function seq(...)
	local t = { ... }
	return function(str, at, ...)
		local v, to = { }, at
		for _, p in ipairs(t) do
			local r = p(str, to, ...)
			if r.ok then
				table.insert(v, r.value)
				to = r.at
			else
				return fail(at)
			end
		end
		return ok(to, v)
	end
end


-- grammar rules

-- token cache
local t = setmetatable({ },
	{
		__index = function(t, k)
			local fn = token(k)
			rawset(t, k, fn)
			return fn
		end
	}
)

P.int = P(pattern('%d+'))

P.var = pattern('[%a_][%w_]*')

-- '}' needs to be escaped in normal text (i.e #0)
local __text0 = consume({ '$' },      { '\\', '}' })
local __text1 = consume({ '}' },      { '\\' })
local __text2 = consume({ ':' },      { '\\' })
local __text3 = consume({ '/' },      { '\\' })
local __text4 = consume({ '$', '}' }, { '\\' })
local __text5 = consume({ ',', '|' }, { '\\' })
local __text6 = consume({ "$", "/" }, { "\\" })

P._if1  = P(__text1, to_text)
P._if2  = P(__text2, to_text)
P._else = P(__text1, to_text)

P.options = pattern('%l*')

P.regex = P(__text3, to_text)

P.format = P(any(
	seq(t['$'],  P.int),
	seq(t['${'], P.int, maybe(seq(t[':'], any(
		seq(t['/'], any(t['upcase'], t['downcase'], t['capitalize'], t['pascalcase'], t['camelcase'])),
		seq(t['+'], P._if1),
		seq(t['?'], P._if2, t[':'], P._else),
		seq(t['-'], P._else),
		P._else
	))), t['}'])
), format_fn)

P.transform_text = P(__text6, to_text)
P.transform = P(
	seq(t['/'], P.regex, t['/'], rep(any(P.format, P.transform_text)), t['/'], P.options),
	transform_fn
)

P.variable_text = P(__text4, text_node)
P.variable = P(any(
	seq(t['$'],  P.var),
	seq(t['${'], P.var, maybe(any(
		-- grammar says a single mandatory 'any' for default, vscode seems to accept any*
		seq(t[':'], maybe(rep(any(P.dollars, P.variable_text)))),
		P.transform
	)), t['}'])
), variable_node)

P.choice_text = P(__text5, to_text)
P.choice = P(
	seq(t['${'], P.int, t['|'], P.choice_text, maybe(rep(seq(t[','], P.choice_text))), t['|}']),
	choice_node
)

P.placeholder_text = P(__text4, text_node)
P.placeholder = P(
	seq(t['${'], P.int, t[':'], maybe(rep(any(P.dollars, P.placeholder_text))), t['}']),
	placeholder_node
)

P.tabstop = P(any(
	seq(t['$'],  P.int),
	-- transform isnt specified in the grammar but seems to be supported by vscode
	seq(t['${'], P.int, maybe(P.transform), t['}'])
), tabstop_node)


P.dollars = any(P.tabstop, P.placeholder, P.choice, P.variable)

P.text = P(__text0, text_node)
P.any = any(P.dollars, P.text)

P.snippet = P(rep(P.any), build_snippet)


-- JSON files

-- defined at the end of the file
local extensions

local files = { }

local files2exts = { }
local exts2files = { }

local function add_file(filename, exts)
	if files[filename] ~= nil or not filename:match('%.json$') then return end
	if not exts then
		local lang_name = filename:match('([^/%\\]*)%.%w*$'):lower()
		exts = extensions[lang_name]
		if not exts then return end
	end
	files[filename] = false
	exts = type(exts) == 'string' and { exts } or exts
	for _, e in ipairs(exts) do
		files2exts[filename] = files2exts[filename] or { }
		table.insert(files2exts[filename], '%.' .. e .. '$')
		exts2files[e] = exts2files[e] or { }
		table.insert(exts2files[e], filename)
	end
end

local function parse_file(file)
	if files[file] then return end

	files[file] = true

	local _f = io.open(file)
	if not _f then return end
	local r = json.decode(_f:read('a'))
	_f:close()

	local exts = files2exts[file]
	for i, s in pairs(r) do
		local template = type(s.body) == 'table' and table.concat(s.body, '\n') or s.body
		snippets.add {
			trigger = s.prefix,
			format = 'lsp',
			files = exts,
			info = i,
			desc = s.description,
			template = template
		}
	end
end

local function for_filename(name)
	if not name then return end
	local ext = name:match('%.(.*)$')
	if not ext then return end
	local files = exts2files[ext]
	if not files then return end
	for _, f in ipairs(files) do
		parse_file(f)
	end
end

local doc_new = Doc.new
function Doc:new(filename, ...)
	doc_new(self, filename, ...)
	for_filename(filename)
end

local doc_set_filename = Doc.set_filename
function Doc:set_filename(filename, ...)
	doc_set_filename(self, filename, ...)
	for_filename(filename)
end


-- API

local M = { }

function M.parse(template)
	local _s = B.new()
	local r = P.snippet(template, 1, _s)
	return r.ok and r.at == #template + 1 and r.value or B.new():s(template):ok()
end

snippets.parsers.lsp = M.parse

local warned = false
function M.add_paths(paths)
	if not json then
		if not warned then
			core.error('Could not add snippet files: JSON plugin not found')
			warned = true
		end
		return
	end

	paths = type(paths) ~= 'table' and { paths } or paths

	for _, p in ipairs(paths) do
		-- non absolute paths are treated as relative from USERDIR
		p = not common.is_absolute_path(p) and (USERDIR .. PATHSEP .. p) or p
		local finfo = system.get_file_info(p)

		-- if path of a directory, add every file it contains and directories
		-- whose name is that of a lang
		if finfo and finfo.type == 'dir' then
			for _, f in ipairs(system.list_dir(p)) do
				f = p .. PATHSEP .. f
				finfo = system.get_file_info(f)
				if not finfo or finfo.type == 'file' then
					add_file(f)
				else
					-- only if the directory's name matches a language
					local lang_name = f:match('[^/%\\]*$'):lower()
					local exts = extensions[lang_name]
					for _, f2 in ipairs(system.list_dir(f)) do
						f2 = f .. PATHSEP .. f2
						finfo = system.get_file_info(f2)
						if not finfo or finfo.type == 'file' then
							add_file(f2, exts)
						end
					end
				end
			end
		-- if path of a file, add the file
		else
			add_file(p)
		end
	end
end


-- extension dump from https://gist.github.com/ppisarczyk/43962d06686722d26d176fad46879d41
-- nothing after this

-- 90% of these are useless but cba

extensions = {
	['abap'] = { 'abap', },
	['ags script'] = { 'asc', 'ash', },
	['ampl'] = { 'ampl', 'mod', },
	['antlr'] = { 'g4', },
	['api blueprint'] = { 'apib', },
	['apl'] = { 'apl', 'dyalog', },
	['asp'] = { 'asp', 'asax', 'ascx', 'ashx', 'asmx', 'aspx', 'axd', },
	['ats'] = { 'dats', 'hats', 'sats', },
	['actionscript'] = { 'as', },
	['ada'] = { 'adb', 'ada', 'ads', },
	['agda'] = { 'agda', },
	['alloy'] = { 'als', },
	['apacheconf'] = { 'apacheconf', 'vhost', },
	['apex'] = { 'cls', },
	['applescript'] = { 'applescript', 'scpt', },
	['arc'] = { 'arc', },
	['arduino'] = { 'ino', },
	['asciidoc'] = { 'asciidoc', 'adoc', 'asc', },
	['aspectj'] = { 'aj', },
	['assembly'] = { 'asm', 'a51', 'inc', 'nasm', },
	['augeas'] = { 'aug', },
	['autohotkey'] = { 'ahk', 'ahkl', },
	['autoit'] = { 'au3', },
	['awk'] = { 'awk', 'auk', 'gawk', 'mawk', 'nawk', },
	['batchfile'] = { 'bat', 'cmd', },
	['befunge'] = { 'befunge', },
	['bison'] = { 'bison', },
	['bitbake'] = { 'bb', },
	['blitzbasic'] = { 'bb', 'decls', },
	['blitzmax'] = { 'bmx', },
	['bluespec'] = { 'bsv', },
	['boo'] = { 'boo', },
	['brainfuck'] = { 'b', 'bf', },
	['brightscript'] = { 'brs', },
	['bro'] = { 'bro', },
	['c'] = { 'c', 'cats', 'h', 'idc', 'w', },
	['c#'] = { 'cs', 'cake', 'cshtml', 'csx', },
	['c++'] = { 'cpp', 'c++', 'cc', 'cp', 'cxx', 'h', 'h++', 'hh', 'hpp', 'hxx', 'inc', 'inl', 'ipp', 'tcc', 'tpp', },
	['c-objdump'] = { 'c-objdump', },
	['c2hs haskell'] = { 'chs', },
	['clips'] = { 'clp', },
	['cmake'] = { 'cmake', 'cmake.in', },
	['cobol'] = { 'cob', 'cbl', 'ccp', 'cobol', 'cpy', },
	['css'] = { 'css', },
	['csv'] = { 'csv', },
	['cap\'n proto'] = { 'capnp', },
	['cartocss'] = { 'mss', },
	['ceylon'] = { 'ceylon', },
	['chapel'] = { 'chpl', },
	['charity'] = { 'ch', },
	['chuck'] = { 'ck', },
	['cirru'] = { 'cirru', },
	['clarion'] = { 'clw', },
	['clean'] = { 'icl', 'dcl', },
	['click'] = { 'click', },
	['clojure'] = { 'clj', 'boot', 'cl2', 'cljc', 'cljs', 'cljs.hl', 'cljscm', 'cljx', 'hic', },
	['coffeescript'] = { 'coffee', '_coffee', 'cake', 'cjsx', 'cson', 'iced', },
	['coldfusion'] = { 'cfm', 'cfml', },
	['coldfusion cfc'] = { 'cfc', },
	['common lisp'] = { 'lisp', 'asd', 'cl', 'l', 'lsp', 'ny', 'podsl', 'sexp', },
	['component pascal'] = { 'cp', 'cps', },
	['cool'] = { 'cl', },
	['coq'] = { 'coq', 'v', },
	['cpp-objdump'] = { 'cppobjdump', 'c++-objdump', 'c++objdump', 'cpp-objdump', 'cxx-objdump', },
	['creole'] = { 'creole', },
	['crystal'] = { 'cr', },
	['cucumber'] = { 'feature', },
	['cuda'] = { 'cu', 'cuh', },
	['cycript'] = { 'cy', },
	['cython'] = { 'pyx', 'pxd', 'pxi', },
	['d'] = { 'd', 'di', },
	['d-objdump'] = { 'd-objdump', },
	['digital command language'] = { 'com', },
	['dm'] = { 'dm', },
	['dns zone'] = { 'zone', 'arpa', },
	['dtrace'] = { 'd', },
	['darcs patch'] = { 'darcspatch', 'dpatch', },
	['dart'] = { 'dart', },
	['diff'] = { 'diff', 'patch', },
	['dockerfile'] = { 'dockerfile', },
	['dogescript'] = { 'djs', },
	['dylan'] = { 'dylan', 'dyl', 'intr', 'lid', },
	['e'] = { 'E', },
	['ecl'] = { 'ecl', 'eclxml', },
	['eclipse'] = { 'ecl', },
	['eagle'] = { 'sch', 'brd', },
	['ecere projects'] = { 'epj', },
	['eiffel'] = { 'e', },
	['elixir'] = { 'ex', 'exs', },
	['elm'] = { 'elm', },
	['emacs lisp'] = { 'el', 'emacs', 'emacs.desktop', },
	['emberscript'] = { 'em', 'emberscript', },
	['erlang'] = { 'erl', 'es', 'escript', 'hrl', 'xrl', 'yrl', },
	['f#'] = { 'fs', 'fsi', 'fsx', },
	['flux'] = { 'fx', 'flux', },
	['fortran'] = { 'f90', 'f', 'f03', 'f08', 'f77', 'f95', 'for', 'fpp', },
	['factor'] = { 'factor', },
	['fancy'] = { 'fy', 'fancypack', },
	['fantom'] = { 'fan', },
	['filterscript'] = { 'fs', },
	['formatted'] = { 'for', 'eam.fs', },
	['forth'] = { 'fth', '4th', 'f', 'for', 'forth', 'fr', 'frt', 'fs', },
	['freemarker'] = { 'ftl', },
	['frege'] = { 'fr', },
	['g-code'] = { 'g', 'gco', 'gcode', },
	['gams'] = { 'gms', },
	['gap'] = { 'g', 'gap', 'gd', 'gi', 'tst', },
	['gas'] = { 's', 'ms', },
	['gdscript'] = { 'gd', },
	['glsl'] = { 'glsl', 'fp', 'frag', 'frg', 'fs', 'fsh', 'fshader', 'geo', 'geom', 'glslv', 'gshader', 'shader', 'vert', 'vrx', 'vsh', 'vshader', },
	['game maker language'] = { 'gml', },
	['genshi'] = { 'kid', },
	['gentoo ebuild'] = { 'ebuild', },
	['gentoo eclass'] = { 'eclass', },
	['gettext catalog'] = { 'po', 'pot', },
	['glyph'] = { 'glf', },
	['gnuplot'] = { 'gp', 'gnu', 'gnuplot', 'plot', 'plt', },
	['go'] = { 'go', },
	['golo'] = { 'golo', },
	['gosu'] = { 'gs', 'gst', 'gsx', 'vark', },
	['grace'] = { 'grace', },
	['gradle'] = { 'gradle', },
	['grammatical framework'] = { 'gf', },
	['graph modeling language'] = { 'gml', },
	['graphql'] = { 'graphql', },
	['graphviz (dot)'] = { 'dot', 'gv', },
	['groff'] = { 'man', '1', '1in', '1m', '1x', '2', '3', '3in', '3m', '3qt', '3x', '4', '5', '6', '7', '8', '9', 'l', 'me', 'ms', 'n', 'rno', 'roff', },
	['groovy'] = { 'groovy', 'grt', 'gtpl', 'gvy', },
	['groovy server pages'] = { 'gsp', },
	['hcl'] = { 'hcl', 'tf', },
	['hlsl'] = { 'hlsl', 'fx', 'fxh', 'hlsli', },
	['html'] = { 'html', 'htm', 'html.hl', 'inc', 'st', 'xht', 'xhtml', },
	['html+django'] = { 'mustache', 'jinja', },
	['html+eex'] = { 'eex', },
	['html+erb'] = { 'erb', 'erb.deface', },
	['html+php'] = { 'phtml', },
	['http'] = { 'http', },
	['hack'] = { 'hh', 'php', },
	['haml'] = { 'haml', 'haml.deface', },
	['handlebars'] = { 'handlebars', 'hbs', },
	['harbour'] = { 'hb', },
	['haskell'] = { 'hs', 'hsc', },
	['haxe'] = { 'hx', 'hxsl', },
	['hy'] = { 'hy', },
	['hyphy'] = { 'bf', },
	['idl'] = { 'pro', 'dlm', },
	['igor pro'] = { 'ipf', },
	['ini'] = { 'ini', 'cfg', 'prefs', 'pro', 'properties', },
	['irc log'] = { 'irclog', 'weechatlog', },
	['idris'] = { 'idr', 'lidr', },
	['inform 7'] = { 'ni', 'i7x', },
	['inno setup'] = { 'iss', },
	['io'] = { 'io', },
	['ioke'] = { 'ik', },
	['isabelle'] = { 'thy', },
	['j'] = { 'ijs', },
	['jflex'] = { 'flex', 'jflex', },
	['json'] = { 'json', 'geojson', 'lock', 'topojson', },
	['json5'] = { 'json5', },
	['jsonld'] = { 'jsonld', },
	['jsoniq'] = { 'jq', },
	['jsx'] = { 'jsx', },
	['jade'] = { 'jade', },
	['jasmin'] = { 'j', },
	['java'] = { 'java', },
	['java server pages'] = { 'jsp', },
	['javascript'] = { 'js', '_js', 'bones', 'es', 'es6', 'frag', 'gs', 'jake', 'jsb', 'jscad', 'jsfl', 'jsm', 'jss', 'njs', 'pac', 'sjs', 'ssjs', 'sublime-build', 'sublime-commands', 'sublime-completions', 'sublime-keymap', 'sublime-macro', 'sublime-menu', 'sublime-mousemap', 'sublime-project', 'sublime-settings', 'sublime-theme', 'sublime-workspace', 'sublime_metrics', 'sublime_session', 'xsjs', 'xsjslib', },
	['julia'] = { 'jl', },
	['jupyter notebook'] = { 'ipynb', },
	['krl'] = { 'krl', },
	['kicad'] = { 'sch', 'brd', 'kicad_pcb', },
	['kit'] = { 'kit', },
	['kotlin'] = { 'kt', 'ktm', 'kts', },
	['lfe'] = { 'lfe', },
	['llvm'] = { 'll', },
	['lolcode'] = { 'lol', },
	['lsl'] = { 'lsl', 'lslp', },
	['labview'] = { 'lvproj', },
	['lasso'] = { 'lasso', 'las', 'lasso8', 'lasso9', 'ldml', },
	['latte'] = { 'latte', },
	['lean'] = { 'lean', 'hlean', },
	['less'] = { 'less', },
	['lex'] = { 'l', 'lex', },
	['lilypond'] = { 'ly', 'ily', },
	['limbo'] = { 'b', 'm', },
	['linker script'] = { 'ld', 'lds', },
	['linux kernel module'] = { 'mod', },
	['liquid'] = { 'liquid', },
	['literate agda'] = { 'lagda', },
	['literate coffeescript'] = { 'litcoffee', },
	['literate haskell'] = { 'lhs', },
	['livescript'] = { 'ls', '_ls', },
	['logos'] = { 'xm', 'x', 'xi', },
	['logtalk'] = { 'lgt', 'logtalk', },
	['lookml'] = { 'lookml', },
	['loomscript'] = { 'ls', },
	['lua'] = { 'lua', 'fcgi', 'nse', 'pd_lua', 'rbxs', 'wlua', },
	['m'] = { 'mumps', 'm', },
	['m4'] = { 'm4', },
	['m4sugar'] = { 'm4', },
	['maxscript'] = { 'ms', 'mcr', },
	['mtml'] = { 'mtml', },
	['muf'] = { 'muf', 'm', },
	['makefile'] = { 'mak', 'd', 'mk', 'mkfile', },
	['mako'] = { 'mako', 'mao', },
	['markdown'] = { 'md', 'markdown', 'mkd', 'mkdn', 'mkdown', 'ron', },
	['mask'] = { 'mask', },
	['mathematica'] = { 'mathematica', 'cdf', 'm', 'ma', 'mt', 'nb', 'nbp', 'wl', 'wlt', },
	['matlab'] = { 'matlab', 'm', },
	['max'] = { 'maxpat', 'maxhelp', 'maxproj', 'mxt', 'pat', },
	['mediawiki'] = { 'mediawiki', 'wiki', },
	['mercury'] = { 'm', 'moo', },
	['metal'] = { 'metal', },
	['minid'] = { 'minid', },
	['mirah'] = { 'druby', 'duby', 'mir', 'mirah', },
	['modelica'] = { 'mo', },
	['modula-2'] = { 'mod', },
	['module management system'] = { 'mms', 'mmk', },
	['monkey'] = { 'monkey', },
	['moocode'] = { 'moo', },
	['moonscript'] = { 'moon', },
	['myghty'] = { 'myt', },
	['ncl'] = { 'ncl', },
	['nl'] = { 'nl', },
	['nsis'] = { 'nsi', 'nsh', },
	['nemerle'] = { 'n', },
	['netlinx'] = { 'axs', 'axi', },
	['netlinx+erb'] = { 'axs.erb', 'axi.erb', },
	['netlogo'] = { 'nlogo', },
	['newlisp'] = { 'nl', 'lisp', 'lsp', },
	['nginx'] = { 'nginxconf', 'vhost', },
	['nimrod'] = { 'nim', 'nimrod', },
	['ninja'] = { 'ninja', },
	['nit'] = { 'nit', },
	['nix'] = { 'nix', },
	['nu'] = { 'nu', },
	['numpy'] = { 'numpy', 'numpyw', 'numsc', },
	['ocaml'] = { 'ml', 'eliom', 'eliomi', 'ml4', 'mli', 'mll', 'mly', },
	['objdump'] = { 'objdump', },
	['objective-c'] = { 'm', 'h', },
	['objective-c++'] = { 'mm', },
	['objective-j'] = { 'j', 'sj', },
	['omgrofl'] = { 'omgrofl', },
	['opa'] = { 'opa', },
	['opal'] = { 'opal', },
	['opencl'] = { 'cl', 'opencl', },
	['openedge abl'] = { 'p', 'cls', },
	['openscad'] = { 'scad', },
	['org'] = { 'org', },
	['ox'] = { 'ox', 'oxh', 'oxo', },
	['oxygene'] = { 'oxygene', },
	['oz'] = { 'oz', },
	['pawn'] = { 'pwn', 'inc', },
	['php'] = { 'php', 'aw', 'ctp', 'fcgi', 'inc', 'php3', 'php4', 'php5', 'phps', 'phpt', },
	['plsql'] = { 'pls', 'pck', 'pkb', 'pks', 'plb', 'plsql', 'sql', },
	['plpgsql'] = { 'sql', },
	['pov-ray sdl'] = { 'pov', 'inc', },
	['pan'] = { 'pan', },
	['papyrus'] = { 'psc', },
	['parrot'] = { 'parrot', },
	['parrot assembly'] = { 'pasm', },
	['parrot internal representation'] = { 'pir', },
	['pascal'] = { 'pas', 'dfm', 'dpr', 'inc', 'lpr', 'pp', },
	['perl'] = { 'pl', 'al', 'cgi', 'fcgi', 'perl', 'ph', 'plx', 'pm', 'pod', 'psgi', 't', },
	['perl6'] = { '6pl', '6pm', 'nqp', 'p6', 'p6l', 'p6m', 'pl', 'pl6', 'pm', 'pm6', 't', },
	['pickle'] = { 'pkl', },
	['picolisp'] = { 'l', },
	['piglatin'] = { 'pig', },
	['pike'] = { 'pike', 'pmod', },
	['pod'] = { 'pod', },
	['pogoscript'] = { 'pogo', },
	['pony'] = { 'pony', },
	['postscript'] = { 'ps', 'eps', },
	['powershell'] = { 'ps1', 'psd1', 'psm1', },
	['processing'] = { 'pde', },
	['prolog'] = { 'pl', 'pro', 'prolog', 'yap', },
	['propeller spin'] = { 'spin', },
	['protocol buffer'] = { 'proto', },
	['public key'] = { 'asc', 'pub', },
	['puppet'] = { 'pp', },
	['pure data'] = { 'pd', },
	['purebasic'] = { 'pb', 'pbi', },
	['purescript'] = { 'purs', },
	['python'] = { 'py', 'bzl', 'cgi', 'fcgi', 'gyp', 'lmi', 'pyde', 'pyp', 'pyt', 'pyw', 'rpy', 'tac', 'wsgi', 'xpy', },
	['python traceback'] = { 'pytb', },
	['qml'] = { 'qml', 'qbs', },
	['qmake'] = { 'pro', 'pri', },
	['r'] = { 'r', 'rd', 'rsx', },
	['raml'] = { 'raml', },
	['rdoc'] = { 'rdoc', },
	['realbasic'] = { 'rbbas', 'rbfrm', 'rbmnu', 'rbres', 'rbtbar', 'rbuistate', },
	['rhtml'] = { 'rhtml', },
	['rmarkdown'] = { 'rmd', },
	['racket'] = { 'rkt', 'rktd', 'rktl', 'scrbl', },
	['ragel in ruby host'] = { 'rl', },
	['raw token data'] = { 'raw', },
	['rebol'] = { 'reb', 'r', 'r2', 'r3', 'rebol', },
	['red'] = { 'red', 'reds', },
	['redcode'] = { 'cw', },
	['ren\'py'] = { 'rpy', },
	['renderscript'] = { 'rs', 'rsh', },
	['robotframework'] = { 'robot', },
	['rouge'] = { 'rg', },
	['ruby'] = { 'rb', 'builder', 'fcgi', 'gemspec', 'god', 'irbrc', 'jbuilder', 'mspec', 'pluginspec', 'podspec', 'rabl', 'rake', 'rbuild', 'rbw', 'rbx', 'ru', 'ruby', 'thor', 'watchr', },
	['rust'] = { 'rs', 'rs.in', },
	['sas'] = { 'sas', },
	['scss'] = { 'scss', },
	['smt'] = { 'smt2', 'smt', },
	['sparql'] = { 'sparql', 'rq', },
	['sqf'] = { 'sqf', 'hqf', },
	['sql'] = { 'sql', 'cql', 'ddl', 'inc', 'prc', 'tab', 'udf', 'viw', },
	['sqlpl'] = { 'sql', 'db2', },
	['ston'] = { 'ston', },
	['svg'] = { 'svg', },
	['sage'] = { 'sage', 'sagews', },
	['saltstack'] = { 'sls', },
	['sass'] = { 'sass', },
	['scala'] = { 'scala', 'sbt', 'sc', },
	['scaml'] = { 'scaml', },
	['scheme'] = { 'scm', 'sld', 'sls', 'sps', 'ss', },
	['scilab'] = { 'sci', 'sce', 'tst', },
	['self'] = { 'self', },
	['shell'] = { 'sh', 'bash', 'bats', 'cgi', 'command', 'fcgi', 'ksh', 'sh.in', 'tmux', 'tool', 'zsh', },
	['shellsession'] = { 'sh-session', },
	['shen'] = { 'shen', },
	['slash'] = { 'sl', },
	['slim'] = { 'slim', },
	['smali'] = { 'smali', },
	['smalltalk'] = { 'st', 'cs', },
	['smarty'] = { 'tpl', },
	['sourcepawn'] = { 'sp', 'inc', 'sma', },
	['squirrel'] = { 'nut', },
	['stan'] = { 'stan', },
	['standard ml'] = { 'ML', 'fun', 'sig', 'sml', },
	['stata'] = { 'do', 'ado', 'doh', 'ihlp', 'mata', 'matah', 'sthlp', },
	['stylus'] = { 'styl', },
	['supercollider'] = { 'sc', 'scd', },
	['swift'] = { 'swift', },
	['systemverilog'] = { 'sv', 'svh', 'vh', },
	['toml'] = { 'toml', },
	['txl'] = { 'txl', },
	['tcl'] = { 'tcl', 'adp', 'tm', },
	['tcsh'] = { 'tcsh', 'csh', },
	['tex'] = { 'tex', 'aux', 'bbx', 'bib', 'cbx', 'cls', 'dtx', 'ins', 'lbx', 'ltx', 'mkii', 'mkiv', 'mkvi', 'sty', 'toc', },
	['tea'] = { 'tea', },
	['terra'] = { 't', },
	['text'] = { 'txt', 'fr', 'nb', 'ncl', 'no', },
	['textile'] = { 'textile', },
	['thrift'] = { 'thrift', },
	['turing'] = { 't', 'tu', },
	['turtle'] = { 'ttl', },
	['twig'] = { 'twig', },
	['typescript'] = { 'ts', 'tsx', },
	['unified parallel c'] = { 'upc', },
	['unity3d asset'] = { 'anim', 'asset', 'mat', 'meta', 'prefab', 'unity', },
	['uno'] = { 'uno', },
	['unrealscript'] = { 'uc', },
	['urweb'] = { 'ur', 'urs', },
	['vcl'] = { 'vcl', },
	['vhdl'] = { 'vhdl', 'vhd', 'vhf', 'vhi', 'vho', 'vhs', 'vht', 'vhw', },
	['vala'] = { 'vala', 'vapi', },
	['verilog'] = { 'v', 'veo', },
	['viml'] = { 'vim', },
	['visual basic'] = { 'vb', 'bas', 'cls', 'frm', 'frx', 'vba', 'vbhtml', 'vbs', },
	['volt'] = { 'volt', },
	['vue'] = { 'vue', },
	['web ontology language'] = { 'owl', },
	['webidl'] = { 'webidl', },
	['x10'] = { 'x10', },
	['xc'] = { 'xc', },
	['xml'] = { 'xml', 'ant', 'axml', 'ccxml', 'clixml', 'cproject', 'csl', 'csproj', 'ct', 'dita', 'ditamap', 'ditaval', 'dll.config', 'dotsettings', 'filters', 'fsproj', 'fxml', 'glade', 'gml', 'grxml', 'iml', 'ivy', 'jelly', 'jsproj', 'kml', 'launch', 'mdpolicy', 'mm', 'mod', 'mxml', 'nproj', 'nuspec', 'odd', 'osm', 'plist', 'pluginspec', 'props', 'ps1xml', 'psc1', 'pt', 'rdf', 'rss', 'scxml', 'srdf', 'storyboard', 'stTheme', 'sublime-snippet', 'targets', 'tmCommand', 'tml', 'tmLanguage', 'tmPreferences', 'tmSnippet', 'tmTheme', 'ts', 'tsx', 'ui', 'urdf', 'ux', 'vbproj', 'vcxproj', 'vssettings', 'vxml', 'wsdl', 'wsf', 'wxi', 'wxl', 'wxs', 'x3d', 'xacro', 'xaml', 'xib', 'xlf', 'xliff', 'xmi', 'xml.dist', 'xproj', 'xsd', 'xul', 'zcml', },
	['xpages'] = { 'xsp-config', 'xsp.metadata', },
	['xproc'] = { 'xpl', 'xproc', },
	['xquery'] = { 'xquery', 'xq', 'xql', 'xqm', 'xqy', },
	['xs'] = { 'xs', },
	['xslt'] = { 'xslt', 'xsl', },
	['xojo'] = { 'xojo_code', 'xojo_menu', 'xojo_report', 'xojo_script', 'xojo_toolbar', 'xojo_window', },
	['xtend'] = { 'xtend', },
	['yaml'] = { 'yml', 'reek', 'rviz', 'sublime-syntax', 'syntax', 'yaml', 'yaml-tmlanguage', },
	['yang'] = { 'yang', },
	['yacc'] = { 'y', 'yacc', 'yy', },
	['zephir'] = { 'zep', },
	['zimpl'] = { 'zimpl', 'zmpl', 'zpl', },
	['desktop'] = { 'desktop', 'desktop.in', },
	['ec'] = { 'ec', 'eh', },
	['edn'] = { 'edn', },
	['fish'] = { 'fish', },
	['mupad'] = { 'mu', },
	['nesc'] = { 'nc', },
	['ooc'] = { 'ooc', },
	['restructuredtext'] = { 'rst', 'rest', 'rest.txt', 'rst.txt', },
	['wisp'] = { 'wisp', },
	['xbase'] = { 'prg', 'ch', 'prw', },
}

extensions.cpp = extensions['c++']
extensions.csharp = extensions['c#']
extensions.latex = extensions.tex
extensions.objc = extensions['objective-c']


return M
