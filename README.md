snippets plugin for [lite-xl](https://github.com/lite-xl)


### Installation

Copy the files into the editor's `plugins` directory.

*  `snippets.lua`: the base plugin which includes features such as snippet
    expansion, tabbing through tabstops, etc.
*  `lsp_snippets.lua`: requires the base plugin; adds support for
    [lsp](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#snippet_syntax)
    / [vscode](https://code.visualstudio.com/docs/editor/userdefinedsnippets) style snippets.
*   `json.lua`: [rxi's json library](https://github.com/rxi/json.lua), required to
    load LSP snippets from json files. `lsp_snippets` will attempt to load it from
    lint+ or the lsp plugin if they're in the plugin path, so it is only needed
    if neither can be found. See the [notes](#Notes) for details.


### Examples

Adding an LSP style snippet with a `fori` trigger for lua files:

```lua
local snippets = require 'plugins.snippets'
snippets.add {
    trigger  = 'fori',
    files    = '%.lua$',
    info     = 'ipairs',             -- optional, used by the autocomplete menu
    desc     = 'numerical for loop', -- optional, used by the autocomplete menu
    format   = 'lsp',                -- 'lsp' must be lowercase
    template = [[
for ${1:i}, ${2:v} in ipairs($3) do
    $0
end
]]
}
```

Adding LSP snippets from json files:

```lua
local lsp_snippets = require 'plugins.lsp_snippets'
lsp_snippets.add_paths {
    'snippets',                   -- relative paths are prefixed with the userdir
    '/path/to/snippets/folder',
    '/specific/snippet/file.json'
}
```

Executing a snippet in the current doc at each cursor:

```lua
local snippets = require 'plugins.snippets'
snippets.execute {
    format   = 'lsp',
    template = [[
local function $1($2)
    $0
end
]]
}
```


### Simple usage

#### Commands

`snippets:next` (`tab`):
    sets selections for the next tabstop. (wraps around to 1)

`snippets:previous` (`shift+tab`):
    sets selections for the previous tabstop. (wraps around to the last tabstop)

`snippets:select-current`:
    selects the values of the current tabstop.

`snippets:exit` (`escape`):
    sets selections for either the end tabstop (e.g `$0`) or after the snippet.

`snippets:next-or-exit`:
    if the current tabstop is the last one, exits; otherwise, next.


#### API

`snippets.add(snippet)` -> `(id, ac | nil) | nil`
*   `snippet`: the snippet to add. Schema:
    -   `template`: the snippet template (e.g `'$1 some text ${2:and more text}'`)
    -   `format`: the format of the template (e.g `lsp`).
        If unspecified, the template is directly inserted as plain text.
    -   `trigger`: if the autocomplete plugin is enabled, the given snippet will
        be added as a completion item with this trigger.
    -   `files`: Pattern to be matched against a filename to determine whether the
        autocompletion should be enabled, e.g `'%.lua$'` for lua files.
    -   `info`: (optional) the name on the right of the trigger in the autocompletion menu.
    -   `desc`: (optional) the description that shows up in the autocompletion menu;
        defaults to the template, if any.
    -   `nodes`, `defaults`, `transforms`, `choices`, `matches`: (optional)
        it is also possible to directly use nodes, which are the internal
        representation of a snippet. If the given snippet contains neither a template
        nor nodes, this function is a no op and returns `nil`. See [docs.md](docs.md)
        for details.

*   `id`: this function returns an id which can be reused to execute this exact
    snippet. If the snippet is parsed from a template, it will be parsed only
    once if executed with this id.
*   `ac`: if the snippet was added as an autocompletion item, this function also
    returns said item.

`snippets.execute(snippet, doc, partial)` -> `true | nil`
*   `snippet`: the snippet to expand; it will be inserted at each cursor in `doc`.
    This is either an id returned from `snippets.add` or a snippet as would be
    given to `snippets.add`.
*   `doc`: the doc in which to expand the snippet; if nil, the current doc is used.
*   `partial`: if truthy, remove the 'partial symbol', e.g the current selection or
    the trigger if expanded from an autocompletion.

*   this function returns `true` if it successfully completed; `nil` otherwise.

`lsp_snippets.add_paths(paths)`
*   `paths`: a single path or an array of paths.
    -   if a path is a relative path, then it is prefixed with the userdir, e.g
        `snippets` -> `~/.config/lite-xl/snippets` if the userdir is `~/.config`.
    -   if it is a file, then it is added only if it has a valid file name in the
        form of `languagename.json` (case is ignored) or ends with `.code-snippets`.
    -   if it is a folder, then:
        *   all files with a valid name are added;
        *   subfolders with a language name have all their json files added,
            regardless of their name (e.g `python/main.json`). This is not recursive,
            e.g `python/python/main.json` will not work.


### Advanced

See [docs.md](docs.md)


### Notes

*   Adding snippets from json files requires the files to have a name that is a
    'valid' language name or to have the `.code-snippets` extension. See the
    [vscode spec](https://code.visualstudio.com/docs/editor/userdefinedsnippets#_snippet-scope)
    (project scope is not supported). These language names are defined in the
    `extensions` table in `lsp_snippets.lua`. Snippets added through these names
    will be active for the list of extensions they're mapped to. Adding a new
    language or editing the extensions for a certain language can be done simply
    by requiring `lsp_snippets` and modifying its `extensions` field:

    ```lua
    local lsp_snippets = require 'plugins.lsp_snippets'

    -- no dot for the extensions, e.g `lua`, not `.lua`
    -- both the name and the extensions must be lowercase
    lsp_snippets.extensions['lang'] = { 'ext1', 'ext2' }
    ```

    Snippet files may be found at
    [rafamadriz/friendly-snippets](https://github.com/rafamadriz/friendly-snippets)
    or in [vscode extensions](https://marketplace.visualstudio.com/VSCode).
