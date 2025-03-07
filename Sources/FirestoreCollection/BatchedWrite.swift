//
//  BatchedWrite.swift
//  FirestoreCollection
//
//  Created by Alex Nagy on 07.03.2025.
//

import Foundation

public struct BatchedWrite<F: Firestorable> {
    public let type: BatchedWriteType
    public let document: F
    
    public init(_ type: BatchedWriteType, document: F) {
        self.type = type
        self.document = document
    }
}

public enum BatchedWriteType {
    case create, update, delete
}
