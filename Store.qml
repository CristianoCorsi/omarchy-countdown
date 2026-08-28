// State of the countdown on disk.
//
// FileView is deliberately only a content-free change watcher. Every read and
// write crosses state_io.py, which opens the state file without following the
// final path, never blocks on special files, validates the same descriptor,
// and bounds the payload before it reaches JSON.parse() in this shell process.

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  visible: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string path: stateDir + "/countdown.json"
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("state_io.py"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  property var data: Model.normalize(null)
  property bool loaded: false
  property bool waitingForSafeFile: true
  property string lastError: ""
  property string readerResponse: ""
  property string readerError: ""
  property bool readQueued: false
  property int writeSerial: 0
  property int activeReadSerial: 0
  property string pendingWrite: ""
  property string activeWrite: ""
  property bool writeQueued: false
  property string writerResponse: ""
  property string writerError: ""

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
    lastError = ""
  }

  function responseObject(line) {
    var text = String(line || "")
    // The helper's output is already bounded. Keep an independent ceiling at
    // the process boundary so no unexpected helper output reaches JSON.parse().
    if (text.length === 0 || text.length > Model.MAX_STATE_BYTES * 2)
      return { status: "error", error: "invalid state helper response size" }
    try {
      var response = JSON.parse(text)
      if (!response || typeof response !== "object") throw new Error("not an object")
      return response
    } catch (error) {
      return { status: "error", error: "invalid state helper response" }
    }
  }

  function acceptReadResponse(line) {
    var response = responseObject(line)
    if (response.status === "ok") {
      apply(response.data)
      waitingForSafeFile = false
      return
    }
    if (response.status === "missing") {
      apply(null)
      waitingForSafeFile = true
      return
    }

    loaded = true
    waitingForSafeFile = true
    lastError = String(response.error || readerError || "secure state read failed")
    console.warn("cristianocorsi.countdown: state rejected:", lastError)
  }

  function requestRead() {
    if (reader.running) {
      readQueued = true
      return
    }
    activeReadSerial = writeSerial
    reader.running = true
  }

  function startWrite() {
    if (writer.running || pendingWrite === "") return
    activeWrite = pendingWrite
    writeQueued = false
    writer.running = true
  }

  // Every mutation is normalized before it enters the UI or the writer. Writes
  // are serialized; a newer mutation replaces any queued older payload.
  function commit(next) {
    var payload = Model.normalize(next)
    var encoded = JSON.stringify(payload)
    if (encoded.length > Model.MAX_STATE_BYTES) {
      saveFailed("state payload is too large")
      return false
    }

    data = payload
    pendingWrite = encoded
    writeSerial++
    if (writer.running) writeQueued = true
    else startWrite()
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
    if (count >= Model.MAX_COUNTDOWNS) {
      saveFailed("countdown limit reached")
      return false
    }
    var next = clone()
    next.countdowns.push(entry)
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

  Process {
    id: reader
    command: ["/usr/bin/python3", root.helperPath, "read", root.path]
    stdout: SplitParser { onRead: function(line) { root.readerResponse = line } }
    stderr: SplitParser { onRead: function(line) { root.readerError = line } }
    onStarted: {
      root.readerResponse = ""
      root.readerError = ""
    }
    onExited: function(code) {
      // Ignore a read that started before a local write. The writer's exact
      // post-rename read will become authoritative instead.
      if (root.activeReadSerial === root.writeSerial && !writer.running && !root.writeQueued)
        root.acceptReadResponse(root.readerResponse)
      if (root.readQueued) {
        root.readQueued = false
        Qt.callLater(root.requestRead)
      }
    }
  }

  Process {
    id: writer
    command: ["/usr/bin/python3", root.helperPath, "write", root.path]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.writerResponse = line } }
    stderr: SplitParser { onRead: function(line) { root.writerError = line } }
    onStarted: {
      root.writerResponse = ""
      root.writerError = ""
      write(root.activeWrite + "\n")
    }
    onExited: function(code) {
      var response = root.responseObject(root.writerResponse)
      if (code !== 0 || response.status !== "ok") {
        root.lastError = String(response.error || root.writerError || "secure state write failed")
        root.saveFailed(root.lastError)
        console.warn("cristianocorsi.countdown: save failed:", root.lastError)
      }

      if (root.writeQueued) Qt.callLater(root.startWrite)
      else Qt.callLater(root.requestRead)
    }
  }

  // QFileSystemWatcher remains useful for prompt cross-monitor updates, but it
  // must never load the watched object. Missing or rejected files are retried
  // by the timer until a safe regular file appears.
  FileView {
    id: stateWatcher
    path: root.path
    preload: false
    blockAllReads: true
    watchChanges: true
    printErrors: false
    onFileChanged: root.requestRead()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.waitingForSafeFile
    onTriggered: root.requestRead()
  }

  Component.onCompleted: requestRead()
}
