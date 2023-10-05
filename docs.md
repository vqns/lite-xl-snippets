Advanced usage doc, please see the readme first


## Snippet creation

### Context

When a snippet is expanded, it is associated with a context (`ctx`):
*  `doc`: the doc in which it was expanded.
*  `cursor_idx`: the index of the cursor.
*  `at_line`: line index of the cursor when `snippets.execute` was called.
*  `at_col`: col index of the cursor when `snippets.execute` was called.
*  `line`: line index of where the snippet is inserted.
*  `col`: col index of where the snippet is inserted.
*  `partial`: the partial symbol (e.g the trigger) or `''`.
*  `selection`: the cursor's selection or `''`.
*  `matches`: tables of the matches. See [matches](#Matches)
*  `removed_from_matches`: text removed due to matches. See [matches](#Matches)
*  `indent_sz`, `indent_str`: the results of `doc:get_line_indent(l)` where `l`
   is the line where the snippet is inserted (`ctx.line`).
*  `extra`: an empty table which can be used to carry user defined state with
   the context.

`at_line`, `at_col` and `line`, `col` will have different values if a partial
or a selection is removed or if the snippet has successful matches. Also note
that `line` and `col` may not be the final position either.

If a snippet is expanded multiple times at once (e.g multiple cursors), it is
multiple independent snippets, each with their own context, which will be active
together at the same time (i.e their tabstops will be synchronized).

If any of the multiple snippets fails during resolution or expansion, the entire
group of snippets will be cancelled.

If this is the case, snippets are inserted in bottom-to-top order in regard to
the doc's selections, which is why `ctx.line` and `ctx.col` will not reflect
the actual position of the snippet.


### Nodes

Internally, a snippet is represented by an array of nodes and extras, such as
defaults, transforms, etc; i.e:

```lua
snippet = {
    nodes    = { node_1, node_2, ... },
    defaults = { ... },
    ...
}
```

There are two kinds of nodes: `static` and `user` nodes. Static nodes are
resolved once, when the snippet is first expanded; user nodes are nodes which
will be interactive, i.e tabstops.

The resulting snippet is the concatenation of the values of all its nodes; no
extra formatting is applied: there is no space, new line, tab, etc. inserted
between nodes, with the exception that each line is indented at the same level
as the line where the snippet was expanded (`ctx.indent_str`).

#### Static nodes

A static node is a table with the following schema:

```lua
{
    kind = 'static',
    value = ...
}
```

where `value` may be:
*  `nil`: the node is discarded;
*  a table, which is interpreted as an array of nodes and inserted in the snippet;
*  a function, which is called with the above context and whose result is resolved
   according to these rules;
*  anything else: `tostring()`.

The table wrapper is optional, and the value may be directly inserted into the
snippet's nodes.

This means that the following three arrays are equivalent:

```lua
-- simplest form
{
    'text',
    function(ctx) return ctx.line end,
    'text2text3'
}

-- the table at index 3 is inserted as is, and so is the 2nd function's return
{
    'text',
    function(ctx) return ctx.line end,
    {
        'text2',
        function() return 'text3' end
    }
}

-- same as above but with all the tables
{
    { kind = 'static', value = 'text' },
    { kind = 'static', value = function(ctx) return ctx.line end },
    { kind = 'static', value = {
        { kind = 'static', value = 'text2' },
        { kind = 'static', value = function() return 'text3' end }
    } }
}
```

One important limit: mutually recursive nodes / values (or any form of cycle)
are neither expected nor guarded against, so the results of resolving such a
snippet is undefined.

#### User nodes

A user node ('tabstop') has the following schema:
*  `kind`: `'user'`
*  `id`: positive integer key. Tabstops will be iterated through in ascending
   order, starting at 1. IDs do not need to be continuous; i.e `{ 2, 3, 6, 18 }`
   will still have all 4 ids iterated through. They also do not need to be
   unique: nodes with the same id will be tabbed into and out of together.
*  `default`: (optional) a default value for this node only. see [defaults](#defaults)
*  `transform`: (optional) a transform function for this node only. see [transforms](#transforms)
*  `main`: (optional) specifies whether this node should be the 'main value' for this id.

An id of 0 means an ending position, i.e where to put the cursor(s) when exiting
the snippet. If a snippet does not have a tabstop with an id of 0, the cursor
will be put at the first position after the snippet. It is however still a normal
node, which means it may have defaults and choices (transforms will be ignored).

### Defaults

Default values may be set for certain ids by adding a `defaults` fields to the
snippet:

```lua
snippet = {
    nodes    = { { kind = 'user', id = 3 } },
    defaults = { [3] = 'default value' }
}
```

These values are resolved through the same coercion rules as static nodes, which
means that a default value may be e.g a function or may include other nodes.

If a node has its own default, then it will use said default instead of the
snippet-wide one.


### Transforms

Transforms are functions which are applied to the string value of a tabstop and
return a string which will replace the old value. Transforms are applied for each
dirty (= modified) node with a certain id when tabbing out of said id. I.e if
double tabbing from #2 to #4, transforms for #3 will not be applied. This also
means that transforms are not applied to default values.

Transforms may be specified just like defaults: with a `transforms` field for
a transform that applies to all tabstops with this id; or in a specific node, in
which case only this function will be applied.

```lua
snippets.add {
    format     = 'lsp',
    template   = '$1 -> $2',
    transforms = {
        [1] = string.lower,
        [2] = function(str) return str:sub(2, -2) end
    }
}
```


### Choices

Choices allow specific given autocompletion suggestions when tabbing into a
certain id. Choices may be added with a `choices` field; its values are tables of
the suggestions to autocomplete items.

E.g simply adding plain text suggestions:

```lua
choices = {
    [2] = { ['suggestion 1'] = true, ['suggestion 2'] = true }
}
```

Or actual snippets (or any other autocomplete items):

```lua
-- snippets.add returns the autocomplete item for the snippet
local _, ac_item = snippets.add {
    trigger  = 'fori',
    format   = 'lsp',
    template = [[
for (int ${1:i} = 0; $1 < $2; ++$1) {
    $0
}]]
}

snippets.add {
    trigger  = 'fun',
    format   = 'lsp',
    choices  = { [0] = { fori = ac_item } },
    template = [[
void $1($2) {
    $0
}
]]
}
```

Upon tabbing into #0 in `fun`, the autocomplete popup will have the option to
expand `fori` and automatically jump into its #1 tabstop.


### Matches

Matches allow fetching (and optionally removing) text before the snippet's
trigger position. Just like defaults, transforms and choices, matches are added
with a new field in the snippet. However, unlike these, the field is used as an
array and not as a 'map'; i.e any key/value pair that is not iterated by `ipairs`
will be ignored, and the key value is not related in any way to user node ids.

A match is a table with the following fields:
*  `kind`: the type of pattern, defaults to `'lua'`.
   -  `'lua'`: [lua pattern](https://www.lua.org/manual/5.4/manual.html#6.4.1).
*  `pattern`: the pattern to match the text against. Defaults to
   `'([%w_]+)[^%S\n]*$'` if kind is `'lua'`.
*  `strict`: if true and the match fails, the snippet is cancelled.
*  `keep`: if true, the matched text is not removed from the doc.

If the match is just a string, then it is assumed to be a lua pattern.
Otherwise, if truthy, then it is the above default lua pattern.

Matches are resolved in the given order against the raw text of the document
after the partial or selection has been removed; i.e whitespace is not removed
(which is why `[^%S\n]*`).

The used text starts at the position of the previous cursor + 1 or at the start
of the document if the current snippet is at the first cursor and ends at the
position of the current cursor. For example, if `|` denotes a cursor, then, in
`text | more text |`, the used parts of the doc will be `' more text '`, then
`'text '` (since snippets are resolved in bottom to top order).

After a match is tested, the text used for the remaining matches will start at
the same position as the original text but will end at the beginning of the
matched text, even if `keep` checks true. Similarly, the whole match is removed
from the doc, not just the captures. E.g if the first match is `'(%d+)%D*$'`
(first digit word starting from the end), then the remaining text will be:
*  `'abc 123'`: matches and captures `'123'`, leaves `'abc '`
*  `'123 abc'`: matches `'123 abc'`, captures `'123'`, leaves `''`

If a match fails and `strict` checks true, then the snippet is cancelled (as
well as any other snippet that was activated at the same time). However, if
`strict` checks false, then the match is set to `''` and the remaining matches
are tested.

The match results will be in the `matches` field of the context, in the same
order as the given matches. If a match pattern has multiple captures, then the
result will be an array of these captures.

The text removed from successful matches will be in `ctx.removed_from_matches`;
matches which failed or did not cause removed text (e.g because `keep` was true)
will have a nil value.

Tldr: matches allow 'postfix' completion style:

```lua
snippets.add {
    trigger = 'sout',
    matches = { true }, -- defaults to '([%w_]+)[^%S\n]*$'
    nodes   = {
        'System.out.println(',
        function(ctx) return ctx.matches[1] end,
        ');\n'
    }
}
```

`myVar sout` -> `System.out.println(myVar);` and the cursor will be positioned
on the next line.


### Templates

When a snippet in template form is expanded, it is fed to the corresponding parser,
which returns nodes that will be resolved and used to expand the snippet. If the
added snippet had a `p_args` field, it is also passed to the parsing function.

Adding support for a template format is a matter of providing the snippets plugin
a template (+ args) -> snippet parser function:

```lua
local snippets = require 'plugins.snippets'

local function my_parser(template, args)
    return ...
end

snippets.parsers.my_format = my_parser

snippets.add {
    format   = 'my_format',
    template = '...'
}
```

Templates are parsed lazily (on first activation), so snippets in a certain
format may be added before the parser itself is set. Additionally, the result
of parsing a template is cached and will be reused for future expansions, so
it should not be modified after the parser function returns.

Functions such as `snippet.add` or `snippet.execute` accept snippets consisting
of a template and extras (defaults, transforms, etc), with said extras overriding
the results of the parser.

e.g in the following snippet, tabstop #1 will have an empty default value
(= no default value), and tabstop #2 will be inserted with `'second'` and will
be converted to lowercase if modified.

```lua
snippets.add {
    format     = 'lsp',
    template   = '${1:default} ${2/(.*)/${1:/upcase}/}',
    defaults   = { [1] = '', [2] = 'second' },
    transforms = { [2] = string.lower }
}
```


## API

### Base

*  `snippets.add(snippet)` -> `(id, ac | nil) | nil`: adds the given snippet.
   Valid fields for `snippet`: `trigger`, `files`, `info`, `desc`, `format`,
   `template`, `nodes`, `defaults`, `transforms`, `choices`, `matches`.
   Requires at least `template` or `nodes` to be valid (i.e not `nil`).
   If `snippet` is valid, an `id` is returned, which can then be passed to
   `snippets.execute` or `snippets.remove`. If `trigger` is not `nil` and the
   autocomplete plugin is enabled, then this also returns an autocompletion
   item (`ac`).
*  `snippets.execute(snippet, doc, partial)` -> `true | nil`: executes the given
   snippet. Returns `true` in case of success, `nil` otherwise.
   -  `snippet` may be either an id returned from `snippets.add` or a snippet
      as would be given to `snippets.add`.
   -  `doc`: the doc in which to expands. Defaults to the current doc.
   -  `partial`: whether to remove the 'partial' symbol under the caret.
*  `snippets.remove(id)`: removes the snippet with the given id.
*  `snippets.parsers`: table which contains the template parsers. See 
   [templates](#Templates).


### Control

The function `snippets.in_snippet(doc)` returns a table which contains the active
snippets in the current doc or the given one. If there is no current doc or it
does not have active snippets, this returns `nil`. This table must not be modified;
it can however be used to call the following functions:
    
*  `snippets.select_current(snippets)`: selects the values of the current tabstop
*  `snippets.next(snippets)`: sets selections for the next tabstop
*  `snippets.previous(snippets)`: sets selections for the previous tabstop
*  `snippets.exit(snippets)`: exits the snippets
*  `snippets.exit_all(snippets)`: recursively exits snippets and its parents
*  `snippets.next_or_exit(snippets)`: if on the last tabstop, exits; otherwise,
    sets the next tabstop

Cycling through tabstops wraps around as `max -> 1` for `next` and `1 -> max` for
`previous`; where max is the 'last' tabstop, i.e the tabstop with the highest id.

Changing the tabstop will trigger transforms for the previous id; this means that
`select_current` will not do so, as the tabstop does not change. Similarly,
exiting will not trigger transforms for nodes with an id of 0.

Exiting has the following behavior:
*  if the snippets were nested, then selections are set as if calling `next_or_exit`
   with the parent snippets.
*  else, if at least one snippet has a tastop with an id of 0, then selections
   are set only for nodes with an id of 0. I.e no cursor for snippets without
   a final tabstop.
*  otherwise, a single cursor is placed at the end of each snippet.

Internally, exiting a snippet also removes it from the active snippets and stops
tracking its changes. This means that it is not possible to tab back into a
nested snippet once it is exited.


### Builder

For convenience, a builder api is included in `snippets.lua`:

```lua
local B = (require 'plugins.snippets').builder
local snippet = B.new():s('local '):u(1):s(' = '):u(2):s('\n'):ok()
snippet.trigger = 'loc'
snippet.files = '%.lua$'
snippets.add(snippet)
```

This adds a snippet equivalent to the LSP template `'local $1 = $2\n'`.

API, where `B` is `snippets.builder` and `snippet` is a snippet as returned from
any of these functions, except `B.static`, `B.user` and `ok`:

*  `B.new()` -> `snippet`: returns a new empty snippet
*  `B.static(value)` -> `node`: returns a static node
*  `B.user(id, default, transform)` -> `node`: returns a user node
*  `B.add(snippet, node)` -> `snippet`: adds a node to `snippet`
   -  `snippet:add(node)`
   -  `snippet:a(node)`
*  `B.choice(snippet, id, item)` -> `snippet`: sets choice items for `id`
   -  `snippet:choice(id, item)`
   -  `snippet:c(id, item)`
*  `B.default(snippet, id, value)` -> `snippet`: sets the default value for `id`
   -  `snippet:default(id, value)`
   -  `snippet:d(id, value)`
*  `B.match(m)` -> `snippet`: adds a match to `snippet`
   -  `snippet:match(m)`
   -  `snippet:m(m)`
*  `B.transform(snippet, id, fn)` -> `snippet`: sets the transform for `id`
   -  `snippet:transform(id, fn)`
   -  `snippet:t(id, fn)`
*  `snippet:static(value)` -> `snippet`: adds a static node to `snippet`
   -  `snippet:s(value)`
*  `snippet:user(id, default, transform)` -> `snippet`: adds a user node to `snippet`
   -  `snippet:u(id, default, transform)`
*  `snippet:ok()` -> `snippet`: finalizes the snippet.

Please note that these builders are mutable; use `ok()` to get an independent
snippet. This is a first level copy, i.e values used for the nodes, defaults, etc
are only shallow copies and will reflect changes.


### `lsp_snippets`

*  `lsp_snippets.parse(template)` -> `snippet`: parses the given template and
   return a snippet which can be passed to `snippets.add` or `snippet.execute`.
*  `lsp_snippets.add_paths(paths)`: loads snippets from json files.
*  `lsp_snippets.extensions`: table of language names to language extensions,
   used for the json files.
