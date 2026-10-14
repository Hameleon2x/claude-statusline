#!/usr/bin/env bash
# Claude Code subagent status line (agent panel rows under the prompt)
#   ● name/type  model [effort]  ctx:bar % (used/max)  time  · label
# Input: {"columns": N, "tasks": [...]} on stdin; output: one {"id","content"} JSON line per row.
# Requires: bash, jq

[ -n "$NO_COLOR" ] && nc=1 || nc=0

jq -c --argjson nc "$nc" '
  def c($code): if $nc == 1 then "" else "\u001b[" + $code + "m" end;
  def reset: c("0");
  def dim($s): c("2") + $s + reset;

  def human_tokens:
    if . >= 1000000 then "\(. / 100000 | floor / 10)M"
    elif . >= 1000 then "\(. / 1000 | floor)k"
    else tostring end;

  def human_duration:
    (. / 3600 | floor) as $h | ((. % 3600) / 60 | floor) as $m | (. % 60) as $s
    | if $h > 0 then "\($h)h\($m)m" elif $m > 0 then "\($m)m\($s)s" else "\($s)s" end;

  # same zones as the main status line: worst of percent and absolute tokens
  def level($pct; $tok):
    ([ (if $pct >= 85 then 3 elif $pct >= 70 then 2 elif $pct >= 50 then 1 else 0 end),
       (if $tok >= 500000 then 3 elif $tok >= 350000 then 2 elif $tok >= 200000 then 1 else 0 end) ] | max);

  def color($lvl): [c("32"), c("33"), c("31"), c("31")][$lvl];
  def text_color($lvl): [c("32"), c("33"), c("31"), c("1;97;41")][$lvl];

  def bar($pct; $w; $lvl):
    ([(($pct * $w + 50) / 100 | floor), $w] | min) as $f
    | color($lvl) + ([range($f)] | map("█") | join("")) + reset
      + dim([range($w - $f)] | map("░") | join(""));

  # "claude-opus-5-5[1m]" -> "opus-5.5"
  def short_model:
    sub("^claude-"; "") | sub("\\[.*\\]$"; "") | sub("-(?<a>[0-9]+)-(?<b>[0-9]+)$"; "-\(.a).\(.b)");

  def status_icon:
    { "running":   (c("33") + "●"),
      "completed": (c("32") + "✔"),
      "failed":    (c("31") + "✘"),
      "killed":    (c("2")  + "■") }[.] // (c("2") + "○");

  (now | floor) as $now
  | (.columns // 120) as $cols
  | .tasks[]?
  | . as $t
  | ($t.tokenCount // 0) as $tok
  | (if ($t.contextWindowSize // 0) > 0 then ($tok * 100 / $t.contextWindowSize | floor) else null end) as $pct
  | (($now - (($t.startTime // ($now * 1000)) / 1000 | floor)) | if . < 0 then 0 else . end) as $el
  | [
      ($t.status | status_icon) + reset,
      c("1") + ($t.name // $t.agentType // "agent") + reset,
      (if $t.model then dim(($t.model | short_model)
         + (if $t.effort then " [\($t.effort)]" else "" end)) else empty end),
      (if $pct != null then
         level($pct; $tok) as $l
         | dim("ctx:") + bar($pct; 6; $l) + " " + text_color($l) + "\($pct)%" + reset
           + dim(" (\($tok | human_tokens)/\($t.contextWindowSize | human_tokens))")
       else dim("\($tok | human_tokens) tok") end),
      dim($el | human_duration)
    ] as $parts
  | ($parts | join("  ")) as $head
  # label gets whatever width is left (ANSI codes do not take columns)
  | ($head | gsub("\u001b\\[[0-9;]*m"; "") | length) as $used
  | ($cols - $used - 4) as $room
  | ($t.label // $t.description // "") as $lbl
  | (if $room > 8 and ($lbl | length) > 0 then
       "  " + dim("· " + (if ($lbl | length) > $room then $lbl[0:$room - 1] + "…" else $lbl end))
     else "" end) as $tail
  | {id: $t.id, content: ($head + $tail)}
'
