# luce-browser-engine

**Status and next steps** for the whole luce-browser port: [luce-js/docs/HANDOFF.md](https://github.com/dymokomi/luce-js/blob/main/docs/HANDOFF.md). Porting tools, oracles and the region brief: [luce-browser-tools](https://github.com/dymokomi/luce-browser-tools).


The web engine of the luce-browser port of Ladybird: DOM, HTML, CSS, SVG, layout and painting, in luce-base.

Part of the luce-browser family, a faithful port of Ladybird's LibWeb to luce-base; the design every
porter follows is [DESIGN.md](docs/DESIGN.md).

| Module | Contents |
| --- | --- |
| `web` | DOM, HTML, CSS, SVG, layout, painting |

Depends on: luce-std, luce-browser-foundation, luce-browser-css, luce-browser-html, luce-browser-render.

## Status

Skeleton: every type of the phase-1 closure is declared and every function has its generated
signature and a `trap("unported: ...")` body, grouped by region (`docs/regions.tsv`). Regions
replace their stub fragments with ported code (DESIGN.md §4.5). `docs/namemap.tsv` maps every C++
name to its Luce name; `docs/gc_fields.tsv` lists the GC pointer fields each cell must visit.

The skeleton is generated from Ladybird at `47c82b38d0` (see `PIN`) by a local tool that is not part
of this repository.

## Testing

`./test.sh` type-checks every module.

## License

BSD-2-Clause, as Ladybird; see `LICENSE`.
