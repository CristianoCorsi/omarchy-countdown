// State of the countdown on disk.
//
// The file is watched (watchChanges) and re-read on every modification: the bar
// exists once per monitor, so each screen has its own instance of the
// widget and its Store. By routing every write through the file, a
// change made by one panel reaches the other screens on its own, without
// having to notify them manually.

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  visible: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  property string path: stateDir + "/countdown.json"

  property var data: Model.normalize(null)
  property bool loaded: false
  property bool dirReady: false

  readonly property var entries: data && data.countdowns ? data.countdowns : []
  readonly property int count: entries.length
  readonly property int currentIndex: {
    var i = data && data.state ? Number(data.state.current_index) : 0
    return (i >= 0 && i < count) ? i : 0
  }
  readonly property var current: count > 0 ? entries[currentIndex] : null

  signal saveFailed(string reason)

  function apply(raw) {
    data = Model.normalize(raw)
    loaded = true
  }

  function parse(text) {
    try {
      apply(JSON.parse(String(text)))
    } catch (e) {
      // A corrupt file must not make the widget disappear: it restarts from a
      // valid empty state and the first write puts it right.
      console.warn("cristianocorsi.countdown: unreadable state, restarting from empty:", e)
      apply(null)
    }
  }

  // Every mutation passes through here: it normalizes, writes, and lets the
  // watcher sync `data` back — so that what is in memory is always what
  // is on disk.
  function commit(next) {
    if (!dirReady) {
      saveFailed("state directory not ready")
      return false
    }
    var payload = Model.normalize(next)
    data = payload
    file.setText(JSON.stringify(payload, null, 2) + "\n")
    return true
  }

  function clone() {
    return JSON.parse(JSON.stringify(data))
  }

  function setIndex(index) {
    var next = clone()
    next.state.current_index = index
    return commit(next)
  }

  function cycle(delta) {
    if (count <= 1) return false
    return setIndex(Model.cycleIndex(currentIndex, count, delta))
  }

  function addEntry(entry) {
    var next = clone()
    next.countdowns.push(entry)
    // Jump immediately to the newly created entry: it is the one being
    // viewed, and it is the only way to see it without scrolling.
    next.state.current_index = next.countdowns.length - 1
    return commit(next)
  }

  function updateEntry(index, entry) {
    if (index < 0 || index >= count) return false
    var next = clone()
    next.countdowns[index] = entry
    return commit(next)
  }

  function removeEntry(index) {
    if (index < 0 || index >= count) return false
    var next = clone()
    next.countdowns.splice(index, 1)
    if (next.state.current_index >= next.countdowns.length) next.state.current_index = 0
    return commit(next)
  }

  function moveEntry(index, delta) {
    var target = index + (delta < 0 ? -1 : 1)
    if (index < 0 || index >= count || target < 0 || target >= count) return false
    var next = clone()
    var moved = next.countdowns.splice(index, 1)[0]
    next.countdowns.splice(target, 0, moved)
    if (next.state.current_index === index) next.state.current_index = target
    return commit(next)
  }

  // FileView cannot write to a directory that does not exist, and
  // ~/.local/state/omarchy is not there on a fresh installation.
  Process {
    id: ensureDir
    running: true
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(code) {
      root.dirReady = code === 0
      if (root.dirReady) file.reload()
      else root.saveFailed("unable to create " + root.stateDir)
    }
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.parse(text())
    // File absent on first startup: empty state, and the first addition creates it.
    onLoadFailed: root.apply(null)
    onFileChanged: reload()
  }
}
