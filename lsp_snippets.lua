--mod-version:3

-- LSP style snippet parser
-- shamelessly 'inspired by' (stolen from) LuaSnip
-- https://github.com/L3MON4D3/LuaSnip/blob/master/lua/luasnip/util/parser/neovim_parser.lua

local core     = require 'core'
local common   = require 'core.common'
local system   = require 'system'
local regex    = require 'regex'
local snippets = require 'plugins.snippets'

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
	TM_FILENAME      = function(ctx) return ctx.doc.filename:match("[^/%\\]*$") or '' end,
	TM_FILENAME_BASE = function(ctx) return ctx.doc.filename:match("([^/%\\]*)%.%w*$") or ctx.doc.filename end,
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
	for i, n in ipairs(v) do _s:add(n) end
	return _s:ok()
end


-- parser metatable

local P
do
	local mt = {
		__call = function(mt, parser, to_node)
			return setmetatable({ parser = parser, to_node = to_node }, mt)
		end,
		-- allows 'lazy arguments'; i.e can use a yet to be defined rule in a previous rule
		__index = function(t, k)
			return function(...) return t[k](...) end
		end
	}

	P = setmetatable({
		__call = function(t, str, at, _s)
			local msg
			local r = t.parser(str, at, _s)
			if r.ok and t.to_node then
				r.value = t.to_node(r.value, _s)
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


-- API

local function parse(template)
	local _s = B.new()
	local r = P.snippet(template, 1, _s)
	return r.ok and r.at == #template + 1 and r.value or B.new():s(template):ok()
end

snippets.parsers.lsp = parse

return {
	parse = parse
}
