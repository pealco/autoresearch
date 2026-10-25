<!--
Template for a project's program.md. AGENTS.md explains how to fill it in.
Replace every <FILL: ...> and delete this comment. Keep the section names: forget.sh refers to "Rounds".
-->

# autoresearch: <FILL: project name>

This is an experiment to have an LLM agent do its own research on this project.

## Task

<FILL: the research question in two or three sentences, and what a better result means for the project.>

- **Metric:** `<FILL: metric name, e.g. elpd>`. <FILL: Higher | Lower> is better. The loop uses its value on the validation split.
- **One experiment:** `<FILL: eval command, e.g. uv run evaluate.py>`. It prints a line `<FILL: metric name>: <value>`.
- **Interface:** <FILL: the function the evaluation calls in your code, e.g. model.fit(train) -> predict>. Your code receives only training data.
- **Fixed budget per experiment:** <FILL: what is held constant so that experiments are comparable, e.g. 4 chains x 1,000 draws, 5-fold CV with fixed seeds, 10 minutes wall clock>. The evaluation enforces it. A typical run takes <FILL: measured run time, e.g. 40 seconds>.
- **A run counts as a crash if:** it errors, prints no metric, or <FILL: task-specific failures, e.g. any divergent transitions or R-hat > 1.01>.

## Files

**You may change:**

- <FILL: the files the agent edits, e.g. model.py: model structure, priors, features, hyperparameters>

**You must not change (forget.sh disqualifies any commit that does):**

- <FILL: the protected paths, e.g. evaluate.py: data loading, splits, seeds and the metric>
- <FILL: e.g. data/>
- `program.md`, `forget.sh` and `autoresearch.env`

Do not add dependencies. You can only use what is already installed for this project.

Do not load the validation or holdout data in your code, do not evaluate on the holdout split, and do not set `AUTORESEARCH_EVAL_SPLIT`. The holdout data is reserved for the human to check that validation gains generalize.

**Simplicity:** all else being equal, simpler is better. A tiny gain that adds a lot of complexity is not worth keeping. Removing code with an equal or better result is a win.

## Setup

To set up a new experiment, work with the user to:

1. **Agree on a run tag**, for example `oct24`. The branch `autoresearch/<tag>` must not exist yet.
2. **Create the branch:** `git checkout -b autoresearch/<tag>`.
3. **Read the in-scope files:** this file, the files you may change, and the protected files.
4. **Check the data:** <FILL: how to confirm the data and splits are available, e.g. "data/train.csv, data/val.csv and data/holdout.csv exist", or "run the evaluation once" if the data is generated; and what to tell the human if not>.
5. **Initialize results.tsv** with only the header row (see below).
6. **Confirm and go.**

## Results

Log every experiment to `results.tsv` (tab-separated). Do not commit it. It has a header row and 5 columns:

```
commit	<FILL: metric name>	seconds	status	description
```

1. Short commit hash (7 characters).
2. The metric value. Use 0 for crashes.
3. Wall-clock seconds for the run. Use 0 for crashes.
4. `keep`, `discard` or `crash`.
5. A short description of what the experiment tried.

## The experiment loop

The first run is always the baseline: run the starting commit unchanged and log it as `keep`.

Loop:

1. Edit the files you may change with one experimental idea.
2. `git commit`.
3. Run `<FILL: eval command> > run.log 2>&1`. Do not let the output flood your context.
4. Read the result: `grep "^<FILL: metric name>:" run.log`. If it is empty, the run crashed: read `tail -n 50 run.log`.
5. Log the result in `results.tsv`.
6. If the metric improved, keep the commit and continue from it.
7. If it is equal or worse, or the run crashed, log it and `git reset --hard HEAD~1`.

If a crash is a simple bug (a typo, a missing import), fix it and rerun. If the idea itself does not work, log `crash` and move on. If a run takes more than <FILL: about 2x the typical run time>, stop it and treat it as a crash.

Long sessions drift toward small, timid edits and early "I've hit the limit" conclusions. Those conclusions are almost always wrong: a fresh agent starting from the same commit usually finds more. Keep proposing real experiments, including large ones.

Unless you are in round mode, never stop to ask the human whether to continue. Run until you are interrupted.

## Rounds

`forget.sh` runs this loop in rounds (see arXiv:2610.20563). Each round, every agent starts with an empty context in its own worktree, from the best commit of all earlier rounds. If your prompt says you are in round mode:

- Skip setup steps 1, 2 and 6. Your branch already exists and is checked out. Do steps 3 to 5.
- Your first run is the baseline of the starting commit, as usual.
- Stop after the number of experiments in your prompt, instead of running forever. The harness then starts a fresh round from the best result.
- If the prompt lists peers, they are other agents working in parallel this round. Before each experiment, you may read their `results.tsv` and inspect their commits with `git log <branch>` and `git diff HEAD <commit>`. Borrow ideas that worked for them, but keep exploring your own direction: do not copy a peer's whole branch.
