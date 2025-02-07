//
//  Firestorable.swift
//  
//
//  Created by Alex Nagy on 07.02.2025.
//

import SwiftUI

public typealias Firestorable = Identifiable & FirestoreModelable & Codable & Equatable
public typealias MappedFirestorable = Codable & Equatable
