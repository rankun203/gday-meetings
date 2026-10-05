import CSQLite
import Foundation

extension IndexDatabase.Connection {
    func updateGuide() throws {
        guard let templateURL = Bundle.module.url(forResource: "index.db.template", withExtension: "md") else {
            throw IndexDatabase.DatabaseError(code: SQLITE_ERROR, message: "The index guide template is missing.")
        }
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let modules = try prepare("SELECT namespace,version FROM index_modules ORDER BY namespace")
        defer { release(modules) }
        var moduleLines = ["| Module | Version |", "| --- | --- |"]
        while sqlite3_step(modules) == SQLITE_ROW {
            moduleLines.append(
                "| \(String(cString: sqlite3_column_text(modules, 0))) | \(sqlite3_column_int(modules, 1)) |")
        }
        let schema = try prepare(
            "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND (type != 'table' OR name IN (SELECT name FROM index_module_tables) OR name IN ('index_modules','index_module_tables')) ORDER BY type,name"
        )
        defer { release(schema) }
        var declarations: [String] = []
        while sqlite3_step(schema) == SQLITE_ROW {
            declarations.append(String(cString: sqlite3_column_text(schema, 0)) + ";")
        }
        let content = template.replacingOccurrences(of: "{{MODULES}}", with: moduleLines.joined(separator: "\n"))
            .replacingOccurrences(of: "{{SCHEMA}}", with: declarations.joined(separator: "\n"))
        let destination = url.deletingLastPathComponent().appendingPathComponent("index.db.md")
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            let previous = try String(contentsOf: destination, encoding: .utf8)
            guard previous.contains("<!-- gday-generated-index-guide -->"), previous != content else { return }
            try Data(content.utf8).write(to: destination, options: .atomic)
        }
        else {
            try Data(content.utf8).write(to: destination, options: .withoutOverwriting)
        }
    }
}
