Review the pull request of the item {{title}} against its acceptance list.

Check out the pull request's head in a git worktree of your own, named after the attempt, and run
`noslop review --adapter claude --json --report json` there. Send its whole JSON output as `noslop`
in the close-out. Close out `passed`, or `changes-requested` with each finding as text.
