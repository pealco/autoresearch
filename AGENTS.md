# Agent guide

autoresearch is a loop where an agent edits code, runs one fixed-budget experiment, keeps the change if one metric improved, reverts it otherwise, and repeats. This fork adds `forget.sh`, which runs that loop in rounds with fresh agent sessions, and checks that keep the loop from improving the score without improving the result.

## Which situation are you in?

1. **Your prompt says you are in round mode** (`forget.sh` started you): follow `program.md` in your working directory. Ignore the rest of this file.
2. **The user wants to run the example task in this repo** (training a small language model): follow `program.md`. It needs an NVIDIA GPU and `uv run prepare.py` first.
3. **The user wants to use autoresearch for their own research project** (any repository, any language, CPU or GPU): follow [Set up a project](#set-up-a-project) below. Most users are in this situation.

## Set up a project

Do this in the user's project repository, not in this repository. The result is a project where one command runs one experiment and prints one number, and where `forget.sh` can run the loop without supervision.

### 1. Decide the experiment with the user

Ask the user for anything here that you cannot find in their repository. Write the answers into `program.md` in step 5.

- **The question and the metric.** One number per experiment, and whether higher or lower is better. If the user cares about two things, combine them into one number or make the second one a crash condition. Give the metric a name without a split in it, such as `elpd` or `rmse`: the evaluation prints the same name for validation and holdout scores.
- **The editable files.** Usually the model or pipeline code. Keep the set small, so that diffs stay reviewable.
- **The interface.** The function the evaluation calls in the editable code, for example `fit(train) -> predict`. The editable code receives only training data through it.
- **The protected files.** Everything that decides the score: data loading, splits, seeds, the metric, and also `program.md`, `forget.sh` and `autoresearch.env`. The agent must not be able to change these.
- **The fixed budget.** What stays the same in every experiment, so that scores are comparable: a wall-clock limit, a number of MCMC draws, a number of boosting rounds, a fixed set of API calls. The evaluation script enforces it, not the agent.
- **The run time** of one experiment, measured in step 6. It sets the experiments per round and `ROUND_HOURS`.
- **The cost** of one experiment if it calls a paid API, and a limit for the whole run. Agent tokens also cost money: the number of agents is usually limited by cost, not by CPU cores.
- **Crash conditions.** Results that must not count as wins even if the metric improves.

Defaults by kind of project:

| Project | Metric | Fixed budget | Crash if |
|---|---|---|---|
| Bayesian hierarchical model (MCMC) | held-out ELPD or log predictive density (higher) | chains, warmup, draws, seed | divergences, R-hat > 1.01, low ESS |
| XGBoost or other classical ML | validation AUC, log loss or RMSE | fixed CV folds and seeds; a cap on boosting rounds or fit time | the fit errors or exceeds the time cap |
| Embeddings or external model calls | task accuracy on a fixed eval set | fixed eval set; a cap on calls or tokens; cache responses | API errors; cost above the cap |

### 2. Split the data once

Make three splits, once, before any experiment: training, validation and holdout. Store them (or the seed and code that produce them) in the protected files. The loop decides keep or discard on the validation split. The holdout split is used only at the end, to check that validation gains generalize.

### 3. Write the evaluation command

Write one protected script, for example `evaluate.py`, that:

1. calls the editable code through the interface, passing only the training split;
2. stops the fit if it exceeds the fixed budget, and treats that as a crash;
3. scores on the holdout split when the environment variable `AUTORESEARCH_EVAL_SPLIT` is `holdout`, and on the validation split otherwise (`forget.sh` also passes `val`);
4. if a crash condition is met, exits non-zero and prints no metric line;
5. otherwise prints exactly one line `<metric>: <value>`, with the same metric name for both splits.

Keep the evaluation out of the editable files. If the editable code computes its own score, the protected-files check cannot protect anything. For the same reason, the editable code must not load the validation or holdout data itself; say so in `program.md`.

### 4. Add the harness

Copy `forget.sh` and `program.template.md` from this repository into the project:

```bash
curl -fsSLO https://raw.githubusercontent.com/pealco/autoresearch/master/forget.sh
curl -fsSL https://raw.githubusercontent.com/pealco/autoresearch/master/program.template.md -o program.md
chmod +x forget.sh
```

Add these lines to the project's `.gitignore`: `results.tsv`, `run.log`, `worktrees/`, and the language's build or cache output (for Python, `__pycache__/`). Agents work in git worktrees, which only see the committed `.gitignore`, so it is committed with the rest of the setup in step 6.

### 5. Fill in program.md and autoresearch.env

Replace every `<FILL: ...>` in `program.md` with the answers from step 1. Then delete the comment at the top. Do not rename the sections: the "Rounds" section is what `forget.sh` tells each agent to read.

Write `autoresearch.env` at the project root, so that `forget.sh` needs no settings on its command line. Use one `KEY=value` line per setting and no quotes. For example:

```
EVAL_CMD=uv run evaluate.py
METRIC=elpd
MAXIMIZE=1
PROTECT=evaluate.py data/ program.md forget.sh autoresearch.env
RESCORE=3
ROUND_HOURS=6
```

Leave out `MAXIMIZE` if lower is better. Set `ROUND_HOURS` to about twice (experiments per round × run time), rounded up to whole hours. See [forget.sh reference](#forgetsh-reference) for every setting.

### 6. Check that it works

Run each check and fix any problem before you continue:

1. Run the evaluation command and confirm it prints `<metric>: <value>`. Record the run time in `program.md`.
2. Run it with `AUTORESEARCH_EVAL_SPLIT=holdout` and confirm that the score changes, which shows it used different data.
3. Run it a second time without the variable. If both validation scores are identical, the task is deterministic: set `RESCORE=0` in `autoresearch.env`.
4. Make the editable code fail on purpose (for example, raise an error in the fit), run the evaluation, and confirm that it exits non-zero and prints no metric line. Then undo the change.
5. Run `grep -n "FILL" program.md` and confirm it prints nothing.
6. Commit the setup on the branch the user works on (usually `main` or `master`). `forget.sh` starts every run from the current commit, so the setup must be committed before the first run.

### 7. Give the user the commands

Do not start a long run yourself unless the user asks. `forget.sh` runs for hours, and by default it starts agents with `claude -p --dangerously-skip-permissions`, which skips all permission prompts. Tell the user to run it in an isolated machine or container.

Give the user these two options, with the values filled in:

1. **One interactive agent:** open an agent in the project and say "Read program.md and let's kick off a new experiment. Let's do the setup first."
2. **Rounds with forgetting** (recommended for long runs):

   ```bash
   ./forget.sh oct24 4 1 30
   ```

   The arguments are the run tag, the number of rounds, the number of agents per round, and experiments per round. Start with 1 or 2 agents: each agent is a separate paid session. If experiments are CPU-heavy, agents in the same round also share the CPU cores, so do not run more agents than the cores can serve.

## forget.sh reference

Usage: `./forget.sh <tag> [rounds=4] [agents=1] [experiments_per_round=30]`

Set these variables in `autoresearch.env` at the repo root (`KEY=value`, no quotes) or in the environment. The environment takes precedence over the file. The defaults fit this repo's example task.

| Variable | Default | Meaning |
|---|---|---|
| `EVAL_CMD` | `uv run train.py` | Runs one experiment and prints `<METRIC>: <value>`. |
| `METRIC` | `val_bpb` | Metric name. Also column 2 of `results.tsv`. |
| `MAXIMIZE` | unset | Set to `1` if higher is better. Leave it out if lower is better. |
| `PROTECT` | `prepare.py` | Space-separated paths. A commit that changes any of them cannot win a round. |
| `RESCORE` | `3` | Rerun the top N candidates each round and rank by mean score. `0` disables. |
| `GPUS` | unset | Comma-separated GPU ids. Agent *i* uses the *i*-th id. Unset means no pinning. |
| `ROUND_HOURS` | `12` | Wall-clock limit per round, in whole hours. |
| `AGENT_CMD` | `claude -p --dangerously-skip-permissions` | Agent CLI. It receives the prompt as its last argument. |

What a run does:

1. Each round, every agent gets a fresh session and a fresh worktree under `worktrees/<tag>/`, starting from the best commit so far. Earlier sessions and results are not shown to it.
2. Agents in the same round can read each other's commits and `results.tsv`.
3. At the end of a round, commits that change a `PROTECT` path are rejected, the top `RESCORE` candidates are rerun, and the best mean score starts the next round.
4. At the end of the run, the start commit and the best commit are rerun with `AUTORESEARCH_EVAL_SPLIT=holdout`. If the holdout gain is much smaller than the validation gain, the search overfit the validation data.

Why rounds help: one long session plateaus, because the agent makes smaller edits as its history grows. Restarting from the best commit with an empty context gets it making large edits again ([arXiv:2610.20563](https://arxiv.org/abs/2610.20563)).
