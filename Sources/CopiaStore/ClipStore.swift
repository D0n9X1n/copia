import Foundation
import SQLite3
import CopiaCore

/// File operations the store performs, so tests can inject failures.
public protocol FileOps: Sendable {
	func write(_ data: Data, to url: URL) throws
	func move(_ from: URL, to: URL) throws
	func remove(_ url: URL) throws
	func exists(_ url: URL) -> Bool
	/// Throws when the folder cannot be read, so an unreadable folder never looks empty.
	func list(_ directory: URL) throws -> [URL]
}

public struct LiveFileOps: FileOps {
	public init() {}
	public func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
	/// rename(2): replaces the destination atomically, and leaves it alone when the source is missing, so moving a
	/// file that is not there never removes an undo copy already in trash. Every store move stays on one volume.
	public func move(_ from: URL, to: URL) throws {
		guard rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
	}
	/// Only "no such file" counts as done; any other failure (permissions, I/O) is reported.
	public func remove(_ url: URL) throws {
		do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
	}
	public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
	public func list(_ directory: URL) throws -> [URL] {
		try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
	}
}

public enum PreviewState: String, Sendable {
	case pending, ok, okNoImage, failed
}

public enum StoreError: Error, Equatable {
	case sqlite(String)
	case missingBlob
	case alreadyExists
	/// Erase cleared the history but could not remove this many files.
	case filesLeft(Int)
}

/// A stored clip as the store sees it.
public struct StoredClip: Equatable, Sendable {
	public var key: String
	public var kind: ClipKind
	public var title: String
	public var previewText: String
	public var isCode: Bool
	public var sourceBundle: String?
	public var sourceName: String?
	public var firstCopied: Date
	public var lastCopied: Date
	public var copyCount: Int
	public var byteSize: Int
	public var meta: String
	public var colorHex: String?
	public var url: String?
	public var fileNames: [String]
	public var previewState: PreviewState
	public var generation: Int
}

/// Everything needed to undo a delete.
public struct DeletedClip: Sendable {
	public let clip: StoredClip
	/// The clip had a thumbnail when it was deleted, so a restore without it must ask for a new preview.
	let hadThumbnail: Bool
}

/// History on disk: SQLite (WAL) with a trigram FTS index, plus blob and thumbnail files.
/// All writes go through this actor so rows and files stay consistent.
public actor ClipStore {
	public let directory: URL
	let files: FileOps
	private nonisolated(unsafe) var db: OpaquePointer?

	var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
	var thumbs: URL { directory.appendingPathComponent("thumbs", isDirectory: true) }
	var trash: URL { directory.appendingPathComponent("trash", isDirectory: true) }

	public init(directory: URL, files: FileOps = LiveFileOps()) throws {
		self.directory = directory
		self.files = files
		for dir in ["blobs", "thumbs", "trash"] {
			try FileManager.default.createDirectory(at: directory.appendingPathComponent(dir), withIntermediateDirectories: true)
		}
		var handle: OpaquePointer?
		guard sqlite3_open_v2(directory.appendingPathComponent("copia.sqlite").path, &handle,
			SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
		else { throw StoreError.sqlite("open failed") }
		db = handle
		try Self.exec(handle, """
			PRAGMA journal_mode=WAL;
			PRAGMA synchronous=NORMAL;
			CREATE TABLE IF NOT EXISTS clips (
				id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, preview_text TEXT NOT NULL,
				is_code INTEGER NOT NULL, source_bundle TEXT, source_name TEXT,
				first_copied REAL NOT NULL, last_copied REAL NOT NULL, copy_count INTEGER NOT NULL,
				byte_size INTEGER NOT NULL, meta TEXT NOT NULL, color_hex TEXT, url TEXT, file_names TEXT NOT NULL,
				preview_state TEXT NOT NULL, generation INTEGER NOT NULL);
			CREATE INDEX IF NOT EXISTS clips_last ON clips(last_copied DESC);
			CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(id UNINDEXED, title, preview_text, tokenize='trigram');
			CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
			""")
	}

	deinit { sqlite3_close(db) }

	// MARK: Paths

	func blobURL(_ key: String) -> URL { blobs.appendingPathComponent("\(key).plist") }
	func thumbURL(_ key: String) -> URL { thumbs.appendingPathComponent("\(key).png") }
	func trashURL(_ key: String, _ ext: String) -> URL { trash.appendingPathComponent("\(key).\(ext)") }
	public func thumbnail(for key: String) -> URL? {
		let url = thumbURL(key)
		return files.exists(url) ? url : nil
	}

	// MARK: Insert

	/// Stores a draft. A recopy moves the existing row to the front, bumps its count and keeps its payload.
	@discardableResult
	public func insert(_ draft: ClipDraft) throws -> (clip: StoredClip, isNew: Bool) {
		let key = draft.contentKey
		if var existing = try fetch(key) {
			existing.lastCopied = draft.copiedAt
			existing.copyCount += 1
			try run("UPDATE clips SET last_copied=?, copy_count=? WHERE id=?",
				[.real(draft.copiedAt.timeIntervalSince1970), .int(existing.copyCount), .text(key)])
			return (existing, false)
		}
		let text = Capture.plainText(draft)
		let kind = Capture.kind(of: draft)
		let fileURLs = Capture.fileURLs(draft)
		let url = Capture.webURL(text)
		let fileNames = fileURLs.map(\.lastPathComponent)
		let title: String = switch kind {
		case .file: fileNames.count == 1 ? fileNames[0] : "\(fileNames.count) files"
		case .color: Capture.colorHex(text) ?? text
		case .link: url?.absoluteString ?? text
		case .image: "Image"
		default: String(text.prefix(600))
		}
		let clip = StoredClip(key: key, kind: kind, title: title, previewText: String((text + " " + fileNames.joined(separator: " ")).prefix(4_000)),
			isCode: kind == .text && Capture.looksLikeCode(text), sourceBundle: draft.sourceBundleID, sourceName: draft.sourceName,
			firstCopied: draft.copiedAt, lastCopied: draft.copiedAt, copyCount: 1, byteSize: draft.byteSize,
			meta: Capture.meta(kind: kind, text: text, files: fileURLs, byteSize: draft.byteSize, url: url,
				image: kind == .image ? Capture.imageData(draft) : nil),
			colorHex: kind == .color ? Capture.colorHex(text) : nil, url: url?.absoluteString, fileNames: fileNames,
			previewState: [.image, .link, .file].contains(kind) ? .pending : .ok, generation: try nextGeneration())
		try files.write(Self.encode(draft.items), to: blobURL(key))
		do {
			try insertRow(clip)
		} catch {
			try? files.remove(blobURL(key))
			throw error
		}
		// A recopy of a deleted item ends its undo, so its trashed files go once the new copy is saved.
		for ext in ["plist", "png"] { try? files.remove(trashURL(key, ext)) }
		return (clip, true)
	}

	// MARK: Preview

	/// Saves a preview only if `generation` still matches, so a late result never lands on a deleted or recopied clip.
	@discardableResult
	public func setPreview(key: String, generation: Int, state: PreviewState, title: String? = nil, image: Data? = nil) throws -> Bool {
		guard let current = try fetch(key), current.generation == generation else { return false }
		if let image { try files.write(image, to: thumbURL(key)) }
		try transaction {
			try run("UPDATE clips SET preview_state=?, title=COALESCE(?, title) WHERE id=?",
				[.text(state.rawValue), title.map { .text($0) } ?? .null, .text(key)])
			if let title {
				try run("UPDATE clips_fts SET title=? WHERE id=?", [.text(title), .text(key)])
			}
		}
		return true
	}

	// MARK: Delete, restore, prune, erase

	/// Moves the clip's files to trash for undo, then removes the row and FTS entry in one transaction.
	/// Either all of it happens or nothing does: a failed move or row delete puts the moved files back and throws.
	/// A file that cannot move back stays in trash under its live row; `emptyTrash`, `removeOrphans` and `sweep`
	/// move it home before they remove anything.
	public func delete(_ key: String) throws -> DeletedClip? {
		guard let clip = try fetch(key) else { return nil }
		var moved: [(file: URL, trashed: URL)] = []
		do {
			for (file, trashed) in [(blobURL(key), trashURL(key, "plist")), (thumbURL(key), trashURL(key, "png"))] {
				do {
					try files.move(file, to: trashed)
					moved.append((file, trashed))
				} catch let error where Self.isNoSuchFile(error) && !files.exists(file) {
					// Only a file that is really not there is skipped: no thumbnail yet, or a blob already in trash.
					// A file the store cannot reach fails with a permission error and fails the delete.
				}
			}
			try transaction {
				try run("DELETE FROM clips WHERE id=?", [.text(key)])
				try run("DELETE FROM clips_fts WHERE id=?", [.text(key)])
			}
		} catch {
			for (file, trashed) in moved.reversed() { try? files.move(trashed, to: file) }
			throw error
		}
		return DeletedClip(clip: clip, hadThumbnail: moved.contains { $0.file == thumbURL(key) })
	}

	/// Puts a deleted clip back. Either the row and its files all return, or nothing changes.
	/// A thumbnail lost from trash comes back as a pending preview, so the app asks for it again.
	public func restore(_ deleted: DeletedClip) throws {
		let key = deleted.clip.key
		guard try fetch(key) == nil else { throw StoreError.alreadyExists }
		let trashedBlob = trashURL(key, "plist")
		let trashedThumb = trashURL(key, "png")
		guard files.exists(trashedBlob) else { throw StoreError.missingBlob }
		try files.move(trashedBlob, to: blobURL(key))
		var movedThumb = false
		do {
			if files.exists(trashedThumb) { try files.move(trashedThumb, to: thumbURL(key)); movedThumb = true }
			try insertRestored(deleted, thumbnailHome: movedThumb)
		} catch {
			let failure = error
			do {
				try files.move(blobURL(key), to: trashedBlob)
			} catch {
				// The blob cannot go back to trash. It is home, so finish the restore rather than leave a blob without a
				// row for cleanup to delete; a thumbnail that did not come home is asked for again.
				if (try? insertRestored(deleted, thumbnailHome: movedThumb)) != nil { return }
				// shortcut: if the database also refuses this insert, the blob stays home without a row and the next
				// cleanup removes it as an orphan. Closing that needs cleanup to spare home files of keys still in undo.
				throw failure
			}
			if movedThumb { try? files.move(thumbURL(key), to: trashedThumb) }
			throw failure
		}
	}

	/// Inserts a restored clip's row with a new generation. A thumbnail it had that is not home makes its preview pending.
	private func insertRestored(_ deleted: DeletedClip, thumbnailHome: Bool) throws {
		var clip = deleted.clip
		if deleted.hadThumbnail, !thumbnailHome { clip.previewState = .pending }
		clip.generation = try nextGeneration()
		try insertRow(clip)
	}

	/// Best effort: trash only holds undo copies of items already deleted.
	/// A trash file whose row is still live is moved home, never removed. If the live rows or the trash cannot be
	/// read, nothing is removed.
	public func emptyTrash() {
		guard let keys = try? Set(strings("SELECT id FROM clips", [])), let listed = try? files.list(trash) else { return }
		emptyTrash(listed, live: keys)
	}

	/// Moves each trash file whose key has a live row back to its empty home path, then removes every other trash
	/// file. A file whose move home fails stays in trash; returns the keys whose blob is still there.
	@discardableResult
	private func emptyTrash(_ listed: [URL], live keys: Set<String>) -> Set<String> {
		var kept = Set<URL>(), stuckBlobs = Set<String>()
		for url in listed {
			let key = url.deletingPathExtension().lastPathComponent
			let home: URL? = switch url.pathExtension {
			case "plist": blobURL(key)
			case "png": thumbURL(key)
			default: nil
			}
			// A home copy that already exists is the live one; the trash copy is redundant and goes below.
			guard keys.contains(key), let home, !files.exists(home) else { continue }
			kept.insert(url)
			do { try files.move(url, to: home) } catch { if url.pathExtension == "plist" { stuckBlobs.insert(key) } }
		}
		for url in listed where !kept.contains(url) { try? files.remove(url) }
		return stuckBlobs
	}

	/// Deletes clips last copied before `cutoff`, with their FTS entries and files.
	@discardableResult
	public func prune(before cutoff: Date) throws -> Int {
		let keys = try strings("SELECT id FROM clips WHERE last_copied < ?", [.real(cutoff.timeIntervalSince1970)])
		guard !keys.isEmpty else { return 0 }
		try transaction {
			for key in keys {
				try run("DELETE FROM clips WHERE id=?", [.text(key)])
				try run("DELETE FROM clips_fts WHERE id=?", [.text(key)])
			}
		}
		for key in keys {
			try? files.remove(blobURL(key))
			try? files.remove(thumbURL(key))
		}
		return keys.count
	}

	/// Clears every row, then every file. A file that cannot be removed is reported, not hidden.
	public func eraseAll() throws {
		try transaction {
			try run("DELETE FROM clips", [])
			try run("DELETE FROM clips_fts", [])
		}
		var left = 0
		for dir in [blobs, thumbs, trash] {
			guard let urls = try? files.list(dir) else { left += 1; continue }
			for url in urls {
				do { try files.remove(url) } catch { left += 1 }
			}
		}
		if left > 0 { throw StoreError.filesLeft(left) }
	}

	/// The hourly pass: moves a live row's files home from trash (a delete whose rollback failed), then removes blob
	/// and thumbnail files that have no row, left by a prune or erase whose removal failed. Undo copies in trash stay.
	public func removeOrphans() throws {
		let keys = Set(try strings("SELECT id FROM clips", []))
		emptyTrash(((try? files.list(trash)) ?? []).filter { keys.contains($0.deletingPathExtension().lastPathComponent) }, live: keys)
		for url in try files.list(blobs) + files.list(thumbs) where !keys.contains(url.deletingPathExtension().lastPathComponent) {
			try? files.remove(url)
		}
	}

	/// Launch cleanup: move live rows' files home from trash, empty trash, drop files without rows and rows without blobs.
	/// Rows are dropped only for blobs a successful listing shows are absent; a folder that cannot be read stops the sweep.
	public func sweep() throws {
		let keys = Set(try strings("SELECT id FROM clips", []))
		// A blob that still cannot move home is in trash, not lost: its row stays.
		let stuck = emptyTrash(try files.list(trash), live: keys)
		let blobFiles = try files.list(blobs), thumbFiles = try files.list(thumbs)
		for url in blobFiles + thumbFiles where !keys.contains(url.deletingPathExtension().lastPathComponent) {
			try? files.remove(url)
		}
		let present = Set(blobFiles.map { $0.deletingPathExtension().lastPathComponent }).union(stuck)
		let missing = keys.subtracting(present)
		if !missing.isEmpty {
			try transaction {
				for key in missing {
					try run("DELETE FROM clips WHERE id=?", [.text(key)])
					try run("DELETE FROM clips_fts WHERE id=?", [.text(key)])
					try? files.remove(thumbURL(key))
				}
			}
		}
		try run("DELETE FROM clips_fts WHERE id NOT IN (SELECT id FROM clips)", [])
	}

	// MARK: Read

	/// Every clip, newest first. History is bounded by retention, not by a count.
	public func recent() throws -> [StoredClip] {
		try query("SELECT * FROM clips ORDER BY last_copied DESC", [])
	}

	public func fetch(_ key: String) throws -> StoredClip? {
		try query("SELECT * FROM clips WHERE id=?", [.text(key)]).first
	}

	public func pending() throws -> [StoredClip] {
		try query("SELECT * FROM clips WHERE preview_state='pending' ORDER BY last_copied DESC", [])
	}

	/// The stored pasteboard items, for pasting.
	public func items(for key: String) throws -> [PasteboardItemData] {
		guard let data = try? Data(contentsOf: blobURL(key)) else { throw StoreError.missingBlob }
		return try Self.decode(data)
	}

	/// Substring search: FTS5 trigram for 3+ characters, LIKE for shorter queries. Returns keys, newest first.
	public func search(_ text: String) throws -> [String] {
		let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !q.isEmpty else { return try strings("SELECT id FROM clips ORDER BY last_copied DESC", []) }
		if q.count >= 3 {
			let phrase = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
			return try strings("""
				SELECT c.id FROM clips_fts f JOIN clips c ON c.id = f.id
				WHERE clips_fts MATCH ? ORDER BY c.last_copied DESC
				""", [.text(phrase)])
		}
		let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
			.replacingOccurrences(of: "_", with: "\\_") + "%"
		return try strings("""
			SELECT id FROM clips WHERE title LIKE ?1 ESCAPE '\\' OR preview_text LIKE ?1 ESCAPE '\\'
			ORDER BY last_copied DESC
			""", [.text(like)])
	}

	// MARK: Rows

	func insertRow(_ c: StoredClip) throws {
		try transaction {
			try run("""
				INSERT INTO clips (id, kind, title, preview_text, is_code, source_bundle, source_name, first_copied, last_copied,
				copy_count, byte_size, meta, color_hex, url, file_names, preview_state, generation)
				VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
				""", [.text(c.key), .text(c.kind.rawValue), .text(c.title), .text(c.previewText), .int(c.isCode ? 1 : 0),
				c.sourceBundle.map { .text($0) } ?? .null, c.sourceName.map { .text($0) } ?? .null,
				.real(c.firstCopied.timeIntervalSince1970), .real(c.lastCopied.timeIntervalSince1970), .int(c.copyCount),
				.int(c.byteSize), .text(c.meta), c.colorHex.map { .text($0) } ?? .null, c.url.map { .text($0) } ?? .null,
				.text(c.fileNames.joined(separator: "\n")), .text(c.previewState.rawValue), .int(c.generation)])
			try run("INSERT INTO clips_fts (id, title, preview_text) VALUES (?,?,?)", [.text(c.key), .text(c.title), .text(c.previewText)])
		}
	}

	private func nextGeneration() throws -> Int {
		try run("INSERT INTO meta (key, value) VALUES ('generation', 1) ON CONFLICT(key) DO UPDATE SET value = value + 1", [])
		return Int(try strings("SELECT value FROM meta WHERE key='generation'", []).first ?? "1") ?? 1
	}

	// MARK: Blob encoding

	static func encode(_ items: [PasteboardItemData]) throws -> Data {
		let plist: [[[Any]]] = items.map { $0.representations.map { [$0.type, $0.data] } }
		return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
	}

	static func decode(_ data: Data) throws -> [PasteboardItemData] {
		guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[[Any]]] else {
			throw StoreError.missingBlob
		}
		return plist.map { item in
			PasteboardItemData(item.compactMap { pair in
				guard pair.count == 2, let type = pair[0] as? String, let data = pair[1] as? Data else { return nil }
				return (type: type, data: data)
			})
		}
	}

	// MARK: SQLite helpers

	enum Value { case text(String), int(Int), real(Double), null }

	private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
		var error: UnsafeMutablePointer<CChar>?
		guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
			let message = error.map { String(cString: $0) } ?? "exec failed"
			sqlite3_free(error)
			throw StoreError.sqlite(message)
		}
	}

	private var inTransaction = false
	private var stepFault = false
	private var writeFault = false

	/// Tests: the next read step fails as SQLite would on a busy or damaged database.
	func failNextStep() { stepFault = true }

	/// Tests: the next write statement fails, so its transaction rolls back.
	func failNextWrite() { writeFault = true }

	/// Only "no such file" means a file is absent; a permission or I/O failure does not.
	static func isNoSuchFile(_ error: Error) -> Bool {
		if let e = error as? POSIXError { return e.code == .ENOENT }
		if let e = error as? CocoaError { return e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile }
		return false
	}

	/// Tests: every id in the FTS table, read directly (search joins on `clips`, so it would hide a leftover entry).
	func ftsKeys() throws -> [String] { try strings("SELECT id FROM clips_fts", []) }

	/// Steps a read. Any result but a row or the end throws, so a failed read never looks like an empty one.
	private func nextRow(_ statement: OpaquePointer?) throws -> Bool {
		let code = stepFault ? SQLITE_IOERR : sqlite3_step(statement)
		stepFault = false
		if code == SQLITE_ROW { return true }
		guard code == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errstr(code))) }
		return false
	}

	func transaction(_ body: () throws -> Void) throws {
		if inTransaction { return try body() }
		try Self.exec(db, "BEGIN IMMEDIATE")
		inTransaction = true
		do {
			try body()
			inTransaction = false
			try Self.exec(db, "COMMIT")
		} catch {
			inTransaction = false
			try? Self.exec(db, "ROLLBACK")
			throw error
		}
	}

	private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
			throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
		}
		let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
		for (i, value) in values.enumerated() {
			let index = Int32(i + 1)
			switch value {
			case let .text(s): sqlite3_bind_text(statement, index, s, -1, transient)
			case let .int(n): sqlite3_bind_int64(statement, index, Int64(n))
			case let .real(d): sqlite3_bind_double(statement, index, d)
			case .null: sqlite3_bind_null(statement, index)
			}
		}
		return statement
	}

	private func run(_ sql: String, _ values: [Value]) throws {
		if writeFault { writeFault = false; throw StoreError.sqlite("injected write fault") }
		let statement = try prepare(sql, values)
		defer { sqlite3_finalize(statement) }
		guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
	}

	private func strings(_ sql: String, _ values: [Value]) throws -> [String] {
		let statement = try prepare(sql, values)
		defer { sqlite3_finalize(statement) }
		var result: [String] = []
		while try nextRow(statement) {
			result.append(String(cString: sqlite3_column_text(statement, 0)))
		}
		return result
	}

	private func query(_ sql: String, _ values: [Value]) throws -> [StoredClip] {
		let statement = try prepare(sql, values)
		defer { sqlite3_finalize(statement) }
		var result: [StoredClip] = []
		func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
		while try nextRow(statement) {
			result.append(StoredClip(
				key: text(0) ?? "", kind: ClipKind(rawValue: text(1) ?? "") ?? .text, title: text(2) ?? "",
				previewText: text(3) ?? "", isCode: sqlite3_column_int(statement, 4) != 0, sourceBundle: text(5), sourceName: text(6),
				firstCopied: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
				lastCopied: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
				copyCount: Int(sqlite3_column_int64(statement, 9)), byteSize: Int(sqlite3_column_int64(statement, 10)),
				meta: text(11) ?? "", colorHex: text(12), url: text(13),
				fileNames: (text(14) ?? "").split(separator: "\n").map(String.init),
				previewState: PreviewState(rawValue: text(15) ?? "") ?? .failed, generation: Int(sqlite3_column_int64(statement, 16))))
		}
		return result
	}
}
