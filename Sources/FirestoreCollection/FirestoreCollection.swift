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
    
    let path: String
    
    public init(path: String) {
        self.path = path
    }
    
    public var queryDocuments: [F] = []
    public var queryDocument: F?
    var lastQueryDocumentSnapshot: QueryDocumentSnapshot?
    
    /// Fetches one document with the specified `id`
    /// - Parameters:
    ///   - id: the `id` of the document
    ///   - animation: optional animation of the the document beig fetched. Default is `nil`
    public func fetch(id: String, animation: Animation? = nil) async throws {
        let document = try await Firestore.firestore().collection(path).document(id).getDocument(as: F.self)
        if let animation {
            withAnimation(animation) {
                queryDocument = document
            }
        } else {
            queryDocument = document
        }
    }
    
    /// Fetches all the documents from the collection
    /// - Parameters:
    ///   - predicates: predicates for the fetch. Default is empty.
    ///   - animation: optional animation of the the documents beig fetched. Default is `nil`
    public func fetchAll(predicates: [QueryPredicate] = [], animation: Animation? = nil) async throws {
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
    }
    
    /// Fetches the next `n` amount (set by the `limit`) of documents according to the specified order. IMPORTANT: Do not set `limit` or `orderBy` in the `predicates`
    /// - Parameters:
    ///   - limit: the document count limit of the fetch
    ///   - orderBy: the key for the order of the fetch
    ///   - descending: should the order be descending
    ///   - predicates: other predicates than `limit` or `orderBy`. Defualt is empty
    ///   - animation: optional animation of the the documents beig fetched. Default is `nil`
    /// - Returns: a state of the collection after the fetch: `empty`, `fetched` or `fullyFetched`
    @discardableResult
    public func fetchNext(_ limit: Int, orderBy: String, descending: Bool = true, predicates: [QueryPredicate] = [], animation: Animation? = nil) async throws -> FetchedCollectionState {
        var query: Query
        if let lastQueryDocumentSnapshot {
            query = getQuery(path: path, predicates: predicates)
                .order(by: orderBy, descending: descending)
                .limit(to: limit)
                .start(afterDocument: lastQueryDocumentSnapshot)
        } else {
            query = getQuery(path: path, predicates: predicates)
                .order(by: orderBy, descending: descending)
                .limit(to: limit)
        }
        let snapshot = try await query.getDocuments()
        let documents = snapshot.documents.compactMap { document in
            try? document.data(as: F.self)
        }
        documents.forEach { document in
            if let animation {
                withAnimation(animation) {
                    queryDocuments.append(document)
                }
            } else {
                queryDocuments.append(document)
            }
        }
        guard let lastSnapshot = snapshot.documents.last else {
            return documents.isEmpty ? .empty : .fullyFetched
        }
        lastQueryDocumentSnapshot = lastSnapshot
        return .fetched
    }
    
    /// Clears the fetched documents and fetches the next `n` amount (set by the `limit`) of documents according to the specified order. IMPORTANT: Do not set `limit` or `orderBy` in the `predicates`
    /// - Parameters:
    ///   - limit: the document count limit of the fetch
    ///   - orderBy: the key for the order of the fetch
    ///   - descending: should the order be descending
    ///   - predicates: other predicates than `limit` or `orderBy`. Defualt is empty
    ///   - animation: optional animation of the the documents beig fetched. Default is `nil`
    /// - Returns: a state of the collection after the fetch: `empty`, `fetched` or `fullyFetched`
    @discardableResult
    public func fetchFirst(_ limit: Int, orderBy: String, descending: Bool = true, predicates: [QueryPredicate] = [], animation: Animation? = nil) async throws -> FetchedCollectionState {
        queryDocuments.removeAll()
        lastQueryDocumentSnapshot = nil
        return try await fetchNext(limit, orderBy: orderBy, descending: descending, predicates: predicates, animation: animation)
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
        try Firestore.firestore().collection(path).addDocument(from: firestorable)
    }
    
    /// Updates the provided document in the collection
    /// - Parameters:
    ///   - document: the document to be updated
    ///   - updatedAtServerTimestampStrategy: Default `local` is going to NOT do another fetch for the document and set the `createdAt` to `Date.now`. If set to `server` another fetch will be made to get the server timestamp of the `updatedAt`. IMPORTANT: Set `server` only if `updatedAt` is critical for your logic, because it will do two operations: one when updating and a second one when fetching it to retreive the server timestamp for the `updatedAt`
    ///   - animation: optional animation of the the documents beig fetched. Default is `nil`
    public func update(with document: F, updatedAtServerTimestampStrategy: UpdatedAtServerTimestampStrategy = .local, animation: Animation? = nil) async throws {
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
    
    /// Deletes the provided document from the collection
    /// - Parameters:
    ///   - document: the document to be deleted
    ///   - animation: optional animation of the the documents beig fetched. Default is `nil`
    public func delete(_ document: F, animation: Animation? = nil) async throws {
        guard let documentId = document.id as? String else { return }
        try await Firestore.firestore().collection(path).document(documentId).delete()
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
    
    // MARK: - Private
    
    private func getQuery(path: String, predicates: [QueryPredicate]) -> Query {
        var query: Query = Firestore.firestore().collection(path)
        
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
    
    private func updateWithServerUpdatedAt(with document: F, animation: Animation? = nil) async throws {
        guard let documentId = document.id as? String else { return }
        var firestorable = document
        firestorable.updatedAt = nil
        try Firestore.firestore().collection(path).document(documentId).setData(from: firestorable, merge: true)
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
    
    private func updateWithLocalUpdatedAt(with document: F, animation: Animation? = nil) throws {
        guard let documentId = document.id as? String else { return }
        var firestorable = document
        firestorable.updatedAt = nil
        try Firestore.firestore().collection(path).document(documentId).setData(from: firestorable, merge: true)
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
