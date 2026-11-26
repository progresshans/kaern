# Flow checks

Checks of the whole app: a test instance of Kaern is taken through what a person does (stage, commit, rebase, resolve
a conflict, drag a pane…), and its state is read back and compared. The KaernKit tests cover git and parsing; these
cover what the app does with them.

They drive a Debug build through its debug driver (`Kaern/App/DebugDriver*.swift`). A test instance is started with a
session file of its own (`-KaernSessionFile`) and a private macOS preferences domain. After the app exits, the
launcher exports the domain to the session's `.settings.plist` and removes the live domain. A relaunch imports
that file. The session's git config and credentials also live beside it. The repositories it works on are samples
made from scratch (`make_samples.py`, `bigsample.py`, `scen6.py`).

## Run

```
checks/build.sh                 # the Debug build the checks start (not the one you run yourself)
python3 checks/suite.py         # every check, three at a time
```

| | |
|---|---|
| Some checks | `python3 checks/suite.py t_stash t_marks6` |
| The checks for an area | `python3 checks/suite.py --area sidebar,undo` |
| The checks for what changed | `python3 checks/suite.py --changed` (since `develop`; `--changed <base>`), uncommitted files included |
| What would run | add `--list` |
| One at a time, or more at a time | `--jobs 1`, `-j 5` |
| One check by hand | `python3 checks/t_stash.py` (prints as it goes; `KAERN_TRACE=1` shows where the time goes) |

Before a merge, run everything: `--area` and `--changed` are for the time in between. A change to a core file (the app
model, the repository model, the window, the driver, GitRunner, a helper here…) selects every check.

More options: `--no-dark` (no dark pictures), `--reuse-samples` (keep the sample cache if it is still good),
`--repeat N` (to find a check that fails now and then), `--timeout S`, `--log FILE`.

Results are in `<work folder>/suite/latest/`: `<check>.log` for each check, `summary.txt` and `times.tsv`. The exit
status is 0 when every check passed. A check that gives up says what it waited for and what the app showed instead,
and leaves `runs/<check>/failed-dump.json` and `failed.png`.

The checks run three at a time, the long ones first. One that measures speed or memory (`alone` in `--list`) runs
after them with nothing beside it. One suite at a time in a work folder; Ctrl-C stops it and its instances.

The test windows are beside the screen, 12,000 points to the right of where they would be, and never take the
keyboard: they cover nothing of yours while the checks run. They are drawn there as on the screen, and the pictures
are the same. The menus and popovers a check opens come up beside them, where they would be on the screen (the
instance's screens answer from there as well, `TestSession.moveScreensAside`), so the pictures have them too.
`KAERN_ON_SCREEN=1` keeps the windows on the screen, to watch a check.

## Where things are

`python3 checks/paths.py` prints the work folder and the app. The work folder is in the temporary folder, one per
checkout (`KAERN_CHECKS_WORK` names another; its path can't have a space). It isn't in the repository because macOS
asks before an app reads a folder such as Documents, and a test instance has nobody to answer. `KAERN_APP` names
another Kaern.app to start.

Each check (a "run") has `<work folder>/runs/<check>/`: its samples, a session file per launch, its git config, and
the files the app answers into. Its instance takes only the commands of its own channel (`-KaernDebugChannel`), and
the real mouse can't hover or click in it (`-KaernDebugIgnorePointer`).

- A command to a run's instance: `python3 checks/k3.py --run t_stash dump /tmp/state.json`.
- An instance to look at by hand: `checks/launch.sh light [scenario]` (the run "manual"; it is on the screen and
  the mouse works in it), then `python3 checks/k3.py snapshot /tmp/a.png`.

Samples are built once into `<work folder>/sample-cache/` (`python3 checks/samples.py list`), and a run gets APFS
clones of what it needs. The suite builds them again at its start; a check run by hand builds what is missing or
older than three hours. Nothing writes into the cache: the suite fails if a file there changed.

Pictures go to `<work folder>/shots/`. A check takes each one in light, switches the instance to dark, takes it
again and switches back. They are for looking at; what a check decides on is the app's state.

## On GitHub

CI runs the suite on each pull request and each push to develop (the `flow` job in `.github/workflows/ci.yml`),
without the dark pictures. GitHub's Mac is several times slower than a recent MacBook, so `KAERN_PATIENCE=3` makes
every limit three times as long there. The checks wait for a state, never for a time, so only a check that fails
takes longer. The job keeps each check's log, and for a check that gave up the app's state and a picture of its
window (the `flow-checks` artifact of the run).

Its screen is small, which doesn't matter: a test session's windows are as large as a check asks, whatever the
screen (`AppWindow` in `Kaern/Window/MainWindowController.swift`), and beside it there as here.

## Writing or changing a check

Nothing waits a fixed time. A command returns at once; what it should bring about is waited for.

```python
from k5 import *
launch_prepared(mode, scenario='base', prepare=None, extra=[])     # fresh samples and instance, every tab loaded
d = show_tab('powerlens')                                          # the tab is shown and loaded
k('undo')                                                          # send a command
d = settle(lambda d: git('rev-parse', 'HEAD') == head0, label='the undo')
```

- `settle(check)`: the app is quiet (no action, load, refresh or git command under way), `check(dump)` holds, and the
  file watcher has caught up with every change made so far. This is what follows a command: the app drops a command
  sent while an action still runs, and the refresh the watcher starts up to 0.3 s after a change would otherwise
  run into the next command. Give it the state the step should reach, not just `settle()`.
- `until(check)`: only the state, for something to catch while the app is still working.
- `sync()`: every command sent so far has run (for a step whose effect is immediate, or "nothing happens").
- `hold_at('status')`: a refresh waits at that point once git has answered, until `k('release', 'status')` (the
  points are in `DebugDriver+Holds.swift`). The hold is in place when it returns, so a change made next is caught; a
  plain `k('hold', …)` can reach the app after the read it was for.
- git run in a sample from the check, or files written there: wait with `settle(...)` for the state the app should
  then show.
- Text: `type_text('name', into='feature/name')` waits until the field with that placeholder has the keyboard.
- Pictures: `snap(name, mode)` takes the picture until two in a row are identical. `changed=True` when the step
  before changed only what shows (no dump field); `toast=True` when the toast on screen belongs in the picture;
  `composite=True`, `window='Command Log'`. `menu_snap(name, 'menu', …)` for a picture with a menu open.
- Samples: `launch_prepared(scenario=…)` takes `base`, `conflict`, `stash-conflict`, `signed`; `big_sample(name,
  commits)`, `scen6.big_remotes()`, `scen6.big_changes()` in `prepare`. A new big sample is a kind in `samples.py`.
- A pause may stay when it is the step itself, not a wait: when a person acts a moment later, or what is left some
  time afterwards. Say so next to it.
- When a feature says "held", "dragged" or "repeated", send that kind of input (`press down hold 12`, `drag`).
- Add the check to `CHECKS` in `suite.py`: its areas, `dark=True` if its pictures matter in dark too, `alone=True`
  if it measures, the sample kinds it uses, about how long it takes.

The samples' names are made up, apart from the open-source godj and PowerLens. Keep it that way: no name of a
private project in a sample, a check or a commit message.

Helpers: `k3.py` (the run, its channel, `k`, `until`, `settle`, `sync`, `hold_at`, the app's process), `k4.py` (launching,
quitting, settings), `k5.py` (pictures, typing, tabs), `samples.py` (the cache), `scen5.py` / `scen6.py` (sample
states), `paths.py` (the work folder and the app).
