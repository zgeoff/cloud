Build the item {{title}} to its design and acceptance list, and open a pull request.

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
{%- if findings %}

## Findings to answer

{{ findings }}
{%- endif %}
{%- if notes %}

## Notes from the owner

{{ notes }}
{%- endif %}

Add no attribution to a commit message, a pull request title or a pull request body: no
`Co-Authored-By` trailer, and no line that names the tool or the model that wrote the change.

Run the checks that the repo's own agent instructions name. Close out `built`, `blocked` with the
question the owner must answer, or `abandoned`.

Start by running `boxxy attempt current`. It prints this attempt as JSON: the item, your input, the
owner's notes on the item, and `closeOut`, which holds the outcome names and the JSON Schema of the
close-out body. Do what the notes say. To cite a test or a check, record it with
`boxxy attempt evidence --kind <test|ci-run|live-check> --ref <what you checked>` and use the ID it
prints. Before you end, send the close-out body as JSON on stdin to `boxxy attempt close-out`. When
it prints problems, fix each one and send it again. The first valid close-out is final, and a
session that ends without one fails.
