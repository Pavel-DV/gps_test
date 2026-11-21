/// Keeps the post-connect Lockdown session alive for the complete image-mounter lifetime.
/// idevice's ImageMounter requires a Lockdown query after its service is opened.
enum LegacyImageMounterSession {
    static func withSession<Mounter, Lockdown, Value>(
        openMounter: () throws -> Mounter,
        closeMounter: (Mounter) -> Void,
        openLockdown: () throws -> Lockdown,
        closeLockdown: (Lockdown) -> Void,
        queryLockdown: (Lockdown) throws -> Void,
        operation: (Mounter) throws -> Value
    ) throws -> Value {
        let mounter = try openMounter()
        var lockdown: Lockdown?
        defer {
            // The service is released first, while its Lockdown session is still alive.
            closeMounter(mounter)
            if let lockdown { closeLockdown(lockdown) }
        }
        let session = try openLockdown()
        lockdown = session
        try queryLockdown(session)
        return try operation(mounter)
    }
}
