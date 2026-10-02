# Copilot instructions for `nvim-flow`

## Project purpose

`nvim-flow` is a Neovim workflow runner for file-scoped YAML commands and cursor-local shell blocks in Markdown.
It resolves commands from `.flow.yml` or a fenced shell block and runs them in a Neovim terminal (or debug runner).

## Core architecture

- `lua/nvim-flow/init.lua`
  - public API and `setup(opts)`
  - command entrypoints (`run`, `run_here`, `debug`, `preview`, `quickfix`, `toggle_lock`)
  - keymap registration
- `lua/nvim-flow/config.lua`
  - config file discovery and merge
  - match resolution and command normalization
  - cursor-based resolution for run-from-`.flow.yml` (`find_key_at_line`, `resolve_at`)
- `lua/nvim-flow/markdown.lua`
  - Tree-sitter Markdown fenced-block selection and shell command extraction
  - Markdown context/template resolution for cursor-based execution
- `lua/nvim-flow/yaml.lua`
  - lightweight YAML parser used by the plugin (no Python dependency)
  - stores map insertion order in `__order` for deterministic match behavior
- `lua/nvim-flow/path.lua`
  - shared path/context helpers (`normalize`, `build_context`, repo detection)
- `lua/nvim-flow/runner.lua`
  - terminal split execution, script creation, output capture
  - split position controlled by `terminal_position` (`top` default, `bottom` optional)
  - flow terminal buffers are tagged with `b:nvim_flow_terminal = 1` for reliable external cleanup integrations
- `lua/nvim-flow/debug_runner.lua`
  - built-in flow command parser + nvim-dap launch config assembly
  - recognizes `python`/`python3`, `uv`, and node commands for automatic DAP config generation
  - for unrecognized commands (e.g. `dotnet run`), falls through to `dap.continue()` so existing user-configured `dap.configurations` are used
- `lua/nvim-flow/preview.lua`
  - floating command preview window
- `lua/nvim-flow/quickfix.lua`
  - Python traceback parser -> quickfix list
- `plugin/nvim-flow.lua`
  - user command registration (`FlowRun`, `FlowRunHere`, `FlowDebug`, `FlowEdit`, etc.)

## Config behavior (important)

- Config file name defaults to `.flow.yml` (configurable).
- Discovery walks from current file's directory upward to `$HOME` (if `stop_at_home = true`).
- All found files are merged.
- Closer files take precedence over farther files.
- `FlowEdit` uses resolved `source_key` + nearest defining config file to jump to the matched `.flow.yml` line.
- Matching priority:
  1. basename
  2. `match:` entries
  3. folder name
  4. repo name
  5. extension (`.py`, then `py`)
  6. `default`
- `match` is optional.
  - If omitted, legacy key-based matching is used.
  - If present, should be string or array.

## Run from `.flow.yml` (`run_here` / `resolve_at`)

- `init.run_here` runs the entry under the cursor in a `.flow.yml` buffer, or a supported shell fence under the cursor in a Markdown buffer.
- The single `run` keymap is context-aware: it runs the cursor entry/block inside a `.flow.yml` or Markdown buffer and runs the file-resolved flow elsewhere.
- `config.find_key_at_line(lines, lnum)` maps a cursor line to the enclosing top-level entry key (inverse of `find_top_level_key_line`).
- `config.resolve_at(flow_file, key, opts, text)` resolves a `cmd_def` for a single entry, bypassing match resolution. Optional `text` (live buffer content) is honored over the file on disk.
- `markdown.resolve_at(filepath, lines, lnum)` resolves a `sh`, `bash`, or `shell` fence from live Markdown lines, including fences inside lists and blockquotes.
- File-scoped vars (`{{filepath}}`, `{{filename}}`, `{{ext}}`) resolve lazily: locked file first, else glob the entry's path-like `match`/key under the repo root and require exactly one file, else abort. Entries with no file-scoped vars run with the `.flow.yml`'s own dir/repo/folder context.
- For Markdown blocks, project vars derive from the Markdown file; file-scoped vars require a lock and derive the full context from the locked target. No Markdown heading/glob target inference is performed.
- `FlowRun` and `FlowEdit` remain YAML-resolved, including when the current file is Markdown. `FlowPreview` and `FlowDebug` resolve the current Markdown shell fence.
- Markdown execution requires the Tree-sitter `markdown` parser on runtimepath, but YAML execution does not require Tree-sitter. The plugin uses Neovim's built-in parser API, not `nvim-treesitter`.
- Coverage: `resolve_at`/`find_key_at_line` in `tests/nvim-flow/config_spec.lua`; Markdown extraction in `tests/nvim-flow/markdown_spec.lua`; cursor command glue in `tests/nvim-flow/init_spec.lua`.

## Run from Markdown

- Markdown buffers are identified by the `markdown` filetype or `.md`/`.markdown` filename. The exact configured flow filename takes precedence.
- A cursor on any line of a closed `sh`, `bash`, or `shell` fence (including its delimiters) selects that block. Language labels are case-insensitive; extra info-string text does not configure execution.
- Tree-sitter identifies fenced blocks and container prefixes. Preserve shell contents and strip only parser-identified list/blockquote prefixes plus opening-fence indentation.
- Reject unsupported or unlabeled blocks, prose cursor positions, empty bodies, and incomplete fences. Never fall back to YAML when a Markdown cursor action cannot resolve a block.
- `FlowRunHere` and the `run` keymap use Bash by default, with an explicit first-line shebang override. Normal execution uses the configured output split and inherits Neovim's working directory; `FlowDebug` uses the debugger's execution context. Opening a document does not execute commands.
- Keep Markdown actions cursor-local; do not add task registries, whole-document execution, inline result insertion, or automatic execution without updating the feature scope and tests.

## Deterministic matching notes

- `yaml.lua` tracks key order in `__order`.
- `config.lua` uses that order when evaluating `match` entries.
- For merged files, closer file keys are promoted ahead of farther keys to keep "closer wins" deterministic.
- Parser edge-case coverage lives in `tests/nvim-flow/yaml_spec.lua`; resolution/merge behavior lives in `tests/nvim-flow/config_spec.lua`.

## Template variables

Supported command templates:

- `{{filepath}}`
- `{{dir}}`
- `{{filename}}`
- `{{ext}}`
- `{{repo}}`
- `{{folder}}`

## Runners and scope

- Supported runners:
  - terminal (`vim`/`terminal`/default)
  - debug (`debug`)
- Intentionally not supported in this project:
  - tmux runner
  - remote runners

Do not reintroduce deprecated runners without updating README, setup docs, and tests.

## Output formatting expectations

- When `show_command = true`, command text is printed followed by a separator line.
- Separator width is dynamic: command width, capped by terminal width (`tput cols` fallback).

## Testing and validation workflow

From repo root:

1. Syntax-check Lua modules:

```bash
find lua plugin tests -name '*.lua' -print | while read -r f; do lua -e "assert(loadfile('$f'))"; done
```

2. Run test suite:

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/nvim-flow { minimal_init = 'tests/minimal_init.lua' }" \
  -c "qa"
```

Markdown tests use a Tree-sitter `markdown` parser. CI builds `tree-sitter-markdown` v0.3.2 and sets `MARKDOWN_PARSER_PATH` to a runtime root containing `parser/markdown.so`; local development can install the parser with `nvim-treesitter`.

3. Optional real-world config parse check (for local environment):

```bash
nvim --headless -u tests/minimal_init.lua -c "lua local y=require('nvim-flow.yaml'); local files=vim.fn.glob('/home/mike/git/**/.flow.yml', false, true); table.insert(files, '/home/mike/.flow.yml'); for _,f in ipairs(files) do assert(y.decode_file(f), f) end" -c "qa"
```

## Editing guidelines for contributors/LLMs

- Keep changes minimal and behavior-safe.
- Preserve backward compatibility for existing `.flow.yml` unless explicitly changing spec.
- Prefer extending tests before/with behavior changes.
- If adding new config semantics, document them in README and this file.
- Avoid adding heavy dependencies unless clearly necessary.

## Known parser boundaries

`yaml.lua` is intentionally lightweight and supports the project's real configs (maps, scalars, inline lists, block-style commands).
If advanced YAML features are required (anchors/tags/complex collections), add tests first and then decide whether to extend parser or swap parser implementation.

The upstream Tree-sitter Markdown grammar can have parsing inaccuracies. Validate exact extracted command text, nested prefixes, and closing-fence behavior against the pinned parser used in CI; do not claim complete CommonMark correctness.
