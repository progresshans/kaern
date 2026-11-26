# Changelog

What changed in each version of Kaern. A version's section is what its update window and GitHub release show.

## [Unreleased]

### Improved

- A branch or tag name that doesn't fit can be read whole: rest the pointer on it. In the history, a label that
  its column cuts short unfolds over the graph, the way the "+2" list does. In the sidebar, the row is drawn as wide
  as its name needs, on over the history beside it.
- With many branches or changes, every list is still a glance away. The sidebar's headers stay in view and each of
  its sections scrolls on its own, and so do the panel's Unstaged Files and Staged Files. While everything fits,
  nothing changes. When it doesn't, drag the line between two of them to give one more room; Kaern keeps the
  heights for next time, and a double-click on the line shares the room out again.

### Fixed

- When Stop ends a Git command, it also ends a hook or tool Git has just started. A command that
  doesn't end when asked is ended by force after 10 seconds.
- Stopping an operation from Activity or the Command Log while Kaern puts uncommitted changes aside brings them
  back with their staging intact. This applies to merge, rebase, pull, Reset Hard and removing a worktree.
- The sidebar's Submodules show where a moved submodule came from (2.6.4 → 2.7.0) also when Git's status leaves
  the submodule out, as it does with `ignore = all`. It read "?" before.
- Quick Look opened again right after closing it (Space twice in a row) stays open. Before, it closed again at
  once.

## [1.0.1] - 2026-11-19

Resizable panes, worktrees in tabs of their own, Finish Feature and zoom, with smoother scrolling and many fixes.

### New

- Drag the edge of the sidebar, the panel on the right or Focus's drawer to resize it, and the list of repositories
  when they're in one. They grow as far as the window allows, leaving the middle at least 400 points. Double-click
  the edge to put it back. Kaern keeps the sizes for next time.
- ↑ and ↓ move through the files of a commit or of your changes once you click one, in the panel and in Focus's
  drawer. Held down, they keep going, in the history too. Back from Review, the history takes them without a click.
- When several branches or tags point at one commit, the history shows one label and "+2". Rest the pointer on it
  and every label unfolds in a list, with its whole name and its right-click menu.
- Double-click a branch's label in the history, or in its "+2" list, to switch to it, as in the sidebar. A remote
  branch's label checks out a local branch that tracks it.
- Double-click a worktree in the sidebar, or a branch checked out in one, to open that worktree in a tab of its
  own. Right-click a worktree to open it, show or copy its folder, lock it, or remove it with or without its
  branch. A branch checked out in another worktree offers Open Worktree instead of Checkout, and no Delete while
  that worktree is there.
- Finish a feature branch in one step, as Gitflow has it: right-click a `feature/…` branch (or Branch › Finish
  Feature…) in a repository with a `develop` branch. Kaern merges it into develop with a merge commit whose message
  you write, can replay it on develop first and delete it afterwards, and keeps those choices for the repository.
  Each step can be taken back with ⌘Z.
- View › Zoom In (⌘+), Zoom Out (⌘−) and Actual Size (⌘0) make Kaern's text, rows and spacing larger or smaller,
  from 80% to 150%, in every window. Kaern keeps the zoom for next time.

### Improved

- Scrolling the history is smoother, and Kaern does less in the background: a refresh starts only for files that
  count (not ones Git ignores), and the graph is rebuilt only when something in it changed.
- Coming back to a tab takes about a third of the work: Kaern keeps the screens of the five tabs you used last,
  as you left them, instead of building them again.
- Review opens on thousands of changed files without stopping the window. It lists the first 40 files, with
  "N more" for the rest, and loads diffs as you scroll.
- When Create New Repository can't publish to GitHub, the repository still opens, and a sheet says what was made
  and what is left, with Try Again and Not Now. Trying again after a failed push only pushes.
- Publish to GitHub shows the name GitHub will give the repository, and asks for that one.
- An error from git is easier to read: its advice about access rights is on one line, apart from what went wrong.
- Sign Out asks first.
- The branch you're on stays in its place in the sidebar, inside its folder, instead of moving to the top. A folded
  folder that holds it shows a check.
- In a narrow panel, a file whose folder doesn't fit shows just its name, without a sliver of the folder.

### Fixed

- A commit far down a long history stays selected through a refresh.
- After closing several tabs, the right one is picked, and groups stay in place.
- A file whose name looks like a pattern is taken as that file.
- A new sign-in shows in sheets that are already open.
- Cancelling Sign In during its check no longer adds the account.
- Undoing Create Branch from Stash puts the stash back.
- The list of remote branches shows more when scrolled to "N more".
- A tag called "v" no longer stops the suggestion for the next tag name.
- Interactive Rebase warns that Push will need Force Push whenever commits already on the remote would change:
  when a Squash or Fixup folds into one, when they trade places, or when they go onto a branch that has moved on.
  Choosing another branch in Onto, such as the upstream, no longer warns when they stay as they are.
- A repository you've just cloned counts as fetched when it was cloned: the status bar no longer says "Not fetched
  from origin yet", and the Repositories window shows the time. Before a worktree's first fetch, its tab shows when
  the repository was last fetched.
- And many smaller fixes.

## [1.0.0] - 2026-11-13

The first release of Kaern, a native Git client for macOS. Free and open source.

- **Every repository in reach.** Repositories open in tabs, in a list beside the history, or behind one toolbar button,
  and related ones can share a group. The windows and tabs you had open come back the next time.
- **A history you can read.** Branches keep their colors, runs of bot updates fold into one row, signed commits show
  who signed them, and search and Quick Open find any commit, branch or file.
- **See exactly what changed.** Split or unified diffs down to the word, images compared side by side, with a swipe or
  as an onion skin, and the history and blame of every line.
- **Commit exactly what you mean.** Stage single lines, and take back almost anything with ⌘Z: discarded changes are
  kept in Stashes.
- **Branch, merge and rewrite with confidence.** Compare branches, rebase interactively, resolve merge conflicts side
  by side, and work in several worktrees.
- **Nothing hidden.** Kaern runs the git you already have, with your config, your hooks and your SSH keys, and its
  Command Log shows every command it ran. It needs no account.

Kaern needs macOS 26 or later on a Mac with Apple silicon, and keeps itself up to date.
