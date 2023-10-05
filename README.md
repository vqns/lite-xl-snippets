snippets plugin for [lite-xl]


### Installation

Place the following files in the editor's `plugins` directory (e.g
`~/.config/lite-xl/plugins`, not `~/.config/lite-xl/plugins/lite-xl-snippets`):

*  `snippets.lua`: the base plugin which includes features such as snippet
    expansion, tabbing through tabstops, etc.
*  `lsp_snippets.lua`: requires the base plugin; adds support for [lsp] / [vscode]
   style snippets.
*   `json.lua`: rxi's [json] library, required to load LSP snippets from json
    files. `lsp_snippets` will attempt to load it from [lint+] or the [lsp plugin]
    if they're in the plugin path, so it is only needed if neither can be found.


### Usage

#### Adding snippets

Snippets may be added through lua configuration:

```lua
local snippets = require 'plugins.snippets'
snippets.add {
    trigger  = 'fori',
    files    = '%.lua$',
    info     = 'ipairs',             -- optional, used by the autocomplete menu
    desc     = 'array iterator',     -- optional, used by the autocomplete menu
    format   = 'lsp',                -- 'lsp' must be lowercase
    template = [[
for ${1:i}, ${2:v} in ipairs($3) do
    $0
end
]]
}
```

-  `trigger`: if present, adds the snippet to autocompletion suggestions.
-  `files`: optional filter used by the autocomplete plugin, in the form of a
   [lua pattern] to be checked against filenames.
-  `info`: the name on the right of the trigger in the autocompletion menu.
-  `desc`: the description popup next to the autocompletion menu. Defaults to
   the template.
-  `format`: the format of the template. If none, the template is inserted as
   plain text.
-  `template`: the body of the snippet. The format supported by the `lsp_snippets`
   plugin is the [lsp] / [vscode] subset of [textmate] snippets.

Other possible and optional fields: `nodes`, `defaults`, `transforms`, `choices`,
`matches`, `p_args`. See [docs.md](docs.md) for details.

For snippets to be automatically loaded on startup, they should be placed
somewhere the editor will load them by itself. The easiest way to do that is
the user module (`init.lua`); another is to create a new plugin which contains
the snippets, which has the advantage of not cluttering the config file. E.g,
in `plugins/my_snippets.lua` or `plugins/my_snippets/init.lua`:

```lua
-- modversion:3
local snippets = require 'plugins.snippets'

snippets.add { ... }
snippets.add { ... }
```

A last option, if the snippets are placed at a location that the editor does not
automatically load, is to load them manually using `dofile`. E.g in `init.lua`:

```lua
dofile '/path/to/my_snippets.lua'
```

An alternative to lua configuration is to use json files, which is done by
adding paths to the `lsp_snippets` plugin:

```lua
local lsp_snippets = require 'plugins.lsp_snippets'
lsp_snippets.add_paths {
    'snippets',                   -- relative paths are prefixed with the userdir
    '/path/to/snippets/folder',
    '/specific/snippet/file.json'
}
```

The `add_paths` function takes as argument either a single path or an array of
paths and loads them according to the following rules:

*  files with a name of the form `langname.json` (see [notes](#Notes)).
*  files with the `.code-snippets` extension.
*  folders:
   -  subfiles with a valid name;
   -  subfolders with a language name: every subfile with the `.json` extension
      is added.

For details on these json files, refer to the [vscode spec] (project scope is not
supported). Existing snippets may be found at [rafamadriz/friendly-snippets] or
in [vscode extensions] (e.g most extensions which add support for a given language
will contain snippets).

For example, adding [rafamadriz/friendly-snippets]:

1. `git clone https://github.com/rafamadriz/friendly-snippets.git` in the userdir
2. add `lsp_snippets.add_paths 'friendly-snippets/snippets'` to `init.lua`

#### Using snippets

A snippet may be expanded either with the autocomplete suggestions or manually:

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

This will expand the given snippet at each cursor in the current document.

Once expanded, a snippet may be navigated through using these commands:

`snippets:next`:
    sets selections for the next tabstop. (wraps around to 1)

`snippets:previous` (`shift+tab`):
    sets selections for the previous tabstop. (wraps around to the last tabstop)

`snippets:select-current`:
    selects the values of the current tabstop.

`snippets:exit` (`escape`):
    sets selections for either the end tabstop (e.g `$0`) or after the snippet.

`snippets:exit-all`:
    exits all snippets, as opposed to only the innermost level.

`snippets:next-or-exit` (`tab`):
    if the current tabstop is the last one, exits; otherwise, next.

#### Configuration

`config.plugins.snippets`:

* `autoexit` (`true`): automatically exits all snippets when modifying the doc
    out of a tabstop.


### Advanced

See [docs.md](docs.md).


### Notes

*  Valid language names for json files are defined in the `extensions` table in
   `lsp_snippets.lua`. Snippets added through these names will be active for the
   list of extensions they're mapped to. Adding a new language or editing the
   extensions for a certain language can be done simply by requiring `lsp_snippets`
   and modifying its `extensions` field:

   ```lua
   local lsp_snippets = require 'plugins.lsp_snippets'

   -- no dot for the extensions, e.g `lua`, not `.lua`
   -- both the name and the extensions must be lowercase
   lsp_snippets.extensions['lang'] = { 'ext1', 'ext2' }
   ```



[lite-xl]:     https://github.com/lite-xl
[json]:        https://github.com/rxi/json.lua
[lsp]:         https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#snippet_syntax
[vscode]:      https://code.visualstudio.com/docs/editor/userdefinedsnippets
[textmate]:    https://macromates.com/textmate/manual/snippets
[vscode spec]: https://code.visualstudio.com/docs/editor/userdefinedsnippets#_create-your-own-snippets
[rafamadriz/friendly-snippets]: https://github.com/rafamadriz/friendly-snippets
[vscode extensions]: https://marketplace.visualstudio.com/VSCode
[lint+]:       https://github.com/liquidev/lintplus
[lsp plugin]:  https://github.com/lite-xl/lite-xl-lsp
[lua pattern]: https://www.lua.org/manual/5.4/manual.html#6.4.1
