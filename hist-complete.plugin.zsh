# hist-complete: entropy-ranked history-aware zsh completion
# Requires: fzf, fzf-tab (Aloxaf/fzf-tab), compinit already initialized
# Source AFTER compinit and BEFORE fzf-tab is loaded.

# Capture plugin directory at source time ($0 not available inside functions)
typeset -g _HC_DIR="${0:A:h}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

COMP_HISTORY_WEIGHT=${COMP_HISTORY_WEIGHT:-0.7}  # 0.0 = explore, 1.0 = exploit
COMP_TOTAL_RESULTS=${COMP_TOTAL_RESULTS:-20}      # total slots in popup

# ---------------------------------------------------------------------------
# Signal files (shared between ZLE widgets and fzf bindings)
# ---------------------------------------------------------------------------

typeset -g _HC_TOGGLE="/tmp/_hc_toggle_$$"
typeset -g _HC_FULLSIG="/tmp/_hc_fullline_$$"
typeset -g _HC_MAP="/tmp/_hc_map_$$"

trap 'rm -f "$_HC_TOGGLE" "$_HC_FULLSIG" "$_HC_MAP"' EXIT

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

typeset -gi _comp_inverted=0

# ---------------------------------------------------------------------------
# Completer (called by zsh completion system)
# ---------------------------------------------------------------------------

_complete_with_history() {
    local ret=1

    # Standard completions for mid-command (files, options, etc.)
    if (( CURRENT > 1 )); then
        _complete "$@" && ret=0
    fi

    {
        # Context-aware completion using LBUFFER for trie walk.
        # Three sources, merged:
        #   1. History matching full LBUFFER prefix (context-aware)
        #   2. History matching post-separator prefix (fresh start, if separator present)
        #   3. PATH commands (if prefix >= 1 char)
        local -a lbuf_words=(${(z)LBUFFER})
        local prefix=""
        local -a ctx_words=()

        if [[ -n "$LBUFFER" && "$LBUFFER" != *[[:space:]] ]]; then
            prefix="${lbuf_words[-1]}"
            (( $#lbuf_words > 1 )) && ctx_words=(${lbuf_words[1,-2]})
        else
            ctx_words=($lbuf_words)
        fi

        local ctx="${(j: :)ctx_words}"
        local -i ctx_count=$#ctx_words

        # Detect separator in context
        local -i has_sep=0
        local w
        for w in "${ctx_words[@]}"; do
            case "$w" in '&&'|'||'|';'|'&'|'|') has_sep=1; break ;; esac
        done

        # PATH only when there's a typed prefix
        local -a path_cmds
        if [[ -n "$prefix" ]]; then
            path_cmds=(
                ${(k)commands[(I)${prefix}*]}
                ${(k)aliases[(I)${prefix}*]}
                ${(k)functions[(I)${prefix}*]}
                ${(k)builtins[(I)${prefix}*]}
            )
            path_cmds=(${(u)path_cmds})
        fi

        local -a all_cmds all_display
        local IFS=$'\t'
        while read -r cmd display; do
            [[ -n "$cmd" ]] || continue
            all_cmds+=("$cmd")
            all_display+=("$display")
        done < <({
            fc -l -n -500
            printf '---\n'
            printf '%s\n' "${path_cmds[@]}"
        } | awk -v pfx="$prefix" \
              -v ctx="$ctx" \
              -v ctx_count="$ctx_count" \
              -v has_sep="$has_sep" \
              -v hw="$COMP_HISTORY_WEIGHT" \
              -v total="$COMP_TOTAL_RESULTS" \
              -v depth=4 \
              -v invert="$_comp_inverted" '
        function frecency_sort(arr, cnt_arr, nr_arr, n,    i, j, t, fi, fj) {
            for (i = 0; i < n; i++)
                for (j = i+1; j < n; j++) {
                    fi = cnt_arr[arr[i]] * (nr_arr[arr[i]] / max_nr)
                    fj = cnt_arr[arr[j]] * (nr_arr[arr[j]] / max_nr)
                    if (fj > fi) { t = arr[i]; arr[i] = arr[j]; arr[j] = t }
                }
        }
        BEGIN { if (ctx_count > 0) split(ctx, ctx_arr, " ") }
        /^---$/ { in_path = 1; next }
        !in_path {
            # Source 1: full context match
            ctx_ok = 1
            for (ci = 1; ci <= ctx_count; ci++)
                if ($ci != ctx_arr[ci]) { ctx_ok = 0; break }

            if (ctx_ok) {
                pos = ctx_count + 1
                if (NF >= pos) {
                    cmd = $pos
                    if (length(pfx) == 0 || substr(cmd, 1, length(pfx)) == pfx) {
                        count[cmd]++
                        latest_nr[cmd] = NR; latest_line[cmd] = $0
                        # Trie from cursor position
                        p = ""
                        d_max = NF - pos + 1
                        d = (d_max < depth) ? d_max : depth
                        for (i = pos; i < pos + d; i++) {
                            parent = p
                            p = (p == "") ? $i : (p SUBSEP $i)
                            trie[p]++; ptotal[parent]++
                        }
                    }
                }
            }

            # Source 2: fresh start after separator (first word of this line)
            if (has_sep) {
                fw = $1
                if (length(pfx) == 0 || substr(fw, 1, length(pfx)) == pfx) {
                    if (!(fw in count)) {
                        fresh_count[fw]++
                        fresh_nr[fw] = NR; fresh_line[fw] = $0
                    }
                }
            }
        }
        in_path {
            # Source 3: PATH (dedup against both context and fresh matches)
            if (!($1 in count) && !($1 in fresh_count))
                path_list[n_path++] = $1
        }
        END {
            # --- Slot allocation ---
            pl = length(pfx)
            for (ci = 1; ci <= ctx_count; ci++) pl += length(ctx_arr[ci]) + 1
            effective_hw = hw + (1 - hw) * (pl / (pl + 4))
            if (invert) effective_hw = 1 - effective_hw
            max_hist = int(effective_hw * total + 0.5)

            # Frecency normalization (across both sources)
            max_nr = 0
            for (c in count)
                if (latest_nr[c] > max_nr) max_nr = latest_nr[c]
            for (c in fresh_count)
                if (fresh_nr[c] > max_nr) max_nr = fresh_nr[c]
            if (max_nr == 0) max_nr = 1

            # --- Source 1: context-aware history (entropy + frecency) ---
            n = 0
            for (c in count) {
                line = latest_line[c]
                split(line, w)
                d_max = length(w) - ctx_count
                d = (d_max < depth) ? d_max : depth
                s = 0; p = ""
                for (i = ctx_count + 1; i <= ctx_count + d; i++) {
                    parent = p
                    p = (p == "") ? w[i] : (p SUBSEP w[i])
                    if (ptotal[parent] > 0 && trie[p] > 0)
                        s += log(ptotal[parent] / trie[p]) / log(2)
                }
                info[c] = s; cmds[n++] = c
            }

            hist_out = 0
            if (n > 0) {
                if (n <= max_hist) {
                    frecency_sort(cmds, count, latest_nr, n)
                    for (i = 0; i < n; i++) {
                        printf "%s\t%s\n", cmds[i], latest_line[cmds[i]]
                        hist_out++
                    }
                } else {
                    for (i = 0; i < n; i++)
                        for (j = i+1; j < n; j++)
                            if (info[cmds[j]] < info[cmds[i]]) {
                                t = cmds[i]; cmds[i] = cmds[j]; cmds[j] = t
                            }
                    for (i = 0; i < max_hist; i++)
                        picked[i] = cmds[int(i * n / max_hist)]
                    frecency_sort(picked, count, latest_nr, max_hist)
                    for (i = 0; i < max_hist; i++) {
                        printf "%s\t%s\n", picked[i], latest_line[picked[i]]
                        hist_out++
                    }
                }
            }

            # --- Source 2: fresh-start history after separator ---
            if (has_sep) {
                nf = 0
                for (c in fresh_count) fresh_cmds[nf++] = c
                if (nf > 0) {
                    frecency_sort(fresh_cmds, fresh_count, fresh_nr, nf)
                    fresh_slots = max_hist - hist_out
                    if (fresh_slots > nf) fresh_slots = nf
                    for (i = 0; i < fresh_slots; i++) {
                        printf "%s\t%s\n", fresh_cmds[i], fresh_line[fresh_cmds[i]]
                        hist_out++
                    }
                }
            }

            # --- Source 3: PATH (LCP proximity) ---
            max_path = total - hist_out
            for (i = 0; i < n_path; i++) {
                p = path_list[i]; best = 0
                for (c in count) {
                    lcp = 0
                    lp = length(p); lc = length(c)
                    ml = (lp < lc) ? lp : lc
                    while (lcp < ml && substr(p, 1, lcp+1) == substr(c, 1, lcp+1))
                        lcp++
                    if (lcp > best) best = lcp
                }
                path_score[i] = best
            }
            for (i = 0; i < n_path; i++)
                for (j = i+1; j < n_path; j++)
                    if (path_score[j] > path_score[i] || \
                        (path_score[j] == path_score[i] && path_list[j] < path_list[i])) {
                        t = path_list[i]; path_list[i] = path_list[j]; path_list[j] = t
                        ts = path_score[i]; path_score[i] = path_score[j]; path_score[j] = ts
                    }
            for (i = 0; i < n_path && i < max_path; i++)
                printf "%s\t%s\n", path_list[i], path_list[i]
        }')

        # Save candidate->display mapping for Shift+Enter full-line insertion
        if (( $#all_cmds )); then
            for (( i=1; i<=$#all_cmds; i++ )); do
                printf '%s\t%s\n' "${all_cmds[$i]}" "${all_display[$i]}"
            done > "$_HC_MAP"
            compadd -Q -V completions -d all_display -a all_cmds && ret=0
        fi
    }

    return $ret
}

zstyle ':completion:*' completer _complete_with_history
zstyle ':completion:*' sort false

# ---------------------------------------------------------------------------
# ZLE widgets
# ---------------------------------------------------------------------------

# Core loop: handles Tab toggle and Shift+Enter full-line expansion
_hc_complete_loop() {
    rm -f "$_HC_TOGGLE" "$_HC_FULLSIG"

    while true; do
        local before="$BUFFER"
        fzf-tab-complete

        if [[ "$BUFFER" != "$before" ]]; then
            # Accepted — expand to full line if Shift+Enter was pressed
            if [[ -f "$_HC_FULLSIG" ]]; then
                rm -f "$_HC_FULLSIG"
                local first_word="${BUFFER%%[[:space:]]*}"
                if [[ -f "$_HC_MAP" ]]; then
                    local full_line
                    full_line=$(awk -F'\t' -v cmd="$first_word" '$1==cmd{print $2; exit}' "$_HC_MAP")
                    if [[ -n "$full_line" && "$full_line" != "$first_word" ]]; then
                        BUFFER="$full_line"
                        CURSOR=${#BUFFER}
                    fi
                fi
            fi
            _comp_inverted=0
            break
        elif [[ -f "$_HC_TOGGLE" ]]; then
            rm -f "$_HC_TOGGLE"
            _comp_inverted=$(( 1 - _comp_inverted ))
        else
            break  # Escape
        fi
    done
}

# Tab: completion (history-heavy)
_hc_tab() {
    _comp_inverted=0
    unset POSTDISPLAY
    _hc_complete_loop
    unset POSTDISPLAY
    zle autosuggest-fetch 2>/dev/null
}

# Shift+Tab: completion (PATH-heavy)
_hc_shift_tab() {
    _comp_inverted=1
    unset POSTDISPLAY
    _hc_complete_loop
    unset POSTDISPLAY
    zle autosuggest-fetch 2>/dev/null
}

# Shift+Enter: accept inline autosuggestion
_hc_accept_suggestion() {
    zle autosuggest-accept
    zle reset-prompt
}

# ---------------------------------------------------------------------------
# hist-complete-bind-keys: call AFTER fzf-tab and fzf --zsh are loaded
# ---------------------------------------------------------------------------

hist-complete-bind-keys() {
    # PTY wrapper: translates Shift+Enter (\e[13;2u) -> Ctrl+O for fzf
    if [[ -x "${_HC_DIR}/fzf-key-translate" ]]; then
        zstyle ':fzf-tab:*' fzf-command "${_HC_DIR}/fzf-key-translate"
    fi

    # Inside fzf:  Tab=toggle, Enter=first word, Shift+Enter=full line, Escape=dismiss
    zstyle ':fzf-tab:*' fzf-bindings-default \
        "tab:execute-silent(touch $_HC_TOGGLE)+abort" \
        "ctrl-o:execute-silent(touch $_HC_FULLSIG)+accept" \
        'btab:up' 'change:top' 'ctrl-space:toggle' \
        'bspace:backward-delete-char/eof' 'ctrl-h:backward-delete-char/eof'

    # Prevent autosuggestion bleed during completion
    ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(_hc_tab _hc_shift_tab)

    # Register and bind
    zle -N _hc_tab
    zle -N _hc_shift_tab
    zle -N _hc_accept_suggestion
    bindkey '^I' _hc_tab                    # Tab
    bindkey '\e[Z' _hc_shift_tab            # Shift+Tab
    bindkey '\e[13;2u' _hc_accept_suggestion # Shift+Enter
}
