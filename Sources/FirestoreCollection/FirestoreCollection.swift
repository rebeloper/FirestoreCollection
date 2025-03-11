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
    
    public var queryDocuments: [F] = []
    public var queryDocument: F?
    public var count: Int?
    
    var lastQueryDocumentSnapshot: QueryDocumentSnapshot?
    var listener: ListenerRegistration?
    
    public enum FetchType {
        case one(id: String)
        case more(predicates: [QueryPredicate])
        case first(options: PaginatedFetchOptions, predicates: [QueryPredicate])
        case next(options: PaginatedFetchOptions, predicates: [QueryPredicate])
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
    
    /// Fetches documents
    /// - Parameters:
    ///   - type: the fetch type
    ///   - animation: optional animation of the operation. Default is `.default`
    /// - Returns: a state of the collection after the fetch: `empty`, `fetched` or `fullyFetched`
    @discardableResult
    public func fetch(_ type: FetchType, animation: Animation? = .default) async throws -> FetchedCollectionState {
        switch type {
        case .one(let id):
            let document = try await database.collection(path).document(id).getDocument(as: F.self)
            if let animation {
                withAnimation(animation) {
                    queryDocument = document
                }
            } else {
                queryDocument = document
            }
            return .fetched
            
        case .more(let predicates):
            let query = getQuery(path: path, predicates: predicates)
            let snapshot = try await query.getDocuments()
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            queryDocuments.removeAll()
            if let animation {
                withAnimation(animation) {
                    queryDocuments = documents
                }
            } else {
                queryDocuments = documents
            }
            return .fetched
            
        case .first(let options, let predicates):
            queryDocuments.removeAll()
            print("FC: queryDocuments: \(queryDocuments)")
            lastQueryDocumentSnapshot = nil
            print("FC: lastQueryDocumentSnapshot: \(String(describing: lastQueryDocumentSnapshot))")
            let query: Query = getQuery(path: path, predicates: predicates)
                .order(by: options.orderBy, descending: options.descending)
                .limit(to: options.limit)
            let snapshot = try await query.getDocuments()
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            print("FC: documents: \(documents)")
            if let animation {
                withAnimation(animation) {
                    queryDocuments = documents
                }
            } else {
                queryDocuments = documents
            }
            guard let lastSnapshot = snapshot.documents.last else {
                return documents.isEmpty ? .empty : .fullyFetched
            }
            print("FC: lastSnapshot: \(lastSnapshot)")
            lastQueryDocumentSnapshot = lastSnapshot
            return .fetched
            
        case .next(let options, let predicates):
            if let lastQueryDocumentSnapshot {
                let query: Query = getQuery(path: path, predicates: predicates)
                    .order(by: options.orderBy, descending: options.descending)
                    .limit(to: options.limit)
                    .start(afterDocument: lastQueryDocumentSnapshot)
                
                let snapshot = try await query.getDocuments()
                let documents = snapshot.documents.compactMap { document in
                    try? document.data(as: F.self)
                }
                if let animation {
                    withAnimation(animation) {
                        documents.forEach { document in
                            queryDocuments.append(document)
                        }
                    }
                } else {
                    documents.forEach { document in
                        queryDocuments.append(document)
                    }
                }
                guard let lastSnapshot = snapshot.documents.last else {
                    return documents.isEmpty ? .empty : .fullyFetched
                }
                self.lastQueryDocumentSnapshot = lastSnapshot
                return .fetched
            } else {
                return .noLastDocumentSnapshot
            }
        case .count(let predicates):
            let query = getQuery(path: path, predicates: predicates)
            let countQuery = query.count
            let snapshot = try await countQuery.getAggregation(source: .server)
            let count = Int(truncating: snapshot.count)
            if let animation {
                withAnimation(animation) {
                    self.count = count
                }
            } else {
                self.count = count
            }
            return .fetched
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
    /// - Parameter writes: an array of `BatchedWrite`s (docum entswith the batch write type)
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
    ///   - updatedAtServerTimestampStrategy: Default `local` is going to NOT do another fetch for the document and set the `createdAt` to `Date.now`. If set to `server` another fetch will be made to get the server timestamp of the `updatedAt`. IMPORTANT: Set `server` only if `updatedAt` is critical for your logic, because it will do two operations: one when updating and a second one when fetching it to retreive the server timestamp for the `updatedAt`
    ///   - animation: optional animation of the operation. Default is `.default`
    public func update(with document: F, updatedAtServerTimestampStrategy: UpdatedAtServerTimestampStrategy = .local, animation: Animation? = .default) async throws {
        switch updatedAtServerTimestampStrategy {
        case .local:
            try updateWithLocalUpdatedAt(with: document, animation: animation)
        case .server:
            try await updateWithServerUpdatedAt(with: document, animation: animation)
        }
    }
    
    public enum UpdatedAtServerTimestampStrategy {
        case server
        case local
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
    ///   - animation: optional animation of the operation. Default is `.default`
    public func delete(_ document: F, animation: Animation? = .default) async throws {
        guard let documentId = document.id as? String else { return }
        try await Firestore.firestore().collection(path).document(documentId).delete()
        guard listener == nil else { return }
        if let onlyOneDocument = queryDocument, let documentID = onlyOneDocument.id as? String, documentID == documentId {
            queryDocument = nil
        } else {
            let index = queryDocuments.firstIndex { document in
                guard let documentID = document.id as? String else { return false }
                return documentID == documentId
            }
            guard let index else { return }
            if let animation {
                _ = withAnimation(animation) {
                    queryDocuments.remove(at: index)
                }
            } else {
                queryDocuments.remove(at: index)
            }
        }
    }
    
    /// Attaches a listener for `QuerySnapshot` events.
    /// - Parameters:
    ///   - predicates: predicates for the listener. Default is empty.
    ///   - animation: optional animation of the operation. Default is `.default`
    ///   - completion: optional completion that surfaces if an error accoured. Returns `nil` if the snapshot is `nil`. IMPORTANT: the listener will be automatically stoped if an error occoures.
    public func startListening(predicates: [QueryPredicate] = [], animation: Animation? = .default, completion: ((Error?) -> Void)? = nil) {
        let query = getQuery(path: path, predicates: predicates)
        listener = query.addSnapshotListener { snapshot, error in
            if let error {
                completion?(error)
                return
            }
            
            guard let snapshot else {
                completion?(nil)
                return
            }
            
            let documents = snapshot.documents.compactMap { document in
                try? document.data(as: F.self)
            }
            
            var queryDocuments: [F] = []
            documents.forEach { document in
                queryDocuments.append(document)
            }
            if let animation {
                withAnimation(animation) {
                    self.queryDocuments = queryDocuments
                }
            } else {
                self.queryDocuments = queryDocuments
            }
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
    
    private func fetch(id: String) async throws -> F {
        try await Firestore.firestore().collection(path).document(id).getDocument(as: F.self)
    }
    
    private func updateWithServerUpdatedAt(with document: F, animation: Animation? = .default) async throws {
        guard let documentId = document.id as? String else { return }
        var firestorable = document
        firestorable.updatedAt = nil
        try Firestore.firestore().collection(path).document(documentId).setData(from: firestorable, merge: true)
        guard listener == nil else { return }
        let updatedDocument = try await fetch(id: documentId)
        if let onlyOneDocument = queryDocument, let documentID = onlyOneDocument.id as? String, documentID == documentId {
            queryDocument = updatedDocument
        } else {
            let index = queryDocuments.firstIndex { document in
                guard let documentID = document.id as? String else { return false }
                return documentID == documentId
            }
            guard let index else { return }
            if let animation {
                withAnimation(animation) {
                    queryDocuments[index] = updatedDocument
                }
            } else {
                queryDocuments[index] = updatedDocument
            }
        }
    }
    
    private func updateWithLocalUpdatedAt(with document: F, animation: Animation? = .default) throws {
        guard let documentId = document.id as? String else { return }
        var firestorable = document
        firestorable.updatedAt = nil
        try Firestore.firestore().collection(path).document(documentId).setData(from: firestorable, merge: true)
        guard listener == nil else { return }
        if let onlyOneDocument = queryDocument, let documentID = onlyOneDocument.id as? String, documentID == documentId {
            var document = document
            document.updatedAt = Timestamp(date: .now)
            queryDocument = document
        } else {
            let index = queryDocuments.firstIndex { document in
                guard let documentID = document.id as? String else { return false }
                return documentID == documentId
            }
            guard let index else { return }
            if let animation {
                withAnimation(animation) {
                    var document = document
                    document.updatedAt = Timestamp(date: .now)
                    queryDocuments[index] = document
                }
            } else {
                var document = document
                document.updatedAt = Timestamp(date: .now)
                queryDocuments[index] = document
            }
        }
    }
}
