# Diagrams

Source is [D2](https://d2lang.com/), rendered with the hand-drawn (`--sketch`)
style. The `.svg` files are committed so the docs render on GitHub with no build
step — edit the `.d2`, re-render, and commit both.

| Diagram | Answers |
|---|---|
| [01-request-path](01-request-path.svg) | How does a call reach a model, and where do auth and quota apply? |
| [02-gitops-flow](02-gitops-flow.svg) | What happens between editing a values file and a model serving? |
| [03-health-model](03-health-model.svg) | What is Argo CD telling me, and when do I need to act? |
| [04-model-weights](04-model-weights.svg) | Where do the weights come from, and how do credentials reach the download? |

## Regenerating

```bash
./docs/diagrams/render.sh
```

Requires `d2`:

```bash
go install oss.terrastruct.com/d2@latest
```

`get.d2lang.com` may be blocked by egress policy on a locked-down network;
`proxy.golang.org` usually is not, which is why the Go install is the documented
route.

## One authoring gotcha

D2 lays a markdown note out at its natural width. If that comes out wider than
the diagram itself, the right-hand side is **silently cut off** — the text is
still in the SVG source, so grepping for it proves nothing, and neither `d2` nor
any linter reports it.

Keep each paragraph short. Blank lines separate paragraphs; single newlines are
joined into one long line, so hand-wrapping a long sentence does not help.

Check the rendered result before committing. In a headless environment:

```bash
SVG=docs/diagrams/02-gitops-flow.svg
SIZE=$(grep -o 'viewBox="0 0 [0-9]* [0-9]*"' "$SVG" | head -1 | grep -oE '[0-9]+ [0-9]+"$' | tr -d '"')
chromium --headless --disable-gpu --no-sandbox --hide-scrollbars \
  --screenshot=/tmp/diagram.png --window-size=$(echo $SIZE | tr ' ' ',') "file://$PWD/$SVG"
```
