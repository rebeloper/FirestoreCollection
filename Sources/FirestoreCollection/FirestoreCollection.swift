//
//  FirestoreCollection.swift
//
//
//  Created by Alex Nagy on 06.02.2025.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

/// An observable for the set collection at the provided `path`
@MainActor
@Observable
public class FirestoreCollection<F: Firestorable> {
    
    let database: Firestore
    let path: String
    
    public init(database: Firestore = Firestore.firestore(), path: String) {
        self.database = database
        self.path = path
    }
    
    var lastQueryDocumentSnapshot: QueryDocumentSnapshot?
    var listener: ListenerRegistration?
    
    public enum FetchType {
        case id(id: String)
        case one(predicates: [QueryPredicate])
        case some(predicates: [QueryPredicate])
        case firstFew(options: PaginatedFetchOptions, predicates: [QueryPredicate])
        case more(options: PaginatedFetchOptions, predicates: [QueryPredicate])
        case count(predicates: [QueryPredicate])
    }
    
    public struct PaginatedFetchOptions {
        public var limit: Int
        public var orderBy: String
        public var descending: Bool
        
        public init(limit: Int, orderBy: String, descending: Bool = true) {
            self.limit = limit
            self.orderBy = orderBy
            self.descending = descending
        }
    }
    
    /// Fetches one document with the specified id
    /// - Parameter id: id of the document
    /// - Returns: and optional document
    public func fetchOne(id: String) async throws -> FetchedCollectionOneResult<F> {
        let result = try await fetch(.id(id: id))
        switch result {
        case .empty:
            return .empty
        case .fetched(let documents):
            if let document = documents.first {
                return .fetched(document: document)
            } else {
                return .empty
            }
        default:
            return .empty
        }
    }
    
    public func fetchOne(predicates: [QueryPredicate]) async throws -> FetchedCollectionOneResult<F> {
        let result = try await fetch(.one(predicates: predicates))
        switch result {
        case .empty:
            return .empty
        case .fetched(let documents):
            if let document = documents.first {
                return .fetched(document: document)
            } else {
                return .empty
            }
        default:
            return .empty
        }
    }
    
    /// Fetches an array of documents for the specified optional paginated fetch options and predicates
    /// - Parameters:
    ///   - options: optional paginated fetch options
    ///   - predicates: predicates for the fetch; do NOT use `limit` or `order` (these are set up in the `options`)
    /// - Returns: an array of documents
    public func fetchSome(options: PaginatedFetchOptions? = nil, predicates: [QueryPredicate]) async throws -> FetchedCollectionSomeResult<F> {
        if let options {
            let result = try await fetch(.more(options: options, predicates: predicates))
            switch result {
            case .empty:
                return .empty
            case .fetched(let documents):
                return documents.isEmpty ? .empty : .fetched(documents: documents)
            case .fullyFetched:
                return .fetched(documents: [])
            default:
                return .empty
            }
        } else {
            let result = try await fetch(.some(predicates: predicates))
            switch result {
            case .empty:
                return .empty
            case .fetched(let documents):
                return documents.isEmpty ? .empty : .fetched(documents: documents)
            default:
                return .empty
            }
        }
    }
    
    /// Fetches the count of documents for the specified predicates
    /// - Parameter predicates: predicates for the fetch
    /// - Returns: the optional count of documents
    public func fetchCount(predicates: [QueryPredicate]) async throws -> Int {
        let result = try await fetch(.count(predicates: predicates))
        switch result {
        case .counted(let count):
            return count
        default:
            return 0
        }
    }
    
    /// Fetches documents
    /// - Parameters:
    ///   - type: the fetch type
    /// - Returns: a result of the collection fetch: `empty`, `fetched(documents: [F])`, `fullyFetched`, `noLastDocumentSnapshot` or `counted(count: Int)`
    public func fetch(_ type: FetchType) async throws -> FetchedCollectionResult<F> {
        switch type {
        case .id(let id):
            let document = try await database.collection(path).document(id).getDocument(as: F.self)
            return .fetched(documents: [document])
            
        case .one(let predicates):
            var predicates = predicates
            predicates.append(.limit(to: 1))
            let query = getQuery(path: path, predicates: predicates)
            let snapshot = try await query.getDocuments()
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            return .fetched(documents: documents)
            
        case .some(let predicates):
            let query = getQuery(path: path, predicates: predicates)
            let snapshot = try await query.getDocuments()
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            return .fetched(documents: documents)
            
        case .firstFew(let options, let predicates):
            lastQueryDocumentSnapshot = nil
            let query: Query = getQuery(path: path, predicates: predicates)
                .order(by: options.orderBy, descending: options.descending)
                .limit(to: options.limit)
            let snapshot = try await query.getDocuments()
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            guard let lastSnapshot = snapshot.documents.last else {
                return documents.isEmpty ? .empty : .fullyFetched
            }
            lastQueryDocumentSnapshot = lastSnapshot
            return .fetched(documents: documents)
            
        case .more(let options, let predicates):
            if let lastQueryDocumentSnapshot {
                let query: Query = getQuery(path: path, predicates: predicates)
                    .order(by: options.orderBy, descending: options.descending)
                    .limit(to: options.limit)
                    .start(afterDocument: lastQueryDocumentSnapshot)
                
                let snapshot = try await query.getDocuments()
                let documents = snapshot.documents.compactMap { document in
                    try? document.data(as: F.self)
                }
                guard let lastSnapshot = snapshot.documents.last else {
                    return documents.isEmpty ? .empty : .fullyFetched
                }
                self.lastQueryDocumentSnapshot = lastSnapshot
                return .fetched(documents: documents)
            } else {
                return try await fetch(.firstFew(options: options, predicates: predicates))
            }
        case .count(let predicates):
            let query = getQuery(path: path, predicates: predicates)
            let countQuery = query.count
            let snapshot = try await countQuery.getAggregation(source: .server)
            let count = Int(truncating: snapshot.count)
            return .counted(count: count)
        }
        
    }
    
    /// Creates the provided document in the collection
    /// - Parameter document: the document to be created
    public func create(_ document: F) throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            return
        }
        var firestorable = document
        firestorable.userId = userId
        firestorable.createdAt = nil
        firestorable.updatedAt = nil
        try database.collection(path).addDocument(from: firestorable)
    }
    
    /// Batch writes the array of documents
    /// - Parameter writes: an array of `BatchedWrite`s (documents with the batch write type)
    public func writeBatch(_ writes: [BatchedWrite<F>]) async throws {
        let batch = database.batch()
        
        try writes.forEach { batchedWrite in
            var firestorable = batchedWrite.document
                switch batchedWrite.type {
                case .create:
                    let reference = database.collection(path).document()
                    guard let userId = Auth.auth().currentUser?.uid else {
                        return
                    }
                    firestorable.userId = userId
                    firestorable.createdAt = nil
                    firestorable.updatedAt = nil
                    try batch.setData(from: firestorable, forDocument: reference)
                case .update:
                    if let documentId = firestorable.id as? String {
                        let reference = database.collection(path).document(documentId)
                        firestorable.updatedAt = nil
                        try batch.setData(from: firestorable, forDocument: reference, merge: true)
                    }
                case .delete:
                    if let documentId = firestorable.id as? String {
                        let reference = database.collection(path).document(documentId)
                        batch.deleteDocument(reference)
                    }
                }
            
        }
        
        try await batch.commit()
    }
    
    /// Updates the provided document in the collection
    /// - Parameters:
    ///   - document: the document to be updated
    public func update(_ document: F) async throws {
        guard let documentId = document.id as? String else { return }
        var firestorable = document
        firestorable.updatedAt = nil
        try Firestore.firestore().collection(path).document(documentId).setData(from: firestorable, merge: true)
    }
    
    /// Increments a field value inside a document by the amount specified.
    /// - Parameters:
    ///   - field: The field to be incremented.
    ///   - by: The amount to increment. Defaults to 1.
    ///   - document: The document.
    public func increment(_ field: String, by: Int = 1, forDocument document: F) async throws {
        guard let id = document.id as? String else { return }
        guard by > 0 else { return }
        try await database.collection(path).document(id).updateData([
            field: FieldValue.increment(Int64(by))
        ])
    }
    
    // Increments a field value inside a document by the amount specified.
    /// - Parameters:
    ///   - field: The field to be incremented.
    ///   - by: The amount to increment. Defaults to 1.
    ///   - id: The id of the document.
    public func increment(_ field: String, by: Int = 1, forId id: String) async throws {
        guard by > 0 else { return }
        try await database.collection(path).document(id).updateData([
            field: FieldValue.increment(Int64(by))
        ])
    }
    
    /// Decrements a field value by the amount specified inside a document.
    /// - Parameters:
    ///   - field: The field to be decremented.
    ///   - by: The amount to decrement. Defaults to 1.
    ///   - document: The document.
    public func decrement(_ field: String, by: Int = 1, forDocument document: F) async throws {
        guard let id = document.id as? String else { return }
        guard by > 0 else { return }
        try await database.collection(path).document(id).updateData([
            field: FieldValue.increment(Int64(-by))
        ])
    }
    
    /// Decrements a field value by the amount specified inside a document.
    /// - Parameters:
    ///   - field: The field to be decremented.
    ///   - by: The amount to decrement. Defaults to 1.
    ///   - id: The id of the document.
    public func decrement(_ field: String, by: Int = 1, forId id: String) async throws {
        guard by > 0 else { return }
        try await database.collection(path).document(id).updateData([
            field: FieldValue.increment(Int64(-by))
        ])
    }
    
    /// Deletes the provided document from the collection
    /// - Parameters:
    ///   - document: the document to be deleted
    public func delete(_ document: F) async throws {
        guard let documentId = document.id as? String else { return }
        try await Firestore.firestore().collection(path).document(documentId).delete()
    }
    
    /// Attaches a listener for `QuerySnapshot` events.
    /// - Parameters:
    ///   - predicates: predicates for the listener. Default is empty.
    ///   - completion: completion surfacing the fetched documents over time and any Errors. IMPORTANT: the listener will be automatically stoped if an error occoures.
    public func startListening(predicates: [QueryPredicate] = [], completion: @escaping (Result<[F], Error>) -> Void) {
        let query = getQuery(path: path, predicates: predicates)
        listener = query.addSnapshotListener { snapshot, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let snapshot else {
                completion(.success([]))
                return
            }
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            completion(.success(documents))
        }
    }
    
    /// Removes the listener being tracked by the `ListenerRegistration`. After the initial call, subsequent calls have no effect.
    public func stopListening() {
        listener?.remove()
    }
    
    // MARK: - Private
    
    private func getQuery(path: String, predicates: [QueryPredicate]) -> Query {
        var query: Query = database.collection(path)
        
        for predicate in predicates {
            switch predicate {
            case let .isEqualTo(field, value):
                query = query.whereField(field, isEqualTo: value)
            case let .isIn(field, values):
                query = query.whereField(field, in: values)
            case let .isNotIn(field, values):
                query = query.whereField(field, notIn: values)
            case let .arrayContains(field, value):
                query = query.whereField(field, arrayContains: value)
            case let .arrayContainsAny(field, values):
                query = query.whereField(field, arrayContainsAny: values)
            case let .isLessThan(field, value):
                query = query.whereField(field, isLessThan: value)
            case let .isGreaterThan(field, value):
                query = query.whereField(field, isGreaterThan: value)
            case let .isLessThanOrEqualTo(field, value):
                query = query.whereField(field, isLessThanOrEqualTo: value)
            case let .isGreaterThanOrEqualTo(field, value):
                query = query.whereField(field, isGreaterThanOrEqualTo: value)
            case let .orderBy(field, value):
                query = query.order(by: field, descending: value)
            case let .limitTo(field):
                query = query.limit(to: field)
            case let .limitToLast(field):
                query = query.limit(toLast: field)
            }
        }
        return query
    }
}
