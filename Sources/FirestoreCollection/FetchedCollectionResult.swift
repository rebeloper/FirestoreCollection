//
//  FetchedCollectionResult.swift
//  FirestoreCollection
//
//  Created by Alex Nagy on 07.02.2025.
//

import Foundation

public enum FetchedCollectionResult<F: Firestorable> {
    case empty
    case fetched(documents: [F])
    case fullyFetched
    case noLastDocumentSnapshot
    case counted(count: Int)
}
