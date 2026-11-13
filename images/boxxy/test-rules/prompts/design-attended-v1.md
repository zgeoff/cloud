Design the item {{title}} with the owner, who works in this session with you.

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

Ask the owner what you need to know. When the owner is done, close out `designed` with the design,
`blocked` with the open question, or `abandoned`.

Start by running `boxxy attempt current`. It prints this attempt as JSON: the item, your input, the
owner's notes on the item, and `closeOut`, which holds the outcome names and the JSON Schema of the
close-out body. Do what the notes say. To cite a test or a check, record it with
`boxxy attempt evidence --kind <test|ci-run|live-check> --ref <what you checked>` and use the ID it
prints. Before you end, send the close-out body as JSON on stdin to `boxxy attempt close-out`. When
it prints problems, fix each one and send it again. The first valid close-out is final, and a
session that ends without one fails.
