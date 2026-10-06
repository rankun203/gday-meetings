"""Instrument an isolated app source tree for fresh-process measurements."""
import argparse
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("client", type=Path, help="Isolated apps/client-macos-swift directory")
parser.add_argument("--task-guards-only", action="store_true", help="Add guards to an already instrumented copy")
args = parser.parse_args()
root = args.client / "Sources/GdayMeetings"
if "tmp" not in args.client.resolve().parts:
    raise SystemExit("Use an isolated checkout under tmp; do not instrument production sources.")
shutil.copyfile(Path(__file__).with_name("startup_probe.swift"), root / "StartupProbe.swift")

def replace(file, before, after):
    path = root / file
    text = path.read_text()
    if text.count(before) != 1:
        raise SystemExit(f"Expected exactly one marker in {file}: {before!r}")
    path.write_text(text.replace(before, after))

if not args.task_guards_only:
    replace("Core/UIPreview.swift", "guard enabled else {", 'StartupProbe.mark("store-start")\n        guard enabled else {')
    replace("Core/UIPreview.swift", "            return store\n", '            StartupProbe.mark("store-ready")\n            return store\n')
    replace("GdayMeetingsApp.swift", "                    delegate.store = store", '                    StartupProbe.windowAppeared()\n                    delegate.store = store')
    replace("Core/SemanticSearchIndex.swift", "        self.directory = directory\n", '        StartupProbe.mark("index-open-start")\n        self.directory = directory\n')
    replace("Core/SemanticSearchIndex.swift", "        try connection.register(Self.module)", '        try connection.register(Self.module)\n        StartupProbe.mark("index-open-end")')
    replace("Core/LocalSearchController.swift", "            try await result.prepare()", '            StartupProbe.mark("model-prepare-start")\n            try await result.prepare()\n            StartupProbe.mark("model-prepare-end")')
    replace("Core/LocalSearchController.swift", "            isReady = true", '            isReady = true\n            StartupProbe.mark("search-ready")')
    replace("Services/SemanticEmbedding.swift", "                let acquired = try await manager.acquireInstalled(id: modelID.localID)", '                StartupProbe.mark("model-acquire-start")\n                let acquired = try await manager.acquireInstalled(id: modelID.localID)\n                StartupProbe.mark("model-acquire-end")')
    replace("Services/SemanticEmbedding.swift", "                    let tokenizer = try await AutoTokenizer.from(modelFolder: acquired.directory)", '                    let tokenizer = try await AutoTokenizer.from(modelFolder: acquired.directory)\n                    StartupProbe.mark("tokenizer-ready")')
    replace("Services/SemanticEmbedding.swift", "                    return (acquired, tokenizer)", '                    StartupProbe.mark("warmup-complete")\n                    return (acquired, tokenizer)')
    replace("UI/LibraryView.swift", "        guard !query.isEmpty else { return }", '        guard !query.isEmpty else { return }\n        StartupProbe.mark("query-submit")')
    replace("UI/LibrarySearchResultsView.swift", "                announced = true", '                announced = true\n                StartupProbe.mark("results-layout-complete")')

for file, anchor in [
    ("Core/LocalSearchController.swift", "    func scheduleSearchIndexing(rebuild: Bool = false) {"),
    ("Core/ManagedTasks.swift", "    func prepareManagedTasks() async {"),
    ("Core/ManagedTasks.swift", "    func recoverUnfinishedManagedTasksCommand() async {"),
    ("Core/ManagedTasks.swift", "    func reloadExternalManagedTasksCommand() async {"),
    ("Core/ManagedTasks.swift", "    private func startManagedTasks() async {"),
]:
    replace(file, anchor, anchor + '\n        guard Bundle.main.object(forInfoDictionaryKey: "GdayStartupDisableTasks") as? Bool != true else { return }')
replace("Core/MeetingStore.swift", '            if FileManager.default.fileExists(atPath: self.dataDirectory.appendingPathComponent("tasks.jsonl").path) {',
        '            if Bundle.main.object(forInfoDictionaryKey: "GdayStartupDisableTasks") as? Bool != true, FileManager.default.fileExists(atPath: self.dataDirectory.appendingPathComponent("tasks.jsonl").path) {')
print("Instrumented isolated sources; no query or meeting content is recorded.")
