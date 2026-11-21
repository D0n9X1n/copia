import Foundation
import CryptoKit
import SQLite3
import CopiaCore

/// File operations the store performs, so tests can inject failures.
public protocol FileOps: Sendable {
	func read(_ url: URL) throws -> Data
	func write(_ data: Data, to url: URL) throws
	func copy(_ from: URL, to: URL) throws
	func remove(_ url: URL) throws
	func exists(_ url: URL) -> Bool
	/// Throws when the folder cannot be read, so an unreadable folder never looks empty.
	func list(_ directory: URL) throws -> [URL]
}

public extension FileOps {
	func read(_ url: URL) throws -> Data { try Data(contentsOf: url, options: .mappedIfSafe) }
}

public struct LiveFileOps: FileOps {
	public init() {}
	public func read(_ url: URL) throws -> Data { try Data(contentsOf: url, options: .mappedIfSafe) }
	public func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
	public func copy(_ from: URL, to: URL) throws {
		guard from != to else { return }
		try read(from).write(to: to, options: .atomic)
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
	case missingThumbnail
	case alreadyExists
	case outcomeUnknown
	case undoExpired
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
	/// A saved thumbnail is required to restore this exact snapshot.
	let hadThumbnail: Bool
	public let token: UUID
	public let issuedSequence: UInt64
}

/// History on disk: SQLite (WAL) with a trigram FTS index, plus blob and thumbnail files.
/// All writes go through this actor so rows and files stay consistent.
public actor ClipStore {
	public let directory: URL
	let files: FileOps
	private nonisolated(unsafe) var db: OpaquePointer?
	private var undos: [UUID: DeletedClip] = [:]
	private var issuedSequence: UInt64 = 0

	public private(set) var recoveryRequired = false
	private var cleanupDebt = false
	/// Cached warning. Only startup or a complete successful cleanup scan can clear it.
	public var cleanupPending: Bool { cleanupDebt }

	var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
	var thumbs: URL { directory.appendingPathComponent("thumbs", isDirectory: true) }
	var trash: URL { directory.appendingPathComponent("trash", isDirectory: true) }

	public init(directory: URL, files: FileOps = LiveFileOps()) throws {
		self.files = files
		for dir in ["blobs", "thumbs", "trash"] {
			try FileManager.default.createDirectory(at: directory.appendingPathComponent(dir), withIntermediateDirectories: true)
		}
		guard let canonical = realpath(directory.path, nil) else {
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		self.directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
		free(canonical)
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
		cleanupDebt = Self.initialCleanupDebt(db: handle, directory: self.directory, files: files)
	}

	/// Actor initialization has no undo tokens. Inspect just ownership columns, not full clip payload metadata.
	private static func initialCleanupDebt(db: OpaquePointer?, directory: URL, files: FileOps) -> Bool {
		do {
			let listed = try ["blobs", "thumbs", "trash"].flatMap { try files.list(directory.appendingPathComponent($0, isDirectory: true)) }
			let paths = Set(listed.map(\.path))
			var owned = Set<String>(), missingBlob = false
			var statement: OpaquePointer?
			guard sqlite3_prepare_v2(db, "SELECT id, preview_state FROM clips", -1, &statement, nil) == SQLITE_OK else { return true }
			defer { sqlite3_finalize(statement) }
			while true {
				let result = sqlite3_step(statement)
				if result == SQLITE_DONE { break }
				guard result == SQLITE_ROW else { return true }
				let key = String(cString: sqlite3_column_text(statement, 0))
				let state = String(cString: sqlite3_column_text(statement, 1))
				let blob = directory.appendingPathComponent("blobs/\(key).plist").path
				owned.insert(blob)
				missingBlob = missingBlob || !paths.contains(blob)
				if state == PreviewState.ok.rawValue || state == PreviewState.okNoImage.rawValue {
					owned.insert(directory.appendingPathComponent("thumbs/\(key).png").path)
				}
			}
			return missingBlob || !paths.isSubset(of: owned)
		} catch { return true }
	}

	deinit { sqlite3_close(db) }

	// MARK: Paths

	func blobURL(_ key: String) -> URL { blobs.appendingPathComponent("\(key).plist") }
	func thumbURL(_ key: String) -> URL { thumbs.appendingPathComponent("\(key).png") }
	func trashURL(_ key: String, _ ext: String) -> URL { trash.appendingPathComponent("\(key).\(ext)") }
	func snapshotURL(_ deleted: DeletedClip, _ ext: String) -> URL {
		trash.appendingPathComponent("\(deleted.clip.key).\(deleted.token.uuidString).\(ext)")
	}

	/// Only an actual ENOENT permits fallback. Permission/I/O errors must not masquerade as absence.
	private func readIfPresent(_ url: URL) throws -> Data? {
		do { return try files.read(url) } catch where Self.isNoSuchFile(error) { return nil }
	}

	private func liveBlob(_ key: String) throws -> (url: URL, data: Data) {
		let home = blobURL(key)
		if let data = try readIfPresent(home) { return (home, data) }
		let legacy = trashURL(key, "plist")
		if let data = try readIfPresent(legacy) { cleanupDebt = true; return (legacy, data) }
		cleanupDebt = true
		throw StoreError.missingBlob
	}

	public func thumbnail(for key: String) -> URL? {
		guard !recoveryRequired, let clip = try? fetch(key), ownsThumbnail(clip) else { return nil }
		let url = thumbURL(key)
		return files.exists(url) ? url : nil
	}

	private func ownsThumbnail(_ clip: StoredClip) -> Bool {
		clip.previewState == .ok || clip.previewState == .okNoImage
	}

	// MARK: Insert

	/// Stores a draft. A recopy moves the existing row to the front, bumps its count and keeps its payload.
	@discardableResult
	public func insert(_ draft: ClipDraft) throws -> (clip: StoredClip, isNew: Bool) {
		let key = draft.contentKey
		if var existing = try fetch(key) {
			let blob = try liveBlob(key).url
			existing.lastCopied = draft.copiedAt
			existing.copyCount += 1
			try transaction(keys: [key], validFiles: { self.files.exists(blob) }) {
				try run("UPDATE clips SET last_copied=?, copy_count=? WHERE id=?",
					[.real(draft.copiedAt.timeIntervalSince1970), .int(existing.copyCount), .text(key)])
			}
			expireUndos(for: key)
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
		var clip = StoredClip(key: key, kind: kind, title: title, previewText: String((text + " " + fileNames.joined(separator: " ")).prefix(4_000)),
			isCode: kind == .text && Capture.looksLikeCode(text), sourceBundle: draft.sourceBundleID, sourceName: draft.sourceName,
			firstCopied: draft.copiedAt, lastCopied: draft.copiedAt, copyCount: 1, byteSize: draft.byteSize,
			meta: Capture.meta(kind: kind, text: text, files: fileURLs, byteSize: draft.byteSize, url: url,
				image: kind == .image ? Capture.imageData(draft) : nil),
			colorHex: kind == .color ? Capture.colorHex(text) : nil, url: url?.absoluteString, fileNames: fileNames,
			previewState: [.image, .link, .file].contains(kind) ? .pending : .ok, generation: 0)
		try removeUnownedThumbnail(key)
		do {
			try writeAtomically(Self.encode(draft.items), to: blobURL(key))
			try transaction(keys: [key], validFiles: { self.files.exists(self.blobURL(key)) }) {
				clip.generation = try nextGeneration()
				try insertRow(clip)
			}
		} catch {
			cleanup([blobURL(key)])
			throw error
		}
		// A recopy of a deleted item ends its undo, so its trashed files go once the new copy is saved.
		expireUndos(for: key)
		return (clip, true)
	}

	// MARK: Preview

	/// Saves a preview only if `generation` still matches, so a late result never lands on a deleted or recopied clip.
	@discardableResult
	public func setPreview(key: String, generation: Int, state: PreviewState, title: String? = nil, image: Data? = nil) throws -> Bool {
		guard let current = try fetch(key), current.generation == generation else { return false }
		guard state != .pending else { return false }
		if current.previewState != .pending {
			guard state == current.previewState, image == nil else { return false }
		}
		let blob = try liveBlob(key).url
		var staged: [URL] = []
		do {
			if !ownsThumbnail(current) { try removeUnownedThumbnail(key) }
			if let image {
				staged.append(thumbURL(key))
				try writeAtomically(image, to: thumbURL(key))
			}
			try transaction(keys: [key], validFiles: { self.files.exists(blob) && (image == nil || self.files.exists(self.thumbURL(key))) }) {
				try run("UPDATE clips SET preview_state=?, title=COALESCE(?, title) WHERE id=?",
					[.text(state.rawValue), title.map { .text($0) } ?? .null, .text(key)])
				if let title { try run("UPDATE clips_fts SET title=? WHERE id=?", [.text(title), .text(key)]) }
			}
		} catch {
			cleanup(staged)
			throw error
		}
		if state == .failed, image != nil { cleanup(staged) }
		return true
	}

	// MARK: Delete, restore, prune, erase

	/// Stages undo copies before removing either the row or its authoritative files.
	public func delete(_ key: String) throws -> DeletedClip? {
		guard let clip = try fetch(key) else { return nil }
		let source = try liveBlob(key).url
		let hadThumbnail = try ownsThumbnail(clip) && readIfPresent(thumbURL(key)) != nil
		let deleted = DeletedClip(clip: clip, hadThumbnail: hadThumbnail, token: UUID(), issuedSequence: issuedSequence + 1)
		var staged: [URL] = []
		do {
			try stage(source, to: snapshotURL(deleted, "plist"), staged: &staged)
			if hadThumbnail { try stage(thumbURL(key), to: snapshotURL(deleted, "png"), staged: &staged) }
			try transaction(keys: [key], validFiles: {
				self.files.exists(self.snapshotURL(deleted, "plist")) && (!hadThumbnail || self.files.exists(self.snapshotURL(deleted, "png")))
			}) {
				try run("DELETE FROM clips WHERE id=?", [.text(key)])
				try run("DELETE FROM clips_fts WHERE id=?", [.text(key)])
			}
		} catch {
			cleanup(staged)
			throw error
		}
		issuedSequence = deleted.issuedSequence
		undos[deleted.token] = deleted
		cleanup([source, thumbURL(key)])
		return deleted
	}

	/// Copies the snapshot home before publishing its row. A failure never consumes the snapshot.
	@discardableResult
	public func restore(_ deleted: DeletedClip) throws -> StoredClip {
		try checkAvailable()
		guard let saved = undos[deleted.token], saved.clip.key == deleted.clip.key,
			saved.issuedSequence == deleted.issuedSequence else { throw StoreError.undoExpired }
		let key = saved.clip.key
		guard try fetch(key) == nil else { throw StoreError.alreadyExists }
		guard try readIfPresent(snapshotURL(saved, "plist")) != nil else { cleanupDebt = true; throw StoreError.missingBlob }
		if saved.hadThumbnail, try readIfPresent(snapshotURL(saved, "png")) == nil { cleanupDebt = true; throw StoreError.missingThumbnail }
		try removeUnownedThumbnail(key)
		var staged: [URL] = []
		var clip = saved.clip
		do {
			try stage(snapshotURL(saved, "plist"), to: blobURL(key), staged: &staged)
			if saved.hadThumbnail { try stage(snapshotURL(saved, "png"), to: thumbURL(key), staged: &staged) }
			try transaction(keys: [key], validFiles: {
				self.files.exists(self.blobURL(key)) && (!saved.hadThumbnail || self.files.exists(self.thumbURL(key)))
			}) {
				clip.generation = try nextGeneration()
				try insertRow(clip)
			}
		} catch {
			cleanup(staged)
			throw error
		}
		invalidateUndo(saved)
		return clip
	}

	/// A failed atomic write can leave a temporary file even when its destination was never published.
	private func writeAtomically(_ data: Data, to url: URL) throws {
		do { try files.write(data, to: url) } catch { cleanupDebt = true; throw error }
	}

	private func stage(_ source: URL, to target: URL, staged: inout [URL]) throws {
		guard source != target else { return }
		staged.append(target)
		do { try files.copy(source, to: target) } catch { cleanupDebt = true; throw error }
	}

	private func removeUnownedThumbnail(_ key: String) throws {
		do { try files.remove(thumbURL(key)) } catch { cleanupDebt = true; throw error }
	}

	private func expireUndos(for key: String) {
		for deleted in undos.values.filter({ $0.clip.key == key }) { invalidateUndo(deleted) }
	}

	/// Invalidates exactly this handle, even when unlinking its files fails.
	public func invalidateUndo(_ deleted: DeletedClip) {
		guard !recoveryRequired, let saved = undos[deleted.token], saved.clip.key == deleted.clip.key else { return }
		undos.removeValue(forKey: deleted.token)
		cleanup([snapshotURL(saved, "plist"), snapshotURL(saved, "png")])
	}

	/// Nil ends every undo; a cutoff never consumes a deletion issued after the close began.
	public func emptyTrash(through cutoff: UInt64? = nil) {
		guard !recoveryRequired else { return }
		let recoverDebt = cleanupDebt
		let expired = undos.values.filter { deleted in cutoff.map { deleted.issuedSequence <= $0 } ?? true }
		for deleted in expired { undos.removeValue(forKey: deleted.token) }
		if recoverDebt {
			try? removeOrphans()
		} else {
			cleanup(expired.flatMap { [snapshotURL($0, "plist"), snapshotURL($0, "png")] })
		}
	}

	/// Deletes clips last copied before `cutoff`, with their FTS entries and files.
	@discardableResult
	public func prune(before cutoff: Date) throws -> Int {
		let keys = try strings("SELECT id FROM clips WHERE last_copied < ?", [.real(cutoff.timeIntervalSince1970)])
		guard !keys.isEmpty else { return 0 }
		try transaction(keys: keys) {
			// Select expired TEXT ids while clips still exist; scan unindexed FTS only once.
			try run("""
				DELETE FROM clips_fts WHERE typeof(id)='text' AND id COLLATE BINARY IN
					(SELECT id FROM clips WHERE last_copied < ?)
				""", [.real(cutoff.timeIntervalSince1970)])
			try run("DELETE FROM clips WHERE last_copied < ?", [.real(cutoff.timeIntervalSince1970)])
			guard sqlite3_changes64(db) == Int64(keys.count) else {
				throw StoreError.sqlite("prune deleted count differs from selected keys")
			}
		}
		cleanup(keys.flatMap { [blobURL($0), thumbURL($0), trashURL($0, "plist")] })
		return keys.count
	}

	/// Clears every row, then every file. A file that cannot be removed is reported, not hidden.
	public func eraseAll() throws {
		try checkAvailable()
		// Get a complete inventory before committing; an unreadable directory stops destruction.
		let before: Inventory
		do { before = try inventory() } catch {
			cleanupDebt = true
			throw StoreError.sqlite("erase inventory unreadable: \(error)")
		}
		try transaction {
			try run("DELETE FROM clips", [])
			try run("DELETE FROM clips_fts", [])
		}
		undos.removeAll()
		let unremoved = cleanup(before.listed)
		let remaining: Int
		do {
			let after = try inventory()
			remaining = after.listed.count
			refreshCleanupStatus(after)
		} catch {
			cleanupDebt = true
			throw StoreError.filesLeft(unremoved.count)
		}
		if remaining > 0 { cleanupDebt = true; throw StoreError.filesLeft(remaining) }
	}

	private struct Inventory {
		let clips: [(key: String, previewState: PreviewState)]
		let listed: [URL]
		let paths: Set<String>
		let owned: Set<String>
	}

	/// Cleanup needs existence and thumbnail ownership, never titles or preview text.
	private func ownershipRows(_ key: String? = nil) throws -> [(key: String, previewState: PreviewState)] {
		readStatementCount += 1
		let statement = try prepare("SELECT id, preview_state FROM clips" + (key == nil ? "" : " WHERE id=?"), key.map { [.text($0)] } ?? [])
		defer { sqlite3_finalize(statement) }
		var rows: [(key: String, previewState: PreviewState)] = []
		while try nextRow(statement) {
			let key = String(cString: sqlite3_column_text(statement, 0))
			let state = String(cString: sqlite3_column_text(statement, 1))
			rows.append((key, PreviewState(rawValue: state) ?? .failed))
		}
		return rows
	}

	/// Full sweeps require readable rows and every directory before destructive cleanup.
	private func inventory() throws -> Inventory {
		let clips = try ownershipRows()
		let listed = try files.list(blobs) + files.list(thumbs) + files.list(trash)
		let paths = Set(listed.map(\.path))
		var owned = Set<String>()
		for clip in clips {
			let home = blobURL(clip.key), legacy = trashURL(clip.key, "plist")
			owned.insert(home.path)
			if !paths.contains(home.path), paths.contains(legacy.path) { owned.insert(legacy.path) }
			if clip.previewState == .ok || clip.previewState == .okNoImage { owned.insert(thumbURL(clip.key).path) }
		}
		for deleted in undos.values {
			owned.insert(snapshotURL(deleted, "plist").path)
			if deleted.hadThumbnail { owned.insert(snapshotURL(deleted, "png").path) }
		}
		return Inventory(clips: clips, listed: listed, paths: paths, owned: owned)
	}

	/// Check only the exact candidate keys/tokens. A failed ownership read preserves the entire batch.
	@discardableResult
	private func cleanup(_ urls: [URL]) -> [URL] {
		guard !recoveryRequired, !urls.isEmpty else { return urls }
		do {
			var rows: [String: PreviewState] = [:], checked = Set<String>(), owned = Set<String>()
			for url in urls {
				let parent = url.deletingLastPathComponent().path
				let name = url.deletingPathExtension().lastPathComponent
				let ext = url.pathExtension
				// Token-specific snapshots are owned only by the exact active actor record.
				if parent == trash.path, let dot = name.lastIndex(of: "."),
					let token = UUID(uuidString: String(name[name.index(after: dot)...])) {
					if let saved = undos[token], saved.clip.key == String(name[..<dot]),
						ext == "plist" || (ext == "png" && saved.hadThumbnail) { owned.insert(url.path) }
					continue
				}
				guard [blobs.path, thumbs.path, trash.path].contains(parent) else { owned.insert(url.path); continue }
				if checked.insert(name).inserted { rows[name] = try ownershipRows(name).first?.previewState }
				guard let state = rows[name] else { continue }
				if parent == blobs.path, ext == "plist" { owned.insert(url.path) }
				if parent == thumbs.path, ext == "png", state == .ok || state == .okNoImage { owned.insert(url.path) }
				if parent == trash.path, ext == "plist", try readIfPresent(blobURL(name)) == nil { owned.insert(url.path) }
			}
			// Token-only/atomic-temp batches still require a readable database before destruction.
			if checked.isEmpty { _ = try strings("SELECT id FROM clips LIMIT 1", []) }
			return unlink(urls.filter { !owned.contains($0.path) })
		} catch { cleanupDebt = true; return urls }
	}

	private func unlink(_ urls: [URL]) -> [URL] {
		var unremoved: [URL] = []
		for url in urls {
			do { try files.remove(url) } catch { cleanupDebt = true; unremoved.append(url) }
		}
		return unremoved
	}

	/// A complete readable scan is the only authority that can clear a previously observed warning.
	private func refreshCleanupStatus(_ inventory: Inventory, removing removed: Set<String> = []) {
		let remaining = inventory.paths.subtracting(removed)
		cleanupDebt = !remaining.isSubset(of: inventory.owned)
			|| inventory.clips.contains { !remaining.contains(blobURL($0.key).path) }
			|| undos.values.contains { !remaining.contains(snapshotURL($0, "plist").path)
				|| ($0.hadThumbnail && !remaining.contains(snapshotURL($0, "png").path)) }
	}

	/// Hourly cleanup preserves every valid token. Legacy fallback is blob-only, never a thumbnail.
	public func removeOrphans() throws {
		try checkAvailable()
		do {
			let before = try inventory()
			var recoveredBlob = false, copyFailed = false
			for clip in before.clips {
				let home = blobURL(clip.key), legacy = trashURL(clip.key, "plist")
				if !before.paths.contains(home.path), before.paths.contains(legacy.path) {
					do { try files.copy(legacy, to: home); recoveredBlob = true }
					catch { copyFailed = true }
				}
			}
			// Only publishing a recovered blob changes file ownership and needs another inventory.
			let known = try recoveredBlob ? inventory() : before
			let obsolete = known.listed.filter { !known.owned.contains($0.path) }
			let unremoved = unlink(obsolete)
			let removed = Set(obsolete.map(\.path)).subtracting(unremoved.map(\.path))
			// The complete inventory plus confirmed unlink results proves what remains without relisting.
			refreshCleanupStatus(known, removing: removed)
			if copyFailed { cleanupDebt = true }
		} catch { cleanupDebt = true; throw error }
	}

	/// Launch ends undos, recovers legacy live blobs, and drops rows proven to have no payload.
	public func sweep() throws {
		let clips = try ownershipRows()
		let listed = try files.list(blobs) + files.list(thumbs) + files.list(trash)
		let paths = Set(listed.map(\.path))
		let missing = clips.filter { !paths.contains(blobURL($0.key).path) && !paths.contains(trashURL($0.key, "plist").path) }.map(\.key)
		try transaction {
			for key in missing {
				try run("DELETE FROM clips WHERE id=?", [.text(key)])
				try run("DELETE FROM clips_fts WHERE id=?", [.text(key)])
			}
			try run("DELETE FROM clips_fts WHERE id NOT IN (SELECT id FROM clips)", [])
		}
		undos.removeAll()
		// The row removal is committed. Later cleanup failure is diagnostic, not a failed sweep.
		try? removeOrphans()
	}

	// MARK: Read

	/// Every clip, newest first. History is bounded by retention, not by a count.
	public func recent() throws -> [StoredClip] {
		try query("SELECT * FROM clips ORDER BY last_copied DESC", [])
	}

	/// One actor-isolated row query pairs current metadata with thumbnails owned by those same rows.
	public func snapshot() throws -> [(clip: StoredClip, thumbnail: URL?)] {
		try recent().map { clip in
			let url = thumbURL(clip.key)
			return (clip, ownsThumbnail(clip) && files.exists(url) ? url : nil)
		}
	}

	public func fetch(_ key: String) throws -> StoredClip? {
		try query("SELECT * FROM clips WHERE id=?", [.text(key)]).first
	}

	public func pending() throws -> [StoredClip] {
		try query("SELECT * FROM clips WHERE preview_state='pending' ORDER BY last_copied DESC", [])
	}

	/// The stored pasteboard items, for pasting.
	public func items(for key: String) throws -> [PasteboardItemData] {
		guard try fetch(key) != nil else { throw StoreError.missingBlob }
		return try Self.decode(liveBlob(key).data)
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

	enum CommitFault { case beforeEffect, afterEffect }
	private var commitFault: CommitFault?
	private var rollbackFault = false
	private var readbackFault = false
	func failTransaction(commit: CommitFault, rollback: Bool = false, readback: Bool = false) {
		commitFault = commit; rollbackFault = rollback; readbackFault = readback
	}

	private var inTransaction = false
	private var stepFault = false
	private(set) var readStatementCount = 0
	private(set) var writeStatementCount = 0
	func resetWriteCount() { writeStatementCount = 0 }
	/// Selected rows, retaining the existing targeted-read diagnostic.
	private(set) var readRowCount = 0
	private(set) var decodedClipCount = 0
	/// Includes skipped FTS ids, so tests also guard total scan work.
	private(set) var steppedReadRowCount = 0
	private(set) var readbackVMStepCount = 0
	func resetReadCounts() { readStatementCount = 0; readRowCount = 0; decodedClipCount = 0; steppedReadRowCount = 0; readbackVMStepCount = 0 }
	/// Tests: exercise chunking below the platform's SQLite bind limit.
	func limitSQLVariables(_ limit: Int32) { sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, limit) }
	private var writeFault = false

	/// Tests: the next read step fails as SQLite would on a busy or damaged database.
	func failNextStep() { stepFault = true }

	/// Tests: the next write statement fails, so its transaction rolls back.
	func failNextWrite() { writeFault = true }

	/// Tests: while on, the database refuses new clip rows only, so an insert fails after its generation and blob write.
	func rejectNewRows(_ on: Bool) throws {
		try checkAvailable()
		try Self.exec(db, on
			? "CREATE TEMP TRIGGER IF NOT EXISTS reject_new_rows BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT, 'injected'); END;"
			: "DROP TRIGGER IF EXISTS temp.reject_new_rows;")
	}

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
		if code == SQLITE_ROW { readRowCount += 1; steppedReadRowCount += 1; return true }
		guard code == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errstr(code))) }
		return false
	}

	private func checkAvailable() throws {
		if recoveryRequired { throw StoreError.outcomeUnknown }
	}

	struct SQLFingerprint: Equatable {
		let count: UInt64
		let digest: SHA256.Digest
	}

	struct SQLState: Equatable {
		let rows: SQLFingerprint
		let fts: SQLFingerprint
		let generation: SQLFingerprint
	}

	/// Construct once per transaction so prior, expected and persisted use identical chunks.
	private struct ReadbackScope {
		// SQLite ids use binary equality, unlike canonically equivalent Swift Strings.
		let keys: Set<Data>?
		let chunks: [[String]]
		init(_ keys: [String]?) {
			self.keys = keys.map { Set($0.map { Data($0.utf8) }) }
			let sorted = self.keys?.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) } ?? []
			chunks = stride(from: 0, to: sorted.count, by: 400).map { Array(sorted[$0..<min($0 + 400, sorted.count)]) }
		}
	}

	/// Framing is independent of SQL text rendering and Swift's lossy metadata decoding.
	private struct SQLHasher {
		var hash = SHA256()
		var count: UInt64 = 0

		mutating func number(_ number: UInt64) {
			var bits = number.bigEndian
			withUnsafeBytes(of: &bits) { hash.update(bufferPointer: $0) }
		}

		mutating func bytes(_ bytes: UnsafeRawBufferPointer) {
			number(UInt64(bytes.count))
			hash.update(bufferPointer: bytes)
		}

		mutating func marker(_ marker: String) {
			Array(marker.utf8).withUnsafeBytes { bytes($0) }
		}

		mutating func row(_ statement: OpaquePointer?) throws {
			number(1) // Row marker, followed by column count and typed fields.
			let columns = sqlite3_column_count(statement)
			number(UInt64(columns))
			for column in 0..<columns {
				let type = sqlite3_column_type(statement, column) // Before any conversion.
				number(UInt64(type))
				switch type {
				case SQLITE_NULL: break
				case SQLITE_INTEGER: number(UInt64(bitPattern: sqlite3_column_int64(statement, column)))
				case SQLITE_FLOAT: number(sqlite3_column_double(statement, column).bitPattern)
				case SQLITE_TEXT, SQLITE_BLOB:
					// SQLite requires the pointer accessor before column_bytes. Never use C-string length.
					let pointer = type == SQLITE_TEXT
						? sqlite3_column_text(statement, column).map { UnsafeRawPointer($0) }
						: sqlite3_column_blob(statement, column)
					let length = Int(sqlite3_column_bytes(statement, column))
					guard sqlite3_errcode(sqlite3_db_handle(statement)) != SQLITE_NOMEM,
						length == 0 || pointer != nil else { throw StoreError.sqlite("readback column unavailable") }
					bytes(UnsafeRawBufferPointer(start: pointer, count: length))
				default: throw StoreError.sqlite("unknown readback storage class")
				}
			}
			count += 1
		}

		mutating func finish() -> SQLFingerprint {
			number(0) // End of table, followed by total row count.
			number(count)
			return SQLFingerprint(count: count, digest: hash.finalize())
		}
	}

	private func fingerprint(_ sql: String, _ values: [Value], into hasher: inout SQLHasher, keys: Set<Data>? = nil) throws {
		readStatementCount += 1
		let statement = try prepare(sql, values)
		defer {
			readbackVMStepCount += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
			sqlite3_finalize(statement)
		}
		hasher.marker(sql) // Query/chunk marker, including empty result sets.
		hasher.number(UInt64(values.count))
		for value in values {
			if case let .text(key) = value { hasher.marker(key) }
		}
		while try nextRow(statement) {
			if let keys {
				// Match the TEXT bindings used by clip queries, without coercing BLOB/numeric ids.
				guard sqlite3_column_type(statement, 0) == SQLITE_TEXT else { readRowCount -= 1; continue }
				let pointer = sqlite3_column_text(statement, 0)
				let length = Int(sqlite3_column_bytes(statement, 0))
				guard let pointer else { throw StoreError.sqlite("readback id unavailable") }
				let key = Data(bytes: pointer, count: length)
				guard keys.contains(key) else {
					// readRowCount tracks selected rows; skipped FTS ids do not decode clip metadata.
					readRowCount -= 1
					continue
				}
			}
			try hasher.row(statement)
		}
		hasher.number(2) // End of query/chunk, including an empty projection.
		hasher.number(UInt64(sqlite3_column_count(statement)))
	}

	/// Internal visibility lets tests compare the actual recovery oracle, not a substitute.
	func sqlState(_ keys: [String]?) throws -> SQLState { try sqlState(ReadbackScope(keys)) }

	private func sqlState(_ scope: ReadbackScope) throws -> SQLState {
		var rows = SQLHasher(), fts = SQLHasher(), generation = SQLHasher()
		rows.marker("clips")
		if scope.keys == nil {
			try fingerprint("SELECT * FROM clips ORDER BY id", [], into: &rows)
		} else {
			for chunk in scope.chunks {
				let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
				try fingerprint("SELECT * FROM clips WHERE id IN (\(placeholders)) ORDER BY id", chunk.map(Value.text), into: &rows)
			}
		}
		fts.marker("clips_fts")
		// Small scopes filter inside SQLite; large scopes still scan FTS only once, never per chunk.
		if scope.keys != nil, scope.chunks.count <= 1 {
			let chunk = scope.chunks.first ?? []
			let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
			let filter = chunk.isEmpty ? "0" : "id COLLATE BINARY IN (\(placeholders)) AND typeof(id)='text'"
			try fingerprint("SELECT id, title, preview_text FROM clips_fts WHERE \(filter) ORDER BY rowid", chunk.map(Value.text), into: &fts)
		} else {
			// id is UNINDEXED. Rowid order avoids sorting full FTS text.
			try fingerprint("SELECT id, title, preview_text FROM clips_fts ORDER BY rowid", [], into: &fts, keys: scope.keys)
		}
		generation.marker("meta")
		try fingerprint("SELECT key, value FROM meta WHERE key='generation' ORDER BY key", [], into: &generation)
		return SQLState(rows: rows.finish(), fts: fts.finish(), generation: generation.finish())
	}

	/// A SQL exception is not evidence of rollback. Read back only after SQLite confirms autocommit.
	/// The prospective state includes row fields, generation and FTS; the caller supplies required files.
	func transaction(keys: [String]? = nil, validFiles: () -> Bool = { true }, _ body: () throws -> Void) throws {
		try checkAvailable()
		if inTransaction { return try body() }
		let scope = ReadbackScope(keys)
		let prior = try sqlState(scope)
		var expected: SQLState?
		do {
			try Self.exec(db, "BEGIN IMMEDIATE")
			inTransaction = true
			try body()
			expected = try sqlState(scope)
			let fault = commitFault
			commitFault = nil
			if fault == .beforeEffect { throw StoreError.sqlite("injected COMMIT before effect") }
			try Self.exec(db, "COMMIT")
			inTransaction = false
			if fault == .afterEffect { throw StoreError.sqlite("injected COMMIT after effect") }
		} catch {
			let failure = error
			inTransaction = false
			if sqlite3_get_autocommit(db) == 0, !rollbackFault { try? Self.exec(db, "ROLLBACK") }
			rollbackFault = false
			var persisted: SQLState?
			if sqlite3_get_autocommit(db) != 0, !readbackFault { persisted = try? sqlState(scope) }
			readbackFault = false
			if let persisted {
				if let expected, persisted == expected, validFiles() { return }
				if persisted == prior { throw failure }
			}
			recoveryRequired = true
			throw StoreError.outcomeUnknown
		}
	}

	private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
		try checkAvailable()
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
			throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
		}
		let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
		for (i, value) in values.enumerated() {
			let index = Int32(i + 1)
			let code: Int32
			switch value {
			case let .text(s): code = s.withCString { sqlite3_bind_text(statement, index, $0, Int32(s.utf8.count), transient) }
			case let .int(n): code = sqlite3_bind_int64(statement, index, Int64(n))
			case let .real(d): code = sqlite3_bind_double(statement, index, d)
			case .null: code = sqlite3_bind_null(statement, index)
			}
			guard code == SQLITE_OK else {
				sqlite3_finalize(statement)
				throw StoreError.sqlite(String(cString: sqlite3_errstr(code)))
			}
		}
		return statement
	}

	private func run(_ sql: String, _ values: [Value]) throws {
		writeStatementCount += 1
		if writeFault { writeFault = false; throw StoreError.sqlite("injected write fault") }
		let statement = try prepare(sql, values)
		defer { sqlite3_finalize(statement) }
		guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
	}

	private func strings(_ sql: String, _ values: [Value]) throws -> [String] {
		readStatementCount += 1
		let statement = try prepare(sql, values)
		defer { sqlite3_finalize(statement) }
		var result: [String] = []
		while try nextRow(statement) {
			let pointer = sqlite3_column_text(statement, 0)
			let length = Int(sqlite3_column_bytes(statement, 0))
			guard let pointer else { throw StoreError.sqlite("string column unavailable") }
			result.append(String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self))
		}
		return result
	}

	private func query(_ sql: String, _ values: [Value]) throws -> [StoredClip] {
		readStatementCount += 1
		let statement = try prepare(sql, values)
		defer { sqlite3_finalize(statement) }
		var result: [StoredClip] = []
		func text(_ i: Int32) -> String? {
			guard let pointer = sqlite3_column_text(statement, i) else { return nil }
			return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self)
		}
		while try nextRow(statement) {
			decodedClipCount += 1
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
