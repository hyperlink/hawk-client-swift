//
//  File.swift
//  
//
//  Created by Xiaoxin Lu on 1/14/23.
//

import Foundation

// MARK: - SubscriptionlResponse
struct SubscriptionResponse: Codable {
    let entities: [Entity]
}

// MARK: - Entity
struct Entity: Codable {
    let id: String
}
