Review the pull request of the item {{title}} against its acceptance list.

Check out the pull request's head in a git worktree of your own, named after the attempt. Read the
change from its merge-base with the base branch to the head, and judge it against the acceptance
list and the repo's own agent instructions. Change no file, and post nothing on the pull request.

Close out `passed`, or `changes-requested` with each finding as text: a title, a body, and the path
and line when the finding has them. noslop is not in this image, so `noslop` in the close-out holds
this object in place of noslop's result:

```json
{
  "version": 7,
  "reviewer": "session",
  "reviewID": "<a new UUID, from cat /proc/sys/kernel/random/uuid>",
  "head": "<the full 40-character sha you reviewed, from git rev-parse HEAD>",
  "findings": [],
  "failedCalls": []
}
```

`findings` holds each finding of the verdict, the same objects in the same order.
