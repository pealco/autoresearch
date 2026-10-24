#!/usr/bin/env bash
# Run autoresearch in rounds with forgetting (arXiv:2610.20563, "Scaling Discovery Requires Forgetting").
# Each round starts every agent in a fresh session and a fresh worktree from the best commit so far.
# Sessions, branches and results.tsv files from earlier rounds are never shown to later rounds.
# Usage: ./forget.sh <tag> [rounds=4] [agents=1] [experiments_per_round=30]
# program.md defines the task. Nothing here needs a GPU. Optional environment variables:
#   EVAL_CMD     runs one experiment and prints "<METRIC>: <value>" (default: uv run train.py)
#   METRIC       metric name, also column 2 of results.tsv (default: val_bpb)
#   MAXIMIZE=1   higher is better (default: lower is better)
#   PROTECT      space-separated paths; a candidate that changes any of them cannot win (default: prepare.py)
#   RESCORE      rerun the top N candidates each round and pick by mean score; 0 disables (default: 3)
#   GPUS=0,1     pin agent i to the i-th listed GPU, wrapping around (default: no pinning)
#   ROUND_HOURS  wall-clock cap per round, whole hours (default: 12)
#   AGENT_CMD    agent CLI (default: claude -p --dangerously-skip-permissions)
set -euo pipefail
tag=${1:?usage: ./forget.sh <tag> [rounds] [agents] [experiments_per_round]}
rounds=${2:-4} agents=${3:-1} experiments=${4:-30}
read -ra agent_cmd <<< "${AGENT_CMD:-claude -p --dangerously-skip-permissions}"
eval_cmd=${EVAL_CMD:-uv run train.py} metric=${METRIC:-val_bpb}
order=-g
[[ ${MAXIMIZE:-} == 1 ]] && order=-gr
protected=${PROTECT-prepare.py}
read -ra protect <<< "$protected"
rescore=${RESCORE:-3}
((rescore > 0)) || rescore=1
IFS=, read -ra gpus <<< "${GPUS:-}"
cap=$((${ROUND_HOURS:-12} * 3600))
root=$(git rev-parse --show-toplevel)
export UV_PROJECT_ENVIRONMENT="$root/.venv" # share one venv across worktrees
best=$(git rev-parse --short=7 HEAD) best_score=""
start=$best

pin() { # pin this process to GPU slot $1 if GPUS is set
  if ((${#gpus[@]})); then export CUDA_VISIBLE_DEVICES=${gpus[$1 % ${#gpus[@]}]}; fi
}

score() { # run commit $1 once in a fresh worktree named $2 with AUTORESEARCH_EVAL_SPLIT=$3; print its metric
  local wt="$root/worktrees/$tag/$2-$1"
  git worktree add -q --detach "$wt" "$1"
  (cd "$wt" && pin 0 && AUTORESEARCH_EVAL_SPLIT=$3 bash -c "$eval_cmd" < /dev/null > "$wt.log" 2>&1) || true
  awk -v m="$metric:" '$1 == m { print $2 }' "$wt.log"
}

for ((r = 1; r <= rounds; r++)); do
  dir="$root/worktrees/$tag/r$r"
  for ((a = 1; a <= agents; a++)); do
    git worktree add -q -b "autoresearch/$tag-r$r-a$a" "$dir/a$a" "$best"
  done
  for ((a = 1; a <= agents; a++)); do
    peers=""
    for ((p = 1; p <= agents; p++)); do
      ((p == a)) || peers+="- branch autoresearch/$tag-r$r-a$p, results in ../a$p/results.tsv"$'\n'
    done
    prompt="Read program.md and run the experiment loop in round mode (see the 'Rounds' section).
Round $r of $rounds. You are on branch autoresearch/$tag-r$r-a$a, starting from commit $best. Setup is done: do not create a branch.
Stop after about $experiments experiments.${protected:+
A commit that changes any of these paths is disqualified: $protected}${peers:+
Peers working in parallel this round:
$peers}"
    # perl alarm is a portable timeout: macOS has no timeout(1).
    (cd "$dir/a$a" && pin $((a - 1)) && perl -e 'alarm shift; exec @ARGV' "$cap" "${agent_cmd[@]}" "$prompt") > "$dir/a$a.log" 2>&1 &
  done
  wait

  # Take the best kept commits, one row per commit, skipping any that changed a protected path.
  picked="" count=0
  while IFS=$'\t' read -r s c; do
    if ((${#protect[@]})) && ! git diff --quiet "$start" "$c" -- "${protect[@]}"; then
      echo "  $c not eligible: it changes $protected"
      continue
    fi
    picked+="$s"$'\t'"$c"$'\n' count=$((count + 1))
    if ((count >= rescore)); then break; fi
  done < <(awk -F'\t' '$4 == "keep" { print $2 "\t" $1 }' "$dir"/a*/results.tsv 2> /dev/null | sort "$order" | awk -F'\t' '!seen[$2]++')

  # The top score is the luckiest of many noisy runs. Rerun each finalist once and rank by the mean.
  if ((count > 1)); then
    echo "  rerunning the top $count candidates"
    rescored=""
    while IFS=$'\t' read -r s c; do
      s2=$(score "$c" "r$r-rescore" val)
      if [[ -n $s2 ]]; then rescored+=$(awk -v a="$s" -v b="$s2" -v c="$c" 'BEGIN { printf "%s\t%s", (a + b) / 2, c }')$'\n'; fi
    done < <(grep . <<< "$picked")
    picked=$rescored
  fi

  new=$(grep . <<< "$picked" | sort "$order" | head -1 || true)
  [[ -n $new ]] && best=${new#*$'\t'} best_score=${new%$'\t'*}
  echo "round $r/$rounds: best commit $best ($metric $best_score)"
done
echo "done: best commit $best (git checkout $best)"

# Selection used the same validation data many times, so part of the gain can be fit to it.
# Rerun the start and best commits once each on holdout data that no decision has seen.
[[ $best == "$start" ]] && exit 0
start_score=$(awk -F'\t' -v c="$start" '$1 == c { print $2 }' "$root/worktrees/$tag/r1"/a*/results.tsv 2> /dev/null | sort "$order" | head -1 || true)
echo "holdout check: rerunning $start and $best with AUTORESEARCH_EVAL_SPLIT=holdout"
echo "validation: $start ${start_score:-?} -> $best $best_score"
echo "holdout:    $start $(score "$start" holdout holdout) -> $best $(score "$best" holdout holdout)"
