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
    case counted(count: Int)
}

public enum FetchedCollectionOneResult<F: Firestorable> {
    case empty
    case fetched(document: F)
}

public enum FetchedCollectionSomeResult<F: Firestorable> {
    case empty
    case fetched(documents: [F])
    case fullyFetched
}
