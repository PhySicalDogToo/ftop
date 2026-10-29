# Process ranking placement fix — 2026-10-20

## Reproduction and correction

Turning Network off and back on stores `cpu, memory, processes, network`.
The previous Scene builder kept that stored order, added GPU/power after Network,
and inserted DNS before Processes. This produced the owner's reported ordering:
CPU/memory → DNS → ranking → network/GPU/power.

SceneBuilder now keeps the relative order of basic modules, appends the GPU/power
readings and only then the process block, before splitting into columns. DNS
remains in the statistics column immediately before a same-column ranking.
Single and two-column layouts therefore put all basic information above the
ranking. Three-column and wide-ranking forms retain an independent process
column on the right. This affects every selected sort equally and requires no
migration or rewrite of user configuration. No sensor or network-setting path was
changed by this fix.

## Validation

- `scripts/check.sh`: strict formatting, warning-free build, two complete passes
  of 252 tests. The three new targeted tests also passed separately.
- Position regressions: 1,144 scene cases covering actual Config Network/Memory
  off/on actions, historical process-first/process-middle orders, all GPU/power/
  DNS visibility combinations, all four sorts, compact/full/detailed candidates,
  single/two/three columns, wide ranking and representative scales.
- Regenerated 153 native reference PNGs in `references/`: 16 dedicated legacy-
  order pictures across four forms, two languages and two appearances, plus the
  existing size references. All 16 dedicated pictures and seven existing size
  representatives were viewed. No remaining ranking-order, clipping or overlap
  issue was seen. README media regenerated successfully.
- An isolated release preview used the exact legacy module order. Actual drags
  covered regular three rows, seven-row single column, large single column,
  large two columns, tall/narrow and wide/thin forms. Same-column rankings
  followed all basic information. A further micro drag was interrupted by the
  native automation's windowNotFoundAtPosition error; real micro dragging is not
  claimed. Its regenerated image and automated bounds remain covered.
- `build/Ftop.app` (0.2.6, local build 11): deep strict code-signature verification
  and plist lint passed. No installation or publication. All temporary previews
  and their collector children were stopped after validation; existing installed
  copies and user/network configuration were left alone.

## Cost check

`performance.json` retains five sanitized interval samples for the visible,
regular download-ranking panel at 1 s refresh, including its helper. Combined
CPU was **0.9–1.7% of one core**, mean **1.24%**; summed `top MEM` was approximately
**30.1–31.2 MiB**. The under-1% reference CPU target remains unmet, as documented
for the prior network-ranking implementation. This short background-active run
is not a controlled before/after comparison or a worst-case bound. Memory is
`top MEM`, not independently measured RSS. An earlier zero-CPU attempt without
verified visibility is excluded. No additional network traffic probes were run.
