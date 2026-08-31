#!/bin/bash
# Replay every preserved soak repro, categorize each surviving divergence
# by its structural signature, cluster. Read-only — never touches the engine.
set -u
O="$HOME/.cache/cmdy-oracle"
OUT="$O/soak/triage"; mkdir -p "$OUT"
: > "$OUT/verdicts.tsv"
n=0; live=0; stale=0
for f in "$O"/soak/repros/*.bin; do
  n=$((n+1))
  R=$("$O/cmdy-diff" --bytes "$f" 2>&1)
  base=$(basename "$f" .bin)
  # DIVERGED (past tense) is the real marker — ORACLE.md's documented trap.
  if ! echo "$R" | grep -q "^DIVERGED$"; then
    stale=$((stale+1)); echo -e "STALE\t-\t-\t$base" >> "$OUT/verdicts.tsv"; continue
  fi
  live=$((live+1))
  body=$(echo "$R" | grep -vE "^Info:")
  # category: what KIND of divergence
  cat="other"
  if echo "$body" | grep -q "cursor:"; then cat="cursor"
  elif echo "$body" | grep -qE "live\[[0-9]+\] text: core '' vs st ''"; then cat="blank-cell-attr"
  elif echo "$body" | grep -qE "live\[[0-9]+\] text: core '[^']"; then cat="text"
  fi
  # detail: the first concrete divergence line, numbers normalized
  detail=$(echo "$body" | grep -E "cursor:|live\[[0-9]+\] (text|attr|bg|fg):" | head -1 \
           | sed -E "s/live\[[0-9]+\]/live[N]/; s/\([0-9]+,[0-9]+\)/(N,N)/g")
  echo -e "LIVE\t$cat\t$detail\t$base" >> "$OUT/verdicts.tsv"
  echo "$R" > "$OUT/$base.txt"
done
echo "replayed $n · still-diverging $live · went-stale $stale"
echo
echo "== categories:"
grep "^LIVE" "$OUT/verdicts.tsv" | cut -f2 | sort | uniq -c | sort -rn
echo
echo "== top signatures (category → detail → count):"
grep "^LIVE" "$OUT/verdicts.tsv" | awk -F'\t' '{print $2" :: "$3}' | sort | uniq -c | sort -rn | head -15
