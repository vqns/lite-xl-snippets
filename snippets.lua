-- mod-version:3


local core      = require 'core'
local command   = require 'core.command'
local config    = require 'core.config'
local common    = require 'core.common'
local Doc       = require 'core.doc'
local translate = require 'core.doc.translate'
local keymap    = require 'core.keymap'

local autocomplete
if config.plugins.autocomplete ~= false then
	local ok, a = pcall(require, 'plugins.autocomplete')
	autocomplete = ok and a
end


local raws    = { }
local cache   = { }
local active  = { }
local watches = { }
local parsers = { }


local SNIPPET_FIELDS   = { 'transforms', 'defaults', 'matches', 'choices' }
local DEFAULT_FORMAT   = { }
local DEFAULT_PATTERN  = '([%w_]+)[^%S\n]*$'
local DEFAULT_MATCH    = { kind = 'lua', pattern = DEFAULT_PATTERN }
local MATCH_TYPES      = { lua = true }
local AUTOCOMPLETE_KEY = { }


-- utils

local function unmask(x, ...)
	return type(x) == 'function' and x(...) or x
end

local function deep_copy(x)
	if type(x) ~= 'table' then return x end
	local r = { }
	for k, v in pairs(x) do
		r[k] = deep_copy(v)
	end
	return r
end

local function copy_snippet(_s)
	local s = common.merge(_s)
	local nodes = { }
	for _, n in ipairs(_s.nodes) do
		table.insert(nodes, common.merge(n))
	end
	s.nodes = nodes
	return s
end

local function autocomplete_cleanup()
	autocomplete.map_manually[AUTOCOMPLETE_KEY] = nil
end


-- trigger

local function normalize_match_patterns(patterns)
	local ret = { normalized = true }
	for _, p in ipairs(patterns) do
		if type(p) == 'string' then
			table.insert(ret, { kind = 'lua', pattern = p })
		elseif type(p) == 'table' then
			if p.kind ~= nil and not MATCH_TYPES[p.kind] then
				core.error('[snippets] invalid match kind: \'%s\'', p.kind)
				return
			end
			table.insert(ret, {
				kind    = p.kind or 'lua',
				pattern = p.pattern or DEFAULT_PATTERN,
				keep    = p.keep,
				strict  = p.strict
			})
		elseif p then
			table.insert(ret, DEFAULT_MATCH)
		else -- false?
			core.error('[snippets] invalid match: \'%s\'', p)
			return
		end
	end
	return ret
end

local function get_raw(raw)
	local _s

	if raw.template then
		local fmt = raw.format or DEFAULT_FORMAT
		_s = cache[fmt] and deep_copy(cache[fmt][raw.template])
		if not _s then
			local parser = parsers[fmt]
			if not parser then
				core.error('[snippets] no parser for format: %s', fmt)
				return
			end
			local _p = parser(raw.template)
			if not _p or not _p.nodes then return end
			_s = { nodes = common.merge(_p.nodes) }
			for _, v in ipairs(SNIPPET_FIELDS) do
				_s[v] = _p[v]
			end
			cache[fmt] = cache[fmt] or { }
			cache[fmt][raw.template] = deep_copy(_s)
		end
	elseif raw.nodes then
		_s = { nodes = common.merge(raw.nodes) }
	end

	if not _s then return end

	for _, v in ipairs(SNIPPET_FIELDS) do
		_s[v] = common.merge(_s[v], raw[v])
	end
	if not _s.matches.normalized then
		_s.matches = normalize_match_patterns(_s.matches)
		if not _s.matches then return end
	end

	return _s
end

local function get_by_id(id)
	local raw = raws[id]
	if not raw then return end
	local _s = get_raw(raw)
	if _s and not raw.matches.normalized then
		raw.matches = _s.matches
	end
	return _s
end

local function get_partial(doc)
	local l2, c2 = doc:get_selection()
	local l1, c1 = doc:position_offset(l2, c2, translate.start_of_word)
	local partial = doc:get_text(l1, c1, l2, c2)
	return partial
end

local function get_matching_partial(doc, partial, l1, c1)
	local sz = #partial
	if sz == 0 then return c1 end

	local n = c1 - 1
	local line = doc.lines[l1]
	for i = 1, sz + 1 do
		local j = sz - i
		local subline = line:sub(n - j, n)
		local subpartial = partial:sub(i, -1)
		if subpartial == subline then
			return n - j
		end
	end
end

local function get_matches(doc, patterns, l1, c1, l2, c2)
	local matches, removed = { }, { }
	if not l2 or not c2 then
		l2, c2 = l1, c1
		l1, c1 = 1, 1
	end

	local text = doc:get_text(l1, c1, l2, c2)

	for i, p in ipairs(patterns) do
		local match = not p.strict and ''
		local function sub_cb(...)
			match = select('#', ...) > 1 and { ... } or ...
			return ''
		end

		local sz = #text
		if p.kind == 'lua' then
			text = text:gsub(p.pattern or DEFAULT_PATTERN.pattern, sub_cb, 1)
		end

		if not match then
			core.error('[snippets] failed strict match #%d: \'%s\'', i, p.pattern)
			return
		end

		matches[i] = match

		local offset = #text - sz
		local _l, _c = doc:position_offset(l2, c2, offset)
		if not p.keep and offset ~= 0 then
			removed[i] = doc:get_text(_l, _c, l2, c2)
			doc:remove(_l, _c, l2, c2)
		end
		l2, c2 = _l, _c
	end

	return matches, removed
end


-- init

local resolve_nodes, resolve_one, resolve_static, resolve_user

local function concat_buf(into)
	if #into.buf == 0 then return end
	table.insert(
		into.nodes,
		{ kind = 'static', value = table.concat(into.buf) }
	)
	into.buf = { }
end

local function resolve_default(default, ctx, into)
	local v = unmask(default, ctx) or ''
	if type(v) ~= 'table' then return v end
	local inline_into = common.merge(into, { nodes = { }, buf = { } })
	resolve_one(v, ctx, inline_into)
	concat_buf(inline_into)
	return { inline = true, nodes = inline_into.nodes }
end

function resolve_user(n, ctx, into)
	local id = n.id
	if type(id) ~= 'number' or id < 0 then
		error(string.format('node id must be a positive number: %s', id), 0)
	end

	n = common.merge(n)
	concat_buf(into)
	table.insert(into.nodes, n)

	local tid = into.tabstops[id]
	if not tid then
		into.tabstops[id] = { count = 1, [n] = true }
	else
		tid[n] = true
		tid.count = tid.count + 1
	end

	local m = into.mains
	m[id] = not m[id] and n or (n.main and not m[id].main) and n or m[id]

	local v
	if n.default then                        -- node specific default
		v = resolve_default(n.default, ctx, into)
	elseif into.defaults[id] then            -- unresolved general default
		v = resolve_default(into.defaults[id], ctx, into)
	end

	local raw
	if type(v) ~= 'table' then
		v = v and tostring(v) or ''
	else
		raw = v
		if v.value then
			v = v.value
		else
			v = { }
			for _, _n in ipairs(raw.nodes) do
				local value = _n.value
				if type(value) == 'table' then value = value.value end
				table.insert(v, value)
			end
			v = table.concat(v)
			raw.value = v
		end
	end

	n.transform = not n.transform and into.transforms[id] or n.transform
	if raw then
		raw.value = v
		n.value = raw
	else
		n.value = v
	end
end

function resolve_static(n, ctx, into)
	local t, v = type(n), n
	if t == 'table' and n.kind then
		v = n.value
		t = type(v)
	end

	if t == 'table' then
		for _, _n in ipairs(v) do resolve_one(_n, ctx, into) end
	elseif t == 'function' then
		resolve_one(v(ctx), ctx, into)
	elseif t ~= 'nil' then
		table.insert(into.buf, tostring(v))
	end
end

function resolve_one(n, ctx, into)
	if type(n) == 'table' and n.kind == 'user' then
		resolve_user(n, ctx, into)
	elseif n ~= nil then
		resolve_static(n, ctx, into)
	end
end

function resolve_nodes(nodes, ctx, into)
	for _, n in ipairs(nodes) do resolve_one(n, ctx, into) end
	concat_buf(into)
	return into
end

local function init(_s)
	local ctx = _s.ctx
	if not ctx then return end

	local into = {
		buf      = { },
		nodes    = { },
		mains    = { },
		tabstops = { },
		defaults = _s.defaults,
		transforms = _s.transforms
	}

	local ok, n = pcall(resolve_nodes, _s.nodes, ctx, into)
	if not ok then
		core.error('[snippets] %s', n)
		return
	end

	_s.mains = n.mains
	_s.nodes = n.nodes
	_s.tabstops = n.tabstops

	return true
end


-- expand

local function push(_s)
	watches[_s.ctx.doc] = watches[_s.ctx.doc] or { }
	local watch = watches[_s.ctx.doc]
	local w1l, w1c = _s.watch.start_line, _s.watch.start_col
	local idx = 1
	for i = #watch, 1, -1 do
		local w2l, w2c = watch[i].start_line, watch[i].start_col
		if w2l < w1l or w2l == w1l and w2c < w1c then
			idx = i + 1; break
		end
	end
	common.splice(watch, idx, 0, _s.watches)

	local a = active[_s.ctx.doc]
	local ts = a.tabstops
	for id, _ in pairs(_s.tabstops) do
		local c = ts[id]
		ts[id] = c and c + 1 or 1
		a.max_id = math.max(id, a.max_id)
	end

	a._tabstops_as_array = nil
	table.insert(a, _s)
end

local function pop(_s)
	local watch = watches[_s.ctx.doc]
	local w1, w2 = _s.watches[1], _s.watches[#_s.watches]
	local i1, i2
	for i, w in ipairs(watch) do
		if w == w1 then i1 = i end
		if w == w2 then i2 = i; break end
	end
	common.splice(watch, i1, i2 - i1 + 1)

	local a = active[_s.ctx.doc]
	local ts = a.tabstops
	local max = false
	for id, _ in pairs(_s.tabstops) do
		ts[id] = ts[id] - 1
		if id == a.max_id and ts[id] == 0 then max = true end
	end
	if max then
		max = 0
		for id, _ in pairs(a.tabstops) do
			max = math.max(id, max)
		end
		a.max_id = max
	end

	local idx
	for i, s in ipairs(a) do
		if s == _s then idx = i; break end
	end

	a._tabstops_as_array = nil
	table.remove(a, idx)
end

local function insert_nodes(nodes, doc, l, c, watches, indent)
	local _l, _c
	for _, n in ipairs(nodes) do
		local w
		if n.kind == 'user' then
			w = { start_line = l, start_col = c }
			n.watch = w
			table.insert(watches, w)
		else
			n.value = n.value:gsub('\n', indent)
		end
		if type(n.value) == 'table' then
			_l, _c = insert_nodes(n.value.nodes, doc, l, c, watches, indent)
		else
			doc:insert(l, c, n.value)
			_l, _c = doc:position_offset(l, c, #n.value)
		end
		l, c = _l, _c
		if w then
			w.end_line, w.end_col = l, c
		end
	end
	return l, c
end

local function expand(_s)
	_s.watches = { _s.watch }
	local ctx = _s.ctx
	local l, c = ctx.line, ctx.col

	local _l, _c = insert_nodes(_s.nodes, ctx.doc, l, c, _s.watches, '\n' .. ctx.indent_str)
	_s.watch.end_line, _s.watch.end_col = _l, _c
	_s.value = ctx.doc:get_text(l, c, _l, _c)

	push(_s)
	return true
end


-- navigation

local function transforms_for(_s, id)
	local nodes = _s.tabstops[id]
	if not nodes or nodes.count == 0 then return end
	local doc = _s.ctx.doc
	for n in pairs(nodes) do
		if n == 'count' then goto continue end
		local w = n.watch
		if --[[not w.dirty or]] not n.transform then goto continue end

		local v = doc:get_text(w.start_line, w.start_col, w.end_line, w.end_col)
		local r = type(n.value) == 'table' and n.value or nil
		v = n.transform(v, r) or ''
		doc:remove(w.start_line, w.start_col, w.end_line, w.end_col)
		doc:insert(w.start_line, w.start_col, v)
		w.dirty = false

		::continue::
	end
end

local function transforms(snippets, id)
	for _, _s in ipairs(snippets) do
		transforms_for(_s, id)
	end
end

-- docview crashes while updating if the doc doesnt have selections
-- so instead gather all new selections & set it at once
local function selection_for_watch(sels, w, end_only)
	table.insert(sels, w.end_line)
	table.insert(sels, w.end_col)
	table.insert(sels, end_only and w.end_line or w.start_line)
	table.insert(sels, end_only and w.end_col  or w.start_col)
end

local function select_after(snippets)
	local doc = snippets.doc
	local new_sels = { }
	for _, _s in ipairs(snippets) do
		selection_for_watch(new_sels, _s.watch, true)
	end
	if #new_sels > 0 then
		doc.selections = new_sels
		doc.last_selection = #new_sels / 4
	end
end

local function next_id(snippets, reverse)
	local id, ts = snippets.last_id, snippets.tabstops

	-- performance issues when iterating above that
	-- 100k should be fine still so 10k just in case
	if snippets.max_id > 10000 then
		ts = snippets._tabstops_as_array
		if not ts then
			ts = { }
			for i in pairs(snippets.tabstops) do table.insert(ts, i) end
			table.sort(ts)
			local last = 0
			for i, _id in ipairs(ts) do if _id == id then last = i; break end end
			ts = { array = ts, last = last - 1 }
			snippets._tabstops_as_array = ts
		end
		local sz = #ts.array
		ts.last = reverse and ((ts.last - 1 + sz) % sz) or ((ts.last + 1) % sz)
		return ts.array[ts.last + 1]
	end

	local wrap = reverse and 1 or snippets.max_id
	local to = reverse and snippets.max_id + 1 or 0
	local i = reverse and -1 or 1
	local old = id
	repeat
		if id == wrap then id = to end
		id = id + i
	until (ts[id] and ts[id] > 0) or id == old
	return id ~= old and id
end

local function set_tabstop(snippets, id)
	local doc = snippets.doc
	local choices = autocomplete and { }
	local new_sels = { }

	for _, _s in ipairs(snippets) do
		local nodes = _s.tabstops[id]
		if not nodes or nodes.count == 0 then goto continue end
		for n in pairs(nodes) do
			if n ~= 'count' then
				selection_for_watch(new_sels, n.watch)
			end
		end
		::continue::
		if choices and _s.choices[id] then
			for k, v in pairs(_s.choices[id]) do choices[k] = v end
		end
	end

	if #new_sels > 0 then
		doc.selections = new_sels
		doc.last_selection = #new_sels / 4
		if choices and next(choices) then
			autocomplete.complete(
				{ name = AUTOCOMPLETE_KEY, items = choices },
				autocomplete_cleanup
			)
		end
	end
	snippets.last_id = id
end


-- watching

local raw_insert, raw_remove = Doc.raw_insert, Doc.raw_remove

function Doc:raw_insert(l1, c1, t, undo, ...)
	raw_insert(self, l1, c1, t, undo, ...)
	local watch = watches[self]
	if not watch then return end

	local u = undo[undo.idx - 1]
	local l2, c2 = u[3], u[4]

	local ldiff, cdiff = l2 - l1, c2 - c1
	for i = #watch, 1, -1 do
		local w = watch[i]
		local d1, d2 = true, false

		if w.end_line > l1 then
			w.end_line = w.end_line + ldiff
		elseif w.end_line == l1 and w.end_col >= c1 then
			w.end_line = w.end_line + ldiff
			w.end_col = w.end_col + cdiff
		else
			d1 = false
		end

		if w.start_line > l1 then
			w.start_line = w.start_line + ldiff
		elseif w.start_line == l1 and w.start_col > c1 then
			w.start_line = w.start_line + ldiff
			w.start_col = w.start_col + cdiff
		else
			d2 = true
		end

		w.dirty = w.dirty or (d1 and d2)
	end
end

function Doc:raw_remove(l1, c1, l2, c2, ...)
	raw_remove(self, l1, c1, l2, c2, ...)
	local watch = watches[self]
	if not watch then return end

	local ldiff, cdiff = l2 - l1, c2 - c1
	for i = #watch, 1, -1 do
		local w = watch[i]
		local d1, d2 = true, false
		local wsl, wsc, wel, wec = w.start_line, w.start_col, w.end_line, w.end_col

		if wel > l1 or (wel == l1 and wec > c1) then
			if wel > l2 then
				w.end_line = wel - ldiff
			else
				w.end_line = l1
				w.end_col = (wel == l2 and wec > c2) and wec - cdiff or c1
			end
		else
			d1 = false
		end

		if wsl > l1 or (wsl == l1 and wsc > c1) then
			if wsl > l2 then
				w.start_line = wsl - ldiff
			else
				w.start_line = l1
				w.start_col = (wsl == l2 and wsc > c2) and wsc - cdiff or c1
			end
		else
			d2 = true
		end

		w.dirty = w.dirty or (d1 and d2)
	end
end


-- API
-- every function that takes 'snippets' assume that all given snippets are in the same doc
-- and the table has the same schema as return from in_snippet

local M = { parsers = parsers }

M.parsers[DEFAULT_FORMAT] = function(s) return { kind = 'static', value = s } end

local function ac_callback(_, item)
	return M.execute(item.data, nil, true)
end

function M.add(snippet)
	local _s = { }

	if snippet.template then
		_s.template = snippet.template
		_s.format   = snippet.format or DEFAULT_FORMAT
	elseif snippet.nodes then
		_s.nodes = snippet.nodes
	else
		return
	end

	for _, v in ipairs(SNIPPET_FIELDS) do
		_s[v] = snippet[v] or { }
	end

	local id = os.time() + math.random()

	local ac
	if autocomplete and snippet.trigger then
		ac = {
			info = snippet.info,
			desc = snippet.desc or snippet.template,
			onselect = ac_callback,
			data = id
		}
		autocomplete.add {
			name  = id,
			files = snippet.files,
			items = { [snippet.trigger] = ac }
		}
	end

	raws[id] = _s
	return id, ac
end

function M.remove(id)
	raws[id] = nil
	cache[id] = nil
	if autocomplete then
		autocomplete.map[id] = nil
	end
end

function M.execute(snippet, doc, partial)
	doc = doc or core.active_view.doc
	if not doc then return end

	local _t, _s = type(snippet)
	if _t == 'number' then
        _s = get_by_id(snippet)
	elseif _t == 'table' then
		_s = get_raw(snippet)
	end

	if not _s then return end

	local undo_idx = doc.undo_stack.idx

	-- special handling of autocomplete pt 1
	-- suggestions are only reset after the item has been handled
	-- i.e once this function (M.execute) returns
	-- so at this point here, it still has old suggestions,
	-- including manually added snippet choices
	if partial and autocomplete then
		autocomplete.close()
	end

	partial = partial and get_partial(doc)
	local snippets = { }

	for idx, l1, c1, l2, c2 in doc:get_selections(true, true) do
		snippet = idx > 1 and copy_snippet(_s) or _s
		local ctx = {
			doc = doc,
			cursor_idx = idx,
			at_line = l1, at_col = c1,
			partial = '', selection = '',
			extra = { }
		}

		local n
		if l1 ~= l2 or c1 ~= c2 then
			n = 'selection'
		elseif partial then
			n = 'partial'
			c1 = get_matching_partial(doc, partial, l1, c1)
		end
		if n then
			ctx[n] = ctx.doc:get_text(l1, c1, l2, c2)
			ctx.doc:remove(l1, c1, l2, c2)
		end

		local matches, removed
		if idx == 1 then
			l2, c2 = 1, 1
		else
			local _; _, _, l2, c2 = doc:get_selection_idx(idx - 1, true)
		end
		ctx.matches, ctx.removed_from_matches = get_matches(doc, _s.matches, l2, c2, l1, c1)

		if not ctx.matches then
			while doc.undo_stack.idx > undo_idx do doc:undo() end
			return
		end

		snippet.ctx = ctx
		snippets[idx] = snippet
	end

	local a = {
		doc = doc, parent = active[doc],
		tabstops = { }, last_id = 0, max_id = 0
	}
	active[doc] = a

	for idx, l, c in doc:get_selections(true, true) do
		_s = snippets[idx]
		local ctx = _s.ctx
		ctx.indent_sz, ctx.indent_str = doc:get_line_indent(doc.lines[l])
		ctx.line, ctx.col = l, c
		_s.watch = { start_line = l, start_col = c, end_line = l, end_col = c }
		if not init(_s) or not expand(_s) then
			-- restores the doc to the original state, except for autocomplete
			-- since there's no clean way to notify it to show auto suggestions
			while doc.undo_stack.idx > undo_idx do doc:undo() end
			active[doc] = a.parent
			return
		end
	end

	if a.max_id > 0 then
		M.next(a)
	else
		M.exit(a)
	end

	-- special handling of autocomplete pt 2
	-- since suggestions are reset once this function returns,
	-- this means that choices for the 1st tabstop set in the M.next call
	-- will be removed
	-- so use on_close to reopen them as a workaround
	if autocomplete and autocomplete.map_manually[AUTOCOMPLETE_KEY] then
		autocomplete.on_close = function()
			autocomplete.open(autocomplete_cleanup)
		end
	end

	return true
end

function M.select_current(snippets)
	if #snippets == 0 then return end
	local id = snippets.last_id
	if id then set_tabstop(snippets, id) end
end

function M.next(snippets)
	if #snippets == 0 then return end
	local id = next_id(snippets)
	if id then
		if snippets.last_id ~= 0 then transforms(snippets, snippets.last_id) end
		set_tabstop(snippets, id)
	end
end

function M.previous(snippets)
	if #snippets == 0 then return end
	local id = next_id(snippets, true)
	if id then
		if snippets.last_id ~= 0 then transforms(snippets, snippets.last_id) end
		set_tabstop(snippets, id)
	end
end

function M.exit(snippets)
	if #snippets == 0 then return end
	local doc = snippets.doc
	local c = snippets.tabstops[0]; c = c and c > 0
	local p = snippets.parent

	if snippets.last_id ~= 0 then transforms(snippets, snippets.last_id) end

	if p then
		for _, _s in ipairs(snippets) do pop(_s) end
		active[doc] = p
		M.next_or_exit(p)
	else
		if c then
			set_tabstop(snippets, 0)
		else
			select_after(snippets)
		end
		if snippets == active[doc] then
			active[doc] = nil
			watches[doc] = nil
		else
			for _, _s in ipairs(snippets) do pop(_s) end
		end
	end
end

function M.next_or_exit(snippets)
	if #snippets == 0 then return end
	local id = snippets.last_id
	if id == snippets.max_id then
		M.exit(snippets)
	else
		M.next(snippets)
	end
end

function M.in_snippet(doc)
	doc = doc or core.active_view.doc
	if not doc then return end
	local t = active[doc]
	if t and #t > 0 then return t, t end
end


-- commands

command.add(M.in_snippet, {
	['snippets:select-current'] = M.select_current,
	['snippets:next']           = M.next,
	['snippets:previous']       = M.previous,
	['snippets:exit']           = M.exit,
	['snippets:next-or-exit']   = M.next_or_exit
})

keymap.add {
	['tab']       = 'snippets:next-or-exit',
	['shift+tab'] = 'snippets:previous',
	['escape']    = 'snippets.exit'
}

do -- 'next' is added to keymap after 'complete' so it overrides autocomplete
	local keys = keymap.get_bindings('autocomplete:complete')
	if not keys then goto continue end
	for _, k in ipairs(keys) do
		if k == 'tab' then
			keymap.unbind('tab', 'autocomplete:complete')
			keymap.add { ['tab'] = 'autocomplete:complete' }
			break
		end
	end
	::continue::
end


-- builder

local B = { }

function B.add(snippet, n)
	snippet.nodes = snippet.nodes or { }
	table.insert(snippet.nodes, n)
	return snippet
end

function B.choice(snippet, id, c)
	snippet.choices = snippet.choices or { }
	snippet.choices[id] = c
	return snippet
end

function B.default(snippet, id, v)
	snippet.defaults = snippet.defaults or { }
	snippet.defaults[id] = v
	return snippet
end

function B.match(snippet, m)
	snippet.matches = snippet.matches or { }
	table.insert(snippet.matches, m)
	return snippet
end

function B.transform(snippet, id, f)
	snippet.transforms = snippet.transforms or { }
	snippet.transforms[id] = f
	return snippet
end

function B.static(x)
	return { kind = 'static', value = x }
end

function B.user(id, default, transform)
	return { kind = 'user', id = id, default = default, transform = transform }
end

local function _add_static(snippet, x)
	return snippet:add(B.static(x))
end

local function _add_user(snippet, id, default, transform)
	return snippet:add(B.user(id, default, transform))
end

local function _ok(snippet)
	return {
		nodes      = common.merge(snippet.nodes),
		choices    = common.merge(snippet.choices),
		defaults   = common.merge(snippet.defaults),
		matches    = common.merge(snippet.matches),
		transforms = common.merge(snippet.transforms)
	}
end

function B.new()
	return {
		add       = B.add,
		choice    = B.choice,
		default   = B.default,
		match     = B.match,
		transform = B.transform,
		static    = _add_static,
		user      = _add_user,
		ok        = _ok,
		a = B.add,
		c = B.choice,
		d = B.default,
		m = B.match,
		t = B.transform,
		u = _add_user,
		s = _add_static
	}
end

M.builder = B


return M
