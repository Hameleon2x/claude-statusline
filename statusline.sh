#!/usr/bin/env bash
# Claude Code status line
#   model [effort] ⚡ | folder | ctx:bar %  (used/max) | 5ч:bar % ×pace (reset [runout]) · 7д:bar % ×pace (reset [runout])
# Input: session JSON on stdin (see https://code.claude.com/docs/en/statusline)
# Requires: bash 4+, jq

input=$(cat)

# --- thresholds (override via env) ---

# context: level is the worst of "percent of window" and "absolute tokens".
# Percent catches the 200k window running into auto-compact (~93%);
# tokens soften 1M windows: 400k/600k/800k (40/60/80%) — no official threshold exists.
CTX_WARN_PCT=${CTX_WARN_PCT:-50}            # yellow: time to /compact soon
CTX_HIGH_PCT=${CTX_HIGH_PCT:-70}            # red: compact now
CTX_CRIT_PCT=${CTX_CRIT_PCT:-85}            # critical: auto-compact is about to fire
CTX_WARN_TOK=${CTX_WARN_TOK:-400000}
CTX_HIGH_TOK=${CTX_HIGH_TOK:-600000}
CTX_CRIT_TOK=${CTX_CRIT_TOK:-800000}

# rate limits: pace = current burn rate / sustainable rate (what's left ÷ time left), ×100
PACE_WARN=${PACE_WARN:-100}                 # yellow: at this pace you hit the limit before reset
PACE_HIGH=${PACE_HIGH:-150}                 # red
PACE_CRIT=${PACE_CRIT:-250}                 # critical (also: limit ≥ 95% used)

# --- colors ---

ESC=$'\033'
C_RESET="${ESC}[0m"
C_DIM="${ESC}[38;5;240m"
C_GREEN="${ESC}[38;5;71m"
C_YELLOW="${ESC}[38;5;208m"                 # orange: reads better than yellow on light themes
C_RED="${ESC}[38;5;196m"
C_MODEL="${ESC}[38;5;111m"
C_DIR="${ESC}[38;5;180m"
C_CRIT="${ESC}[1;97;48;5;160m"              # bold white on red background
if [ -n "$NO_COLOR" ]; then
  C_RESET="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED="" C_MODEL="" C_DIR="" C_CRIT=""
fi

# level 0..3 -> $COL (bar color) and $TXT (percent text color)
level_color() {
  case "$1" in
    0) COL="$C_GREEN"  TXT="$C_GREEN" ;;
    1) COL="$C_YELLOW" TXT="$C_YELLOW" ;;
    2) COL="$C_RED"    TXT="$C_RED" ;;
    *) COL="$C_RED"    TXT="$C_CRIT" ;;
  esac
}

# value -> level by three ascending thresholds
level_of() {
  local v="$1"
  if   (( v >= $4 )); then echo 3
  elif (( v >= $3 )); then echo 2
  elif (( v >= $2 )); then echo 1
  else                     echo 0
  fi
}

# --- helpers ---

# bar <pct> <width> <level>
bar() {
  local p="$1" width="$2" filled empty out=""
  filled=$(( (p * width + 50) / 100 ))
  (( filled < 0 ))     && filled=0
  (( filled > width )) && filled=$width
  empty=$(( width - filled ))
  level_color "$3"
  out="$COL"
  while (( filled-- > 0 )); do out+="█"; done
  out+="${C_RESET}${C_DIM}"
  while (( empty--  > 0 )); do out+="░"; done
  out+="$C_RESET"
  printf '%s' "$out"
}

human_tokens() {
  local t="$1"
  case "$t" in ''|*[!0-9]*) return ;; esac
  if   (( t >= 1000000 )); then
    if (( t % 1000000 < 100000 )); then printf '%dM' $(( t / 1000000 ))
    else printf '%d.%dM' $(( t / 1000000 )) $(( (t % 1000000) / 100000 ))
    fi
  elif (( t >= 1000 )); then printf '%dk' $(( t / 1000 ))
  else                       printf '%d' "$t"
  fi
}

human_duration() {
  local s="$1" d h m
  case "$s" in ''|*[!0-9]*) return ;; esac
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   (( d > 0 )); then printf '%dд %dч' "$d" "$h"
  elif (( h > 0 )); then printf '%dч %dм' "$h" "$m"
  elif (( m > 0 )); then printf '%dм' "$m"
  else                   printf '%dс' "$s"
  fi
}

# rate_part <label> <used%> <pace×100> <seconds to reset>
rate_part() {
  local label="$1" pct="$2" pace="$3" left="$4" lvl b pace_str="" cd="" runout=""
  [ -z "$pct" ] && return
  lvl=$(level_of "${pace:-0}" "$PACE_WARN" "$PACE_HIGH" "$PACE_CRIT")
  (( pct >= 95 )) && lvl=3
  (( pct >= 80 && lvl < 2 )) && lvl=2
  b=$(bar "$pct" 6 "$lvl")
  level_color "$lvl"
  # show the multiplier only when burning faster than sustainable,
  # plus how long the remainder lasts at this pace: (100 - used) / rate = left / pace
  if [ -n "$pace" ] && (( pace >= PACE_WARN )); then
    printf -v pace_str ' %s×%d.%d%s' "$TXT" $(( pace / 100 )) $(( pace % 100 / 10 )) "$C_RESET"
    if [ -n "$left" ] && (( pct < 100 )); then
      runout="${C_RESET} ${TXT}[$(human_duration $(( left * 100 / pace )))]${C_RESET}${C_DIM}"
    fi
  fi
  [ -n "$left" ] && cd=" ${C_DIM}($(human_duration "$left")${runout})${C_RESET}"
  printf '%s%s:%s%s %s%d%%%s%s%s' "$C_DIM" "$label" "$C_RESET" "$b" "$TXT" "$pct" "$C_RESET" "$pace_str" "$cd"
}

# --- extract fields + compute pace (single jq pass) ---
# pace = (used / elapsed) / ((100 - used) / left), elapsed clamped so the first minutes aren't noise

mapfile -t F < <(jq -r '
  def pace($w; $minel):
    if . == null or .used_percentage == null or .resets_at == null then ["", "", ""]
    else
      (.used_percentage | floor) as $u
      | ((.resets_at | tonumber) - now | floor) as $left
      | if $left <= 0 then ["", "", ""]
        else
          ([($w - $left), $minel] | max) as $el
          | (if $u >= 100 then 99900
             elif $u <= 0 then 0
             else (($u / $el) / ((100 - $u) / $left) * 100 | floor) end) as $p
          | [$u, ([$p, 99900] | min), $left]
        end
    end;
  [
    (.model.display_name // .model.id // "unknown"),
    (.effort.level // ""),
    (if .thinking.enabled == false then "off" else "" end),
    (if .fast_mode == true then "on" else "" end),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // ""),
    (.context_window.context_window_size // "")
  ]
  + (.rate_limits.five_hour | pace(18000; 900))
  + (.rate_limits.seven_day | pace(604800; 21600))
  + [((.workspace.current_dir // .cwd // "") | gsub("\\\\"; "/") | sub("/+$"; "") | split("/") | last // "")]
  | .[] | tostring' <<< "$input")

# jq on Windows emits CRLF — strip the trailing \r from every field
CR=$'\r'
F=("${F[@]%"$CR"}")

model="${F[0]:-unknown}"
effort="${F[1]}"
thinking_off="${F[2]}"
fast="${F[3]}"
ctx_used="${F[4]}"
ctx_cur="${F[5]}"
ctx_max="${F[6]}"
sess_pct="${F[7]}"  sess_pace="${F[8]}"  sess_left="${F[9]}"
week_pct="${F[10]}" week_pace="${F[11]}" week_left="${F[12]}"
dir="${F[13]}"

# --- build parts ---

# 1. Model + effort + fast mode. "(1M context)" is dropped — the context part shows the size anyway.
model="${model% (*context)}"
model_part="${C_MODEL}${model}${C_RESET}"
if [ -n "$thinking_off" ]; then
  model_part+=" ${C_DIM}[no think]${C_RESET}"
elif [ -n "$effort" ]; then
  model_part+=" ${C_DIM}[${effort}]${C_RESET}"
fi
[ -n "$fast" ] && model_part+=" ${C_YELLOW}⚡${C_RESET}"

# 2. Project folder
dir_part=""
[ -n "$dir" ] && dir_part="${C_DIR}${dir}${C_RESET}"

# 3. Context: bar + % + (used/max). Critical gets a red badge with a hint.
ctx_part=""
if [ -n "$ctx_used" ]; then
  printf -v ctx_p '%.0f' "$ctx_used"
  lvl=$(level_of "$ctx_p" "$CTX_WARN_PCT" "$CTX_HIGH_PCT" "$CTX_CRIT_PCT")
  case "$ctx_cur" in ''|*[!0-9]*) ;; *)
    tl=$(level_of "$ctx_cur" "$CTX_WARN_TOK" "$CTX_HIGH_TOK" "$CTX_CRIT_TOK")
    (( tl > lvl )) && lvl=$tl ;;
  esac
  ctx_bar=$(bar "$ctx_p" 10 "$lvl")
  level_color "$lvl"
  ctx_abs=""
  if [ -n "$ctx_cur" ] && [ -n "$ctx_max" ]; then
    ctx_abs=" ${C_DIM}($(human_tokens "$ctx_cur")/$(human_tokens "$ctx_max"))${C_RESET}"
  fi
  if (( lvl >= 3 )); then
    ctx_pct_str="${TXT} ⚠ ${ctx_p}% /compact ${C_RESET}"
  else
    ctx_pct_str="${TXT}${ctx_p}%${C_RESET}"
  fi
  ctx_part="${C_DIM}ctx:${C_RESET}${ctx_bar} ${ctx_pct_str}${ctx_abs}"
fi

# 4. Rate limits: 5h + 7d, colored by pace
sess_str=$(rate_part "5ч" "$sess_pct" "$sess_pace" "$sess_left")
week_str=$(rate_part "7д" "$week_pct" "$week_pace" "$week_left")
limits_part="$sess_str"
if [ -n "$week_str" ]; then
  [ -n "$limits_part" ] && limits_part+=" ${C_DIM}·${C_RESET} "
  limits_part+="$week_str"
fi

# --- assemble ---

sep="  ${C_DIM}|${C_RESET}  "
out=""
for part in "$model_part" "$dir_part" "$ctx_part" "$limits_part"; do
  [ -z "$part" ] && continue
  if [ -z "$out" ]; then out="$part"; else out+="${sep}${part}"; fi
done

echo "$out"
