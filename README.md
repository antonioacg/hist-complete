# hist-complete

An entropy-ranked, history-aware zsh completion engine. Replaces the default
first-word completion with a unified pipeline that blends shell history and
PATH commands using information-theoretic scoring.

## How it works

When you press **Tab** on the first word of a command line, hist-complete runs
a single `awk` pipeline that:

1. Builds a **word-level trie** from recent history
2. Scores each history command using **trie self-information**
3. Selects a diverse subset via **stratified sampling** across the entropy
   spectrum
4. Ranks the selection by **frecency** (frequency × recency)
5. Scores remaining PATH commands by **LCP proximity** to your history
6. Outputs a unified, ordered list

For mid-command positions (arguments, flags), it merges standard zsh
completions with history words from the same argument position in entries that
share the same command.

## The science

### Self-information (surprisal)

Given a history of *N* matching entries, a command *c* appearing *f* times
carries self-information:

```
I(c) = log₂(N / f)
```

High frequency → low surprise (you use `git` constantly).
Low frequency → high surprise (that one-off `claudish --top-models`).

### Word-level trie

Flat frequency treats `clr` and `clr <uuid>` the same. The trie captures
the full command structure by tracking prefix frequencies at each word level
(up to depth 4):

```
I(line) = Σᵢ log₂(parent_count(i) / prefix_count(i))
```

This means `clr <unique-uuid>` scores higher than `clr <common-uuid>` — the
second word carries additional surprise. A command like `clear && ./remote-exec.sh ...`
that's always identical scores low because every trie level is predictable.

### Stratified sampling

Instead of showing the *N* most recent commands (which might all be `clr`),
we sort unique commands by their trie entropy and pick evenly-spaced entries
across the spectrum. This guarantees **diversity**: you see your workhorse
commands *and* your rare one-offs.

### Frecency

Within the selected entries, ordering uses frecency — a product of frequency
and normalized recency:

```
frecency(c) = count(c) × (latest_nr(c) / max_nr)
```

Commands you use **often and recently** rank highest. Stop using a command
and its recency decays; it drops in the ranking without disappearing. This is
inherently adaptive — history *is* the state.

### LCP proximity (PATH commands)

Commands from PATH, aliases, builtins, and functions that don't appear in
history are scored by **Longest Common Prefix** with the closest history
command. This ranks PATH commands by proximity to your usage patterns:

- `claude-limitline` shares 6 chars with `claude` → high score
- `clusterdb` shares 2 chars with `clr` → low score

PATH commands near your most-used tools bubble up; obscure ones sink.

### Dynamic slot allocation

The ratio of history vs PATH slots adapts to prefix specificity:

```
effective_weight = base_weight + (1 - base_weight) × len / (len + 4)
```

| Prefix length | Effective weight (base=0.7) | History | PATH |
|:---:|:---:|:---:|:---:|
| 0 | 0.70 | 14 | 6 |
| 1 | 0.76 | 15 | 5 |
| 2 | 0.80 | 16 | 4 |
| 3 | 0.83 | 17 | 3 |
| 4 | 0.85 | 17 | 3 |

Short prefix → exploring, more PATH for discovery.
Long prefix → you know what you want, lean into history.
Asymptotic curve, never overshoots 1.0.

### Why not feed PATH into the trie?

PATH commands have zero history. Assigning them a pseudo-count (Laplace
smoothing) makes them all **maximally surprising** — they flood the
high-entropy end of the spectrum and waste slots on commands you've never
used. The entropy model needs real frequency data. PATH is better served as a
separate source, scored by proximity rather than surprisal.

## Key bindings

### From the command line

| Key | Action |
|-----|--------|
| **Tab** | Open completion (history-heavy) |
| **Shift+Tab** | Open completion (PATH-heavy, inverted ratio) |

### Inside the fzf popup

| Key | Action |
|-----|--------|
| **Enter** | Accept first word only |
| **Shift+Enter** | Accept full command line |
| **Tab** | Toggle history↔PATH ratio (auto-reopens) |
| **Escape** | Dismiss |

**Shift+Enter** works via a PTY wrapper (`fzf-key-translate`) that translates
the CSI u sequence (`\e[13;2u`) to Ctrl+O before fzf sees it. This is
transparent to the user — no terminal configuration needed.

**Tab+Tab** cycles between history-heavy and PATH-heavy views. The effective
weight becomes `1 - effective_weight`, flipping from exploit to explore (or
back). The widget auto-reopens instantly — no extra keypress needed.

## Configuration

Set these in `.zshrc` (or `.zshrc.local`) before sourcing the plugin:

```zsh
COMP_HISTORY_WEIGHT=0.7   # 0.0 = explore (all PATH), 1.0 = exploit (all history)
COMP_TOTAL_RESULTS=20     # total slots in the completion popup
```

## Dependencies

- **fzf** — fuzzy finder
- **fzf-tab** (`Aloxaf/fzf-tab`) — wraps zsh completion with fzf
- **compinit** — must be initialized before this plugin loads
- **awk** — POSIX awk (gawk, mawk, or macOS awk all work)
- **python3** — for the PTY key-translation wrapper (Shift+Enter support)

## Load order

```
compinit
  ↓
source hist-complete.plugin.zsh   ← registers the completer + zstyles
  ↓
zinit light Aloxaf/fzf-tab        ← wraps the completion system with fzf
zstyle ':fzf-tab:*' fzf-bindings 'tab:accept'
  ↓
source <(fzf --zsh)               ← provides fzf-history-widget for Shift+Tab
```
