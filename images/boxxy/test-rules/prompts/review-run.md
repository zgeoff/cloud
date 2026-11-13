Run the review tool on the pull request of this item. You judge nothing: the server checks the
tool's result, posts it and reads the open findings.

# {{ title }}

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

The attempt's input, as JSON, holds the review round and the command to run:

{{ input }}

In the folder the session starts in, run the input's `command` exactly as it is given. The folder is
a clone of the repo, and the command fetches the pull request's base and head itself, with the
read-only token that this session holds as `GH_TOKEN`. The command writes the tool's result to
`noslop-review.json`. Send that file unchanged as the close-out:
`boxxy attempt close-out < noslop-review.json`. Never edit the file, and never write a close-out of
your own.

When `command` is null, the item has no pull request: end the session with no close-out. When the
close-out fails with an error that is not a refusal, send the same file again. The first recorded
close-out is final.
