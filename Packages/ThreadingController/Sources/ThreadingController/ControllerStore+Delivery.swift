import Foundation

extension ControllerStore {
    public func delivery(_ id: DeliveryID) throws -> WorkDelivery { try required("delivery", id.description) }

    /// Persist before making an external call. Send delivery.id as the destination's idempotency
    /// key when supported. A second caller cannot start the same pending delivery.
    public func beginDelivery(_ id: DeliveryID) throws -> WorkDelivery {
        try db.transaction {
            var delivery: WorkDelivery = try required("delivery", id.description)
            guard delivery.state == .pending else { throw ControllerError.conflict }
            delivery.state = .sending
            delivery.attemptID = DeliveryAttemptID()
            try saveDelivery(delivery)
            try event("delivery.started", id.description)
            return delivery
        }
    }
    public func acknowledgeDelivery(_ id: DeliveryID, attemptID: DeliveryAttemptID, receipt: String) throws -> WorkDelivery {
        try Limits.text(receipt, field: "receipt", maximum: 4_096)
        return try db.transaction {
            var delivery: WorkDelivery = try required("delivery", id.description)
            guard delivery.attemptID == attemptID else { throw ControllerError.conflict }
            if delivery.state == .delivered {
                guard delivery.receipt == receipt else { throw ControllerError.conflict }
                return delivery
            }
            guard delivery.state == .sending || delivery.state == .uncertain else { throw ControllerError.conflict }
            delivery.state = .delivered
            delivery.receipt = receipt
            try saveDelivery(delivery)
            try event("delivery.confirmed", id.description)
            return delivery
        }
    }
    public func markDeliveryUncertain(_ id: DeliveryID, attemptID: DeliveryAttemptID) throws -> WorkDelivery {
        try db.transaction {
            var delivery: WorkDelivery = try required("delivery", id.description)
            guard delivery.attemptID == attemptID,
                  delivery.state == .sending || delivery.state == .uncertain else { throw ControllerError.conflict }
            if delivery.state == .uncertain { return delivery }
            delivery.state = .uncertain
            try saveDelivery(delivery)
            try event("delivery.uncertain", id.description)
            return delivery
        }
    }
    /// Only a trusted destination adapter/operator may establish absence. A timeout is NOT proof.
    /// The old attempt is fenced; a late acknowledgement cannot settle a later attempt.
    public func confirmDeliveryAbsent(_ id: DeliveryID, attemptID: DeliveryAttemptID) throws -> WorkDelivery {
        try db.transaction {
            var delivery: WorkDelivery = try required("delivery", id.description)
            guard delivery.attemptID == attemptID, delivery.state == .uncertain else { throw ControllerError.conflict }
            delivery.state = .pending
            delivery.attemptID = nil
            try saveDelivery(delivery)
            try event("delivery.confirmedAbsent", id.description)
            return delivery
        }
    }
    func saveDelivery(_ delivery: WorkDelivery) throws {
        try update("delivery", delivery.id.description, state: delivery.state.rawValue, value: delivery)
    }
}
