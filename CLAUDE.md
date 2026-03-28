# hist-complete

Entropy-ranked, history-aware zsh completion plugin.

## Status

Prototype — extracted from dotfiles after prototyping with fzf-tab. Next step: replace fzf-tab with direct fzf invocation for full control over `reload`, candidate format, and query preservation.

## Architecture

See README.md for the information theory (trie entropy, frecency, LCP, stratified sampling).

### Key components

- **Completer** (`_complete_with_history`): zsh completion function with awk pipeline
- **PTY wrapper** (`fzf-key-translate`): translates Shift+Enter to Ctrl+O for fzf (Python, uses `forkpty()` — required on macOS)
- **Context-aware trie walk**: uses LBUFFER for full context; separators (`&&`, `|`, `;`) are trie nodes

### Why replace fzf-tab

1. Can't use fzf `reload` — fzf-tab's candidate format is opaque
2. Abort+reopen loses the fzf query
3. fzf-tab's internal widgets trigger `autosuggest-accept`, bleeding into buffer

## Target key bindings

| Key | On command line | Inside fzf |
|-----|----------------|------------|
| Tab | Open completion | Toggle history↔PATH (reload) |
| Shift+Tab | Open completion (inverted) | — |
| Enter | — | Accept first word |
| Shift+Enter | Accept autosuggestion | Accept full command line |
| Escape | — | Dismiss |

## Configuration

```zsh
COMP_HISTORY_WEIGHT=0.7   # 0.0 = explore (PATH), 1.0 = exploit (history)
COMP_TOTAL_RESULTS=20     # total slots in popup
```

## Testing

Done through chezmoi dotfiles. See `CLAUDE.local.md` for instructions.

## Conventions

- macOS PTY: must use `forkpty()` — Go's `SysProcAttr.Ctty` does NOT work on Darwin
- PATH commands only shown when prefix >= 1 char (performance guard)
