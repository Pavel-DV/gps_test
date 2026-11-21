import Foundation

/// Owns the Lockdown session that starts the service until the service is released.
enum LegacyImageMounterSession {
    static func withSession<Mounter, Lockdown, Value>(
        openLockdown: () throws -> Lockdown,
        closeLockdown: (Lockdown) -> Void,
        openMounter: (Lockdown) throws -> Mounter,
        closeMounter: (Mounter) -> Void,
        queryLockdown: (Lockdown) throws -> Void,
        operation: (Mounter) throws -> Value
    ) throws -> Value {
        let lockdown = try openLockdown()
        defer { closeLockdown(lockdown) }
        let mounter = try openMounter(lockdown)
        defer { closeMounter(mounter) }
        // Query the retained control connection after opening the image-mounter service.
        try queryLockdown(lockdown)
        return try operation(mounter)
    }
}

enum LegacyDeveloperImageLookup {
    enum Outcome { case mounted, notMounted, failure }

    static func outcome(signatureLength: Int, errorVariant: String?) -> Outcome {
        if let errorVariant {
            // idevice returns exactly the Debug variant "NotFound" for an absent image.
            // A socket error mentioning that text must not be interpreted as absence.
            return errorVariant == "NotFound" ? .notMounted : .failure
        }
        return signatureLength > 0 ? .mounted : .failure
    }
}
