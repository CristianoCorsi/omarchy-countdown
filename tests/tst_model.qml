import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "CountdownModelSecurity"

  function entry(label) {
    return {
      label: label || "Release 1.0",
      start: "2030-01-01",
      end: "2030-03-31",
      format: "days"
    }
  }

  function test_normalizeBoundsRecordCount() {
    var records = []
    for (var i = 0; i < Model.MAX_COUNTDOWNS + 10; i++) records.push(entry("Item " + i))
    var normalized = Model.normalize({ state: { current_index: 999 }, countdowns: records })
    compare(normalized.countdowns.length, Model.MAX_COUNTDOWNS)
    compare(normalized.state.current_index, 0)
  }

  function test_normalizeBoundsAndCleansLabel() {
    var hostile = "<b>" + "x".repeat(Model.MAX_LABEL_LENGTH + 20) + "\n"
    var normalized = Model.normalize({ state: {}, countdowns: [entry(hostile)] })
    verify(normalized.countdowns[0].label.length <= Model.MAX_LABEL_LENGTH)
    verify(normalized.countdowns[0].label.indexOf("\n") === -1)
  }

  function test_escapeMarkupForAutoTextBoundary() {
    compare(Model.escapeMarkup("<b>R&D</b>"), "&lt;b&gt;R&amp;D&lt;/b&gt;")
  }

  function test_validateRejectsOversizedLabel() {
    var value = entry("x".repeat(Model.MAX_LABEL_LENGTH + 1))
    compare(Model.validate(value), "Label is too long")
  }

  function test_validateRejectsControlCharacters() {
    var value = entry("Release\nInjected")
    compare(Model.validate(value), "Label must be a single line")
  }
}
