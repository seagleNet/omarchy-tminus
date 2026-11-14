.pragma library

// The widget's plain logic, kept apart from the QML so tests/logic.test.mjs
// can run it under node: parsing what t- prints, and splitting what the user
// types. Nothing here starts processes or touches the shell.

// Lengths kept from anything t- reports: titles and labels are free text.
var MAX_CLOCK = 80
var MAX_TOOLTIP = 600
var MAX_TIMERS = 20
var MAX_SUGGESTIONS = 8
var MAX_ERROR = 300

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// `~/` at the start of the configured command: no shell sees it to expand it.
function expandHome(command, home) {
  var c = String(command || "").trim() || "t-"
  return c.indexOf("~/") === 0 && home ? home + c.slice(1) : c
}

// A `t- ctl status --follow` line: { state, clock, tooltip, name }, or null
// for anything that isn't one.
function parseStatus(line) {
  var data
  try {
    data = JSON.parse(line)
  } catch (e) {
    return null
  }
  if (!isPlainObject(data))
    return null
  return {
    state: String(data["class"] || "idle"),
    clock: String(data.text || "").slice(0, MAX_CLOCK),
    tooltip: String(data.tooltip || "").slice(0, MAX_TOOLTIP),
    name: typeof data.name === "string" ? data.name : ""
  }
}

// `t- ctl list --json`: the timers as model rows, or null if it isn't a list.
function parseTimerList(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!Array.isArray(data))
    return null
  var list = []
  for (var i = 0; i < data.length && list.length < MAX_TIMERS; i++) {
    var t = data[i]
    if (!isPlainObject(t) || typeof t.name !== "string" || t.name === "")
      continue
    list.push({
      name: t.name.slice(0, 60),
      timerState: String(t.state || "").slice(0, 20),
      clock: String(t.clock || "").slice(0, 20),
      title: String(t.title || "").slice(0, 80),
      segment: String(t.segment || "").slice(0, 20),
      headless: t.mode === "headless",
      pid: Math.max(0, Math.floor(Number(t.pid) || 0))
    })
  }
  return list
}

// Split t- arguments into words: whitespace separates them, and single or
// double quotes keep a title with spaces together (`-t "Tea break"`).
// Nothing else is special: the words go to t- as they are, never to a shell.
function words(line) {
  var out = []
  var word = ""
  var inWord = false
  var quote = ""
  var text = String(line || "")
  for (var i = 0; i < text.length; i++) {
    var c = text[i]
    if (quote) {
      if (c === quote)
        quote = ""
      else
        word += c
    } else if (c === '"' || c === "'") {
      quote = c
      inWord = true
    } else if (c === " " || c === "\t" || c === "\n") {
      if (inWord)
        out.push(word)
      word = ""
      inWord = false
    } else {
      word += c
      inWord = true
    }
  }
  if (inWord)
    out.push(word)
  return out
}

// Where the word being typed starts, or -1 inside an open quote (a title
// being typed has nothing to complete).
function currentWordStart(text) {
  var start = 0
  var quote = ""
  var s = String(text || "")
  for (var i = 0; i < s.length; i++) {
    var c = s[i]
    if (quote) {
      if (c === quote)
        quote = ""
    } else if (c === '"' || c === "'")
      quote = c
    else if (c === " " || c === "\t")
      start = i + 1
  }
  return quote ? -1 : start
}

// The arguments for `COMPLETE=fish t- -- t- <args>`: the words before the
// one being typed, then that word as it stands (maybe empty). Null inside
// an open quote.
function completionArgs(text) {
  var s = String(text || "")
  var start = currentWordStart(s)
  if (start < 0)
    return null
  var args = words(s.slice(0, start))
  args.push(s.slice(start))
  return args
}

// t-'s completion answer (`candidate<TAB>description` lines) as suggestions
// for the word being typed in `text`.
function parseSuggestions(text, raw) {
  var s = String(text || "")
  var word = s.slice(Math.max(0, currentWordStart(s)))
  var lines = String(raw || "").split("\n")
  var list = []
  for (var i = 0; i < lines.length && list.length < MAX_SUGGESTIONS; i++) {
    var tab = lines[i].indexOf("\t")
    var value = (tab < 0 ? lines[i] : lines[i].slice(0, tab)).slice(0, 80)
    var help = tab < 0 ? "" : lines[i].slice(tab + 1).slice(0, 300)
    if (value === "" || value === word)
      continue
    // Flags only once one is being typed; subcommands never start a timer.
    if (value[0] === "-" && word[0] !== "-")
      continue
    if (["ctl", "completions", "man", "help"].indexOf(value) !== -1)
      continue
    list.push({
      value: value,
      help: help
    })
  }
  return list
}

// The first line of t-'s complaint, without its `tminus: ` / `error: `, cut
// with an ellipsis if long; "" when it said nothing.
function errorLine(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim().replace(/^(tminus|error): */, "")
    if (line !== "")
      return line.length > MAX_ERROR ? line.slice(0, MAX_ERROR - 1) + "\u2026" : line
  }
  return ""
}
