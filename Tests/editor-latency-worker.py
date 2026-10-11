#!/usr/bin/env python3
"""Isolated system Vim insert workload with a sequence-colored status line.

Vim handles every key, edits an actual buffer and redraws its native TUI. The
status-line color is an observation marker set by TextChangedI; its tiny hook
is shared by both terminals. This is not uninstrumented editor latency.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time


def vim_string(value):
    return "'" + str(value).replace("'", "''") + "'"


def prepare(output, timeout, vim, runtime):
    if not 1 <= timeout <= 600:
        raise ValueError("timeout must be 1...600 seconds")
    if not vim.is_file() or not os.access(vim, os.X_OK) or not runtime.is_dir():
        raise ValueError("the requested installed Vim and runtime must exist")
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    source = output / "generated.swift"
    source.write_text("\n" + "\n".join(
        f"func generated_{index:04d}(value: Int) -> Int {{ return value + {index} }}"
        for index in range(1000)) + "\n")
    size = os.get_terminal_size(0)
    metadata = {"pid": os.getpid(), "parentPID": os.getppid(), "role": "editor",
                "fixture": "system-vim-insert-with-status-marker", "ttyPath": os.ttyname(0),
                "rows": size.lines, "columns": size.columns,
                "startedMonotonicNs": time.monotonic_ns(),
                "vimExecutable": str(vim), "vimRuntime": str(runtime)}
    script = output / "fixture.vim"
    script.write_text("\n".join([
        "set nocompatible",
        "let &runtimepath = " + vim_string(runtime),
        "set packpath=",
        "set nomodeline noexrc noswapfile nobackup nowritebackup",
        "set termguicolors noshowmode noruler noshowcmd laststatus=2",
        "set shortmess+=I",
        "let &statusline = '%#CmdyBenchMarker#' . repeat(' ', 400)",
        "syntax on",
        "setfiletype swift",
        "let g:bench_directory = " + vim_string(output),
        "let g:bench_metadata = json_decode(" + vim_string(json.dumps(metadata)) + ")",
        "let g:bench_receipts = []",
        "let g:bench_error = ''",
        "let g:bench_sequence = 0",
        "let g:bench_last_text = ''",
        "let g:bench_ready = 0",
        "let g:bench_start = reltime()",
        "function! BenchWrite(name, value) abort",
        "  let destination = g:bench_directory . '/' . a:name",
        "  call writefile([json_encode(a:value)], destination . '.tmp')",
        "  call rename(destination . '.tmp', destination)",
        "endfunction",
        "function! BenchPaint() abort",
        "  let red = 48 + (g:bench_sequence % 16) * 11",
        "  let green = 48 + ((g:bench_sequence / 16) % 16) * 11",
        "  execute printf('highlight CmdyBenchMarker guifg=#101010 guibg=#%02x%02xd3', red, green)",
        "  redrawstatus",
        "endfunction",
        "function! BenchChanged() abort",
        "  let text = getline(1)",
        "  if text !~# '^a*$' || strlen(text) != g:bench_sequence + 1 || line('$') != 1001",
        "    let g:bench_error = 'unexpected edit sequence'",
        "    return",
        "  endif",
        "  let g:bench_sequence += 1",
        "  let g:bench_last_text = text",
        "  call add(g:bench_receipts, {'sequence': g:bench_sequence, 'columns': &columns, 'rows': &lines,",
        "        \\ 'event': 'TextChangedI', 'vimElapsedSeconds': reltimefloat(reltime(g:bench_start))})",
        "  call BenchPaint()",
        "endfunction",
        "function! BenchReady() abort",
        "  if g:bench_ready | return | endif",
        "  let g:bench_ready = 1",
        "  let g:bench_metadata.rows = &lines",
        "  let g:bench_metadata.columns = &columns",
        "  call BenchWrite('ready.json', g:bench_metadata)",
        "endfunction",
        "function! BenchStart() abort",
        "  call cursor(1, 1)",
        "  call BenchPaint()",
        "  call timer_start(" + str(int(timeout * 1000)) + ", {timer -> execute('qa!')})",
        "  startinsert",
        "endfunction",
        "function! BenchLeave() abort",
        "  call BenchWrite('received.json', g:bench_receipts)",
        "  call BenchWrite('cleanup.json', {'pid': getpid(), 'status': 'stopped',",
        "        \\ 'fixture': 'vim', 'error': g:bench_error, 'insertedCharacters': strlen(g:bench_last_text),",
        "        \\ 'lastValidatedTextSHA256': sha256(g:bench_last_text), 'vimVersion': v:versionlong})",
        "endfunction",
        "augroup CmdyBenchmark",
        "  autocmd!",
        "  autocmd VimEnter * call BenchStart()",
        "  autocmd InsertEnter * call BenchReady()",
        "  autocmd TextChangedI * call BenchChanged()",
        "  autocmd VimResized * call BenchPaint()",
        "  autocmd VimLeavePre * call BenchLeave()",
        "augroup END",
        "",
    ]))
    return [str(vim), "-N", "-u", "NONE", "-i", "NONE", "--noplugin", "-n",
            "-S", str(script), str(source)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--vim", type=Path, default=Path("/usr/bin/vim"))
    parser.add_argument("--runtime", type=Path, default=Path("/usr/share/vim/vim91"))
    args = parser.parse_args(argv)
    try:
        command = prepare(args.output.resolve(), args.timeout, args.vim.resolve(), args.runtime.resolve())
        # Keep the same owned PID and TTY. NONE/no-plugin flags and the explicit
        # runtime path prevent user vimrc, viminfo, packages and source files.
        os.execv(command[0], command)
    except (OSError, ValueError) as error:
        print(f"Editor fixture failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
