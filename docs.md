Advanced usage doc


### Context

When a snippet is expanded, it is associated with a context (`ctx`):
*   `doc`: the doc in which it was expanded.
*   `cursor_idx`: the index of the cursor.
*   `at_line`: line index of the cursor when `snippets.execute` was called.
*   `at_col`: col index of the cursor when `snippets.execute` was called.
*   `line`: line index of where the snippet is inserted.
*   `col`: col index of where the snippet is inserted.
*   `partial`: the partial symbol (e.g the trigger) or `''`.
*   `selection`: the cursor's selection or `''`.
*   `matches`: tables of the matches. See [matches](#Matches)
*   `removed_from_matches`: the text that was removed due to matches.
*   `indent_sz`, `indent_str`: the results of `doc:get_line_indent(l)` where `l` is
    the line where the snippet is inserted.

`at_line`, `at_col` and `line`, `col` will have different values if a partial
or a selection is removed or if the snippet has successful matches.

If a snippet is expanded multiple times at once (e.g multiple cursors), it is
multiple independent snippets, each with their own context, which will be active
together at the same time (i.e their tabstops will be synchronized).

If this is the case, snippets are inserted in bottom-to-top order in regard to
the doc's selections.


### Nodes

There are two kinds of nodes: `static` and `user` nodes. Static nodes are resolved
once, when the snippet is first expanded; user nodes are nodes which will be
interactive, i.e tabstops.

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
*   `nil`: the node is discarded;
*   a table, which is interpreted as an array of nodes and inserted in the snippet;
*   a function, which is called with the above context and whose result is resolved
    according to these rules;
*   anything else: `tostring()`.

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
*   `kind`: `'user'`
*   `id`: positive integer key. Tabstops will be iterated through in ascending
    order, starting at 1. IDs do not need to be continuous; i.e `{ 2, 3, 6, 18 }`
    will still have all 4 ids iterated through. An id of 0 means an ending position,
    i.e where to put the cursor(s) when exiting the snippet. If a snippet does
    not have a tabstop with an id of 0, the cursor will be put at the first
    position after the snippet. It is however still a normal node, which means
    it may have defaults and choices (transforms will be ignored).
*   `default`: (optional) a default value for this node only. see [defaults](#defaults)
*   `transform`: (optional) a transform function for this node only. see [transforms](#transforms)
*   `main`: (optional) specifies whether this node should be the 'main value' for this id.


### Defaults

Default values may be set for certain ids by adding a `defaults` fields to the
snippet:

```lua
snippet = {
    nodes = { { kind = 'user', id = 3 } },
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
    format = 'lsp',
    template = '$1 -> $2',
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
    trigger = 'fori',
    format = 'lsp',
    template = [[
for (int ${1:i} = 0; $1 < $2; ++$1) {
    $0
}
]]
}

snippets.add {
    trigger = 'fun',
    format = 'lsp',
    choices = { [0] = { fori = ac_item } },
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

Matches allow fetching (and removing) text before the snippet's trigger position.
Just like defaults, transforms and choices, matches are added with a new field
in the snippet:

```lua
snippets.add {
    ...,
    matches = {
        [1] = ...,
        [2] = ...
    }
}
```

A match is a table with two fields:
*   `kind`: the type of pattern.
    *   `'lua'`: lua based pattern.
*   `pattern`: the pattern to match the text against.

If the given match is just a string, then it is assumed to be a lua pattern.
If it is neither a table nor a string, then it defaults to the lua pattern
`'(%w+)[^%S\n]*$'` which is the previous word (of alphanumerics characters) on
the same line.

There are a few important rules regarding matches resolution:
*   matches are resolved backwards from the end of the text. This means that, for
    any successful match, the text that the remaining matches will be tested against
    is the text before the match. e.g, assuming match #1 is the first numeric word
    (`'(%d+)%D*$'`) and match #2 is any word, then match #2 will be left with:
    -   `'abc 123'` -> `'abc '`
    -   `'123 abc'` -> `''`
*   an unsuccessful match does not cancel the snippet. Instead, it results in `''`
    (empty string) and then the other matches are tested and the snippet proceeds
    as normal.
*   matches happen after the partial / selection has been removed, but before the
    next snippet is resolved.
*   if a snippet with matches is expanded with multiple cursors, the text used for
    matches starts at the position of the previous cursor + 1.
    e.g, if `|n|` denotes cursor #n, then, in `'text |1| more text |2|'`, #2 will
    be matched against `' more text '`.
*   the results of the match are returned as is, i.e if a pattern has multiple
    captures, then the result will be a table of said captures.

The results of matches will be in the `matches` field of the context. This allows
'postfix' completion style:

```lua
snippets.add {
    trigger = 'sout',
    matches = { [1] = true },
    nodes = {
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
which returns nodes that will be resolved and used to expand the snippet. Adding
support for a template format is a matter of providing the snippets plugin a
template -> nodes parser function:

```lua
local snippets = require 'plugins.snippets'

local function my_parser(template)
    return ...
end

snippets.parsers.my_format = my_parser

snippets.add {
    format   = 'my_format',
    template = '...'
}
```

Templates are parsed lazily (on first activation), so snippets in a certain
format may be added before the parser itself is set.

Functions such as `snippet.add` or `snippet.execute` accept snippets consisting
of a template and extras (defaults, transforms, etc), with said extras overriding
the results of the parser.

e.g in the following snippet, tabstop #1 will have an empty default value
(= no default value), and tabstop #2 will be inserted with `'second'` and will
be converted to lowercase if modified.

```lua
snippets.add {
    format = 'lsp',
    template = '${1:default} ${2/(.*)/${1:/upcase}/}',
    defaults = { [1] = '', [2] = 'second' },
    transforms = { [2] = string.lower }
}
```


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

*   `B.new()` -> `snippet`: returns a new empty snippet
*   `B.static(value)` -> `node`: returns a static node
*   `B.user(id, default, transform)` -> `node`: returns a user node
*   `B.add(snippet, node)` -> `snippet`: adds a node to `snippet`
    -   `snippet:add(node)`
    -   `snippet:a(node)`
*   `B.choice(snippet, id, item)` -> `snippet`: adds a choice item for `id`
    -   `snippet:choice(id, item)`
    -   `snippet:c(id, item)`
*   `B.default(snippet, id, value)` -> `snippet`: sets the default value for `id`
    -   `snippet:default(id, value)`
    -   `snippet:d(id, value)`
*   `B.match(m)` -> `snippet`: adds a match to `snippet`
    -   `snippet:match(m)`
    -   `snippet:m(m)`
*   `B.transform(snippet, id, fn)` -> `snippet`: sets the transform for `id`
    -   `snippet:transform(id, fn)`
    -   `snippet:t(id, fn)`
*   `snippet:static(value)` -> `snippet`: adds a static node to `snippet`
    -   `snippet:s(value)`
*   `snippet:user(id, default, transform)` -> `snippet`: adds a user node to `snippet`
    -   `snippet:u(id, default, transform)`
*   `snippet:ok()` -> `snippet`: finalizes the snippet.


### Controlling snippets

The function `snippets.in_snippet(doc)` returns a table which contains the active
snippets in the current doc or the given one. If there is no current doc or it
does not have active snippets, this returns `nil`. This table must not be modified;
it can however be used to call the following functions:
    
*   `snippets.select_current(snippets)`: selects the values of the current tabstop
*   `snippets.next(snippets)`: sets selections for the next tabstop
*   `snippets.previous(snippets)`: sets selections for the previous tabstop
*   `snippets.exit(snippets)`: exits the snippets
*   `snippets.next_or_exit(snippets)`: if on the last tabstop, exits; otherwise,
    sets the next tabstop

Cycling through tabstops wraps around as `max -> 1` for `next` and `1 -> max` for
`previous`; where max is the 'last' tabstop, i.e the tabstop with the highest id.

Changing the tabstop will trigger transforms for the previous id; this means that
`select_current` will _not_ do so, as the tabstop does not change. Similarly,
exiting will not trigger transforms for nodes with an id of 0.

Exiting has the following behavior:
*   if the snippets were nested, then selections are set as if calling `next_or_exit`
    with the parent snippets.
*   else, if at least one snippet has a tastop with an id of 0, then selections
    are set only for nodes with an id of 0. I.e no cursor for snippets without
    a final tabstop.
*   otherwise, a single cursor is placed at the end of each snippet.

