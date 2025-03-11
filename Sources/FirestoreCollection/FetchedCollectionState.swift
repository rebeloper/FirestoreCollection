//
//  FetchedCollectionState.swift
//  FirestoreCollection
//
//  Created by Alex Nagy on 07.02.2025.
//

import Foundation

public enum FetchedCollectionState {
    case empty
    case fetched
    case fullyFetched
    case noLastDocumentSnapshot
}
