Review the pull request of the item {{title}} against its acceptance list.

{{ outcome }}
{%- if body %}

{{ body }}
{%- endif %}
{%- if acceptance %}

## Acceptance

{{ acceptance }}
{%- endif %}
{%- if design %}

## Design

{{ design }}
{%- endif %}
{%- if notes %}

## Notes from the owner

{{ notes }}
{%- endif %}

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

Start by running `boxxy attempt current`. It prints this attempt as JSON: the item, your input, the
owner's notes on the item, and `closeOut`, which holds the outcome names and the JSON Schema of the
close-out body. Do what the notes say. To cite a test or a check, record it with
`boxxy attempt evidence --kind <test|ci-run|live-check> --ref <what you checked>` and use the ID it
prints. Before you end, send the close-out body as JSON on stdin to `boxxy attempt close-out`. When
it prints problems, fix each one and send it again. The first valid close-out is final, and a
session that ends without one fails.
