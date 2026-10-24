#!/usr/bin/env bash
# Run autoresearch in rounds with forgetting (arXiv:2610.20563, "Scaling Discovery Requires Forgetting").
# Each round starts every agent in a fresh session and a fresh worktree from the best commit so far.
# Sessions, branches and results.tsv files from earlier rounds are never shown to later rounds.
# Usage: ./forget.sh <tag> [rounds=4] [agents=1] [minutes_per_round=180]
# Agent i uses GPU i-1, so agents must not exceed the number of GPUs.
set -euo pipefail
tag=${1:?usage: ./forget.sh <tag> [rounds] [agents] [minutes_per_round]}
rounds=${2:-4} agents=${3:-1} minutes=${4:-180}
read -ra agent_cmd <<< "${AGENT_CMD:-claude -p --dangerously-skip-permissions}"
root=$(git rev-parse --show-toplevel)
export UV_PROJECT_ENVIRONMENT="$root/.venv" # share one venv across worktrees
best=$(git rev-parse --short=7 HEAD)

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
Stop after about $((minutes / 6)) experiments.${peers:+
Peers working in parallel this round:
$peers}"
    (cd "$dir/a$a" && CUDA_VISIBLE_DEVICES=$((a - 1)) timeout "${minutes}m" "${agent_cmd[@]}" "$prompt" > "$dir/a$a.log" 2>&1) &
  done
  wait
  # ponytail: picks the single lowest val_bpb, so a lucky noisy run can win; rerun the top few if that bites.
  new=$(awk -F'\t' '$4 == "keep" && $2 > 0 { print $2 "\t" $1 }' "$dir"/a*/results.tsv 2> /dev/null | sort -g | head -1 | cut -f2 || true)
  best=${new:-$best}
  echo "round $r/$rounds: best commit $best"
done
echo "done: best commit $best (git checkout $best)"
