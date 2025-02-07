//
//  FirestoreModelable.swift
//
//
//  Created by Alex Nagy on 07.02.2025.
//

import FirebaseFirestore

public protocol FirestoreModelable {
    var createdAt: Timestamp? { get set }
    var updatedAt: Timestamp? { get set }
    var userId: String { get set }
}
