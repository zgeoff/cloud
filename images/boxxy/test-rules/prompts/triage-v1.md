Triage the item {{title}}.

{{ outcome }}
{%- if body %}

{{ body }}
{%- endif %}
{%- if acceptance %}

## Acceptance

{{ acceptance }}
{%- endif %}
{%- if notes %}

## Notes from the owner

{{ notes }}
{%- endif %}

Decide whether boxxy takes it on: close out `accepted`, `duplicate` with the other item, or
`declined` with the reason. An accepted item needs an acceptance list. Accept no criterion that only
a release or a live run can prove.

Start by running `boxxy attempt current`. It prints this attempt as JSON: the item, your input, the
owner's notes on the item, and `closeOut`, which holds the outcome names and the JSON Schema of the
close-out body. Do what the notes say. To cite a test or a check, record it with
`boxxy attempt evidence --kind <test|ci-run|live-check> --ref <what you checked>` and use the ID it
prints. Before you end, send the close-out body as JSON on stdin to `boxxy attempt close-out`. When
it prints problems, fix each one and send it again. The first valid close-out is final, and a
session that ends without one fails.
