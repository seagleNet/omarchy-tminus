// Tests for Logic.js, the widget's plain logic: `node --test tests`.
// The inputs are what t- prints (copied from tminus 0.4), so no t- is needed.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

// Load Logic.js as QML does: one shared scope. Its first line is QML's
// `.pragma library`, which isn't JavaScript.
const source = readFileSync(new URL("../Logic.js", import.meta.url), "utf8")
const Logic = {}
vm.runInNewContext(source.replace(/^\.pragma library\s*$/m, ""), Logic)

// Values made in the other context compare by structure, not prototype.
const plain = value => JSON.parse(JSON.stringify(value))

test("words split on whitespace and keep quoted titles together", () => {
  assert.deepEqual(plain(Logic.words("10m:tea")), ["10m:tea"])
  assert.deepEqual(plain(Logic.words("  25m:work  5m:break x4 ")), ["25m:work", "5m:break", "x4"])
  assert.deepEqual(plain(Logic.words('@pomodoro -t "Deep work"')), ["@pomodoro", "-t", "Deep work"])
  assert.deepEqual(plain(Logic.words("-t 'Tea' 5m")), ["-t", "Tea", "5m"])
  assert.deepEqual(plain(Logic.words('-t "" 5m')), ["-t", "", "5m"])
  assert.deepEqual(plain(Logic.words("a\tb\nc")), ["a", "b", "c"])
  assert.deepEqual(plain(Logic.words("")), [])
})

test("shell syntax stays plain words", () => {
  // The words go to t- as arguments, never to a shell.
  assert.deepEqual(plain(Logic.words("; touch /tmp/foobar")), [";", "touch", "/tmp/foobar"])
  assert.deepEqual(plain(Logic.words('"$(id)" | rm -rf ~')), ["$(id)", "|", "rm", "-rf", "~"])
})

test("the word being typed, and none inside an open quote", () => {
  assert.equal(Logic.currentWordStart("25m@n"), 0)
  assert.equal(Logic.currentWordStart("5m --th"), 3)
  assert.equal(Logic.currentWordStart("5m --theme "), 11)
  assert.equal(Logic.currentWordStart('5m -t "Tea'), -1)
  assert.deepEqual(plain(Logic.completionArgs("5m --theme ")), ["5m", "--theme", ""])
  assert.deepEqual(plain(Logic.completionArgs("@po")), ["@po"])
  assert.equal(Logic.completionArgs('5m -t "Tea'), null)
})

test("suggestions from t-'s completion", () => {
  const themes = "tokyo-night\tOmarchy\ncatppuccin\tOmarchy\ncatppuccin-latte\tOmarchy\n"
  // t- filters by what was typed; this keeps its order and drops nothing here.
  assert.deepEqual(plain(Logic.parseSuggestions("5m --theme ", themes)).map(s => s.value),
                   ["tokyo-night", "catppuccin", "catppuccin-latte"])
  assert.deepEqual(plain(Logic.parseSuggestions("@", "@pomodoro\t25m:work 5m:break x3\n")),
                   [{ value: "@pomodoro", help: "25m:work 5m:break x3" }])
  // After a bare word t- offers its subcommands and every flag: none of
  // them starts a timer unless a flag is being typed.
  const empty = "ctl\tWatch and control\nman\tPrint the man page\n--until\tCount down to a time\n"
  assert.deepEqual(plain(Logic.parseSuggestions("5m ", empty)), [])
  assert.deepEqual(plain(Logic.parseSuggestions("5m --u", "--until\tCount down to a time\n")).map(s => s.value),
                   ["--until"])
  // The word already typed in full isn't offered again.
  assert.deepEqual(plain(Logic.parseSuggestions("--theme", "--theme\tColor theme\n")), [])
  // At most eight.
  const many = Array.from({ length: 20 }, (_, i) => `t${i}\tOmarchy`).join("\n")
  assert.equal(Logic.parseSuggestions("--theme ", many).length, 8)
})

test("t-'s error, first line, without its prefix", () => {
  assert.equal(Logic.errorLine("tminus: no preset `nope` (available: pomodoro)\n"),
               "no preset `nope` (available: pomodoro)")
  // clap's errors come with usage lines after them.
  assert.equal(Logic.errorLine("error: unexpected argument '--bogus' found\n\nUsage: t- [OPTIONS]\n"),
               "unexpected argument '--bogus' found")
  assert.equal(Logic.errorLine(""), "")
  const long = Logic.errorLine("tminus: unknown theme " + "x".repeat(400))
  assert.equal(long.length, 300)
  assert.ok(long.endsWith("\u2026"))
})

test("status lines", () => {
  const line = '{"text":"work 12:34","tooltip":"work\\nsegment 1/8\\nname: pomodoro","class":"alert",' +
               '"alt":"alert","percentage":51,"name":"pomodoro"}'
  assert.deepEqual(plain(Logic.parseStatus(line)),
                   { state: "alert", clock: "work 12:34", tooltip: "work\nsegment 1/8\nname: pomodoro", name: "pomodoro" })
  // No timer: t- prints this without a name.
  assert.deepEqual(plain(Logic.parseStatus('{"text":"","tooltip":"no timer running","class":"idle"}')),
                   { state: "idle", clock: "", tooltip: "no timer running", name: "" })
  assert.equal(Logic.parseStatus("not json"), null)
  assert.equal(Logic.parseStatus("[1, 2]"), null)
  assert.equal(Logic.parseStatus('{"text":"' + "9".repeat(500) + '"}').clock.length, 80)
})

test("the timer list", () => {
  const raw = '[{"name":"tea","pid":4242,"mode":"headless","state":"paused","clock":"04:00","title":"Tea",' +
              '"segment":"2/2","default":true},{"name":"focus","pid":17,"mode":"window","state":"running",' +
              '"clock":"24:59","title":"","segment":"","default":false}]'
  assert.deepEqual(plain(Logic.parseTimerList(raw)), [
    { name: "tea", timerState: "paused", clock: "04:00", title: "Tea", segment: "2/2", headless: true, pid: 4242 },
    { name: "focus", timerState: "running", clock: "24:59", title: "", segment: "", headless: false, pid: 17 },
  ])
  assert.deepEqual(plain(Logic.parseTimerList("[]")), [])
  assert.equal(Logic.parseTimerList("no running timer"), null)
  // Rows without a name are left out; a pid is only ever a whole number.
  assert.deepEqual(plain(Logic.parseTimerList('[{"pid":1},{"name":"x","pid":"12; rm"}]')).map(t => [t.name, t.pid]),
                   [["x", 0]])
  assert.equal(Logic.parseTimerList(JSON.stringify(Array.from({ length: 30 }, (_, i) => ({ name: `t${i}` })))).length, 20)
})

test("~/ in the command", () => {
  assert.equal(Logic.expandHome("~/.cargo/bin/t-", "/home/me"), "/home/me/.cargo/bin/t-")
  assert.equal(Logic.expandHome("t-", "/home/me"), "t-")
  assert.equal(Logic.expandHome("  ", "/home/me"), "t-")
  assert.equal(Logic.expandHome(null, "/home/me"), "t-")
})
