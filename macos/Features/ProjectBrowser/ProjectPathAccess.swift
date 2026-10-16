import Darwin

/// Opens a path inside a project root without ever leaving it: the path must be relative with
/// no `.` or `..` components and no NUL, and every component is opened with `openat` +
/// `O_NOFOLLOW`, so a symbolic link anywhere on the way fails instead of being followed. The file
/// browser and the Agent's read-only tools share it.
enum ProjectPath {
    enum Failure: Error, Equatable {
        /// Absolute, containing `.` / `..`, or containing a NUL, where the system would stop
        /// reading the path: "..\0" opens "..".
        case outsideProject
        /// `errno` from opening a component (`ELOOP` for a symbolic link).
        case system(Int32)
    }

    /// A descriptor the caller closes. Intermediate components must be directories.
    static func open(root: String, path: String, directory: Bool) throws(Failure) -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !path.utf8.contains(0), !parts.contains(".."), !parts.contains(".") else { throw .outsideProject }
        var fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .system(errno) }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index < parts.count - 1 || directory ? O_DIRECTORY : 0)
            let next = openat(fd, part, flags)
            let code = errno
            close(fd)
            guard next >= 0 else { throw .system(code) }
            fd = next
        }
        return fd
    }

    /// `path` fully resolved, as `realpath` gives it; nil when it does not resolve. URL's own
    /// resolution keeps `/var` for `/private/var`.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
