import Foundation

extension IndexDatabase.Module {
    static let library = Self(
        namespace: "core_library", version: 3,
        tables: [
            .init(
                name: "meetings",
                definition:
                    "(id TEXT PRIMARY KEY,created REAL NOT NULL,sortTime REAL NOT NULL,title TEXT NOT NULL,metadata BLOB NOT NULL)"
            ),
            .init(
                name: "relations",
                definition:
                    "(meeting TEXT NOT NULL,kind TEXT NOT NULL,target TEXT NOT NULL,sortTime REAL NOT NULL,PRIMARY KEY(meeting,kind,target))"
            ),
            .init(name: "index_state", definition: "(id INTEGER PRIMARY KEY CHECK(id=1),complete INTEGER NOT NULL)"),
            .init(name: "meeting_folders", definition: "(id TEXT PRIMARY KEY,name TEXT NOT NULL)"),
            .init(
                name: "search_locations",
                definition:
                    "(id INTEGER PRIMARY KEY AUTOINCREMENT,meeting TEXT NOT NULL,source TEXT NOT NULL,revision TEXT NOT NULL,UNIQUE(meeting,source))"
            ),
            .init(
                name: "search_passages",
                definition: "USING fts5(meeting UNINDEXED,kind UNINDEXED,segment UNINDEXED,start UNINDEXED,text)",
                virtual: true, copiedColumns: "rowid,meeting,kind,segment,start,text"),
        ],
        indexes:
            "CREATE INDEX IF NOT EXISTS meeting_seek ON meetings(sortTime,id); CREATE INDEX IF NOT EXISTS relation_seek ON relations(kind,target,sortTime,meeting); CREATE INDEX IF NOT EXISTS search_location_meeting ON search_locations(meeting)",
        initialValues: "INSERT OR IGNORE INTO index_state VALUES(1,0)", legacyVersion: 3, retiredTables: ["search"])

    static let directory = Self(
        namespace: "core_directory", version: 1,
        tables: [
            .init(
                name: "entities",
                definition:
                    "(kind TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,excluded INTEGER NOT NULL,PRIMARY KEY(kind,id))"
            ),
            .init(name: "person_tags", definition: "(person TEXT NOT NULL,tag TEXT NOT NULL,PRIMARY KEY(person,tag))"),
            .init(name: "state", definition: "(id INTEGER PRIMARY KEY,complete INTEGER NOT NULL)"),
        ],
        indexes: "CREATE INDEX IF NOT EXISTS entity_name ON entities(kind,name COLLATE GDAY_NAME,id)",
        initialValues: "INSERT OR IGNORE INTO state VALUES(1,0)")

    static let tasks = Self(
        namespace: "core_tasks", version: 2,
        tables: [
            .init(
                name: "task_offsets",
                definition:
                    "(id TEXT PRIMARY KEY,created REAL NOT NULL,state TEXT NOT NULL,kind TEXT NOT NULL,meeting TEXT NOT NULL,priority INTEGER NOT NULL,offset INTEGER NOT NULL,length INTEGER NOT NULL,digest TEXT NOT NULL)"
            ),
            .init(name: "journal_revision", definition: "(id INTEGER PRIMARY KEY,revision TEXT,committed INTEGER)"),
        ],
        indexes:
            "CREATE INDEX IF NOT EXISTS task_history ON task_offsets(created DESC,id DESC); CREATE INDEX IF NOT EXISTS task_state ON task_offsets(state,created DESC,id DESC); CREATE INDEX IF NOT EXISTS task_queue ON task_offsets(kind,state,priority DESC,created,id); CREATE INDEX IF NOT EXISTS task_meeting ON task_offsets(meeting,kind,created DESC,id DESC)",
        initialValues: "")
}
