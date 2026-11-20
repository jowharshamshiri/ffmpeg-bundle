// The lock that lets one build of ffmpeg run at a time for one identity.
//
// Included by build.rs. It is a file locked through the kernel (`flock` on
// Unix, `LockFileEx` on Windows), not a directory created and removed by
// convention, because the kernel releases a lock the moment nothing holds it
// any more. A build that is killed releases it as it dies, so the next build
// takes it over at once and nothing is left behind to be judged stale. The
// directory this replaced named no owner and outlived a killed holder, and
// every build after one waited its full 30 minutes before taking it over.
//
// Beside the lock is the owner's record: the holder's process id, its host,
// and when it took the lock. It is what a waiting build names, and what tells
// the next holder that the last one ended without finishing.
//
// The recipe the holder runs is part of the hold. Killing the holder alone
// can leave its recipe running, writing into the scratch tree; a second
// recipe started there would build into the same files. On Unix the recipe
// and everything it starts inherit the locked file, so the lock is held until
// the last of them is gone. On Windows the holder puts itself in a job that
// ends every process in it when the holder ends, so the recipe dies with it.

/// Held while this process builds ffmpeg for one identity.
struct BuildLock {
    /// The locked file. Closing it releases the lock.
    file: std::fs::File,
    /// Where the owner's record is.
    owner: PathBuf,
}

impl BuildLock {
    /// Take the lock at `path`, waiting for as long as another build holds it.
    ///
    /// The wait has no deadline: a build that holds it is building, and one
    /// that is gone no longer holds it. Taking it over from a live builder
    /// would run a second recipe beside the first.
    fn acquire(path: &Path) -> BuildLock {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap_or_else(|e| {
                panic!("ffmpeg-bundle: cannot create the build root {parent:?}: {e}")
            });
        }
        let owner = path.with_extension("owner");
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .unwrap_or_else(|e| panic!("ffmpeg-bundle: cannot open the build lock {path:?}: {e}"));
        match file.try_lock() {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => {
                let holder = describe_owner(&owner);
                let began = Instant::now();
                file.lock().unwrap_or_else(|e| {
                    panic!("ffmpeg-bundle: cannot wait for the build lock {path:?}: {e}")
                });
                println!(
                    "cargo:warning=ffmpeg-bundle: waited {}s for the build lock at {path:?}, \
                     held by {holder}",
                    began.elapsed().as_secs()
                );
            }
            Err(std::fs::TryLockError::Error(e)) => {
                panic!("ffmpeg-bundle: cannot take the build lock {path:?}: {e}")
            }
        }

        // A record left behind is a holder that ended without releasing the
        // lock: killed, or its machine stopped. A holder that finishes, or
        // fails, removes its record before it lets go.
        if let Some(left) = read_owner(&owner) {
            println!(
                "cargo:warning=ffmpeg-bundle: the build lock at {path:?} was held by {left}, \
                 which ended without finishing; this build takes it over"
            );
        }
        write_owner(&owner);
        BuildLock { file, owner }
    }

    /// Make the processes this one starts, until the returned hold is
    /// dropped, hold the lock with it: the recipe, and everything the recipe
    /// starts in turn.
    #[cfg(unix)]
    fn extend_to_children(&self) -> ChildHold {
        use std::os::fd::AsRawFd;
        // A second descriptor of the same open file, and so of the same
        // lock: `flock` belongs to the open file, and holds until every
        // descriptor of it is closed. Rust opens every file close-on-exec;
        // this one is made inheritable, and is closed when the hold is
        // dropped, so that nothing started after the recipe inherits it.
        let shared = self
            .file
            .try_clone()
            .unwrap_or_else(|e| panic!("ffmpeg-bundle: cannot share the build lock: {e}"));
        let fd = shared.as_raw_fd();
        // SAFETY: `fd` is a descriptor this process owns for as long as
        // `shared` lives, and F_GETFD/F_SETFD only read and set its flags.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } < 0 {
            panic!(
                "ffmpeg-bundle: cannot let the recipe inherit the build lock: {}",
                std::io::Error::last_os_error()
            );
        }
        ChildHold { _shared: shared }
    }

    /// Make the processes this one starts end when it ends, which is when
    /// the lock is released.
    #[cfg(windows)]
    fn extend_to_children(&self) -> ChildHold {
        end_children_with_this_process();
        ChildHold {}
    }

    /// Let go: the record first, so that nothing reads it as a holder that
    /// died, then the lock itself.
    fn release(self) {
        match std::fs::remove_file(&self.owner) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => panic!(
                "ffmpeg-bundle: cannot remove the build lock's owner record {:?}: {e}",
                self.owner
            ),
        }
        drop(self.file);
    }
}

/// What keeps the processes started under it holding the build lock.
struct ChildHold {
    /// The inheritable descriptor of the locked file.
    #[cfg(unix)]
    _shared: std::fs::File,
}

/// The owner's record: who holds the lock, and since when.
///
/// Written to a temporary name and renamed into place, so a reader never sees
/// half of one.
fn write_owner(owner: &Path) {
    let started = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("the clock is after 1970")
        .as_secs();
    let record = format!(
        "pid={}\nhost={}\nstarted={started}\n",
        std::process::id(),
        host_name()
    );
    let partial = owner.with_extension(format!("owner.{}", std::process::id()));
    std::fs::write(&partial, record).unwrap_or_else(|e| {
        panic!("ffmpeg-bundle: cannot write the build lock's owner record {partial:?}: {e}")
    });
    std::fs::rename(&partial, owner).unwrap_or_else(|e| {
        panic!("ffmpeg-bundle: cannot publish the build lock's owner record at {owner:?}: {e}")
    });
}

/// The record at `owner`, on one line, or `None` when there is none.
fn read_owner(owner: &Path) -> Option<String> {
    match std::fs::read_to_string(owner) {
        Ok(text) => {
            let fields: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
            if fields.is_empty() {
                None
            } else {
                Some(fields.join(" "))
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => panic!("ffmpeg-bundle: cannot read the build lock's owner record {owner:?}: {e}"),
    }
}

/// The holder, as a waiting build names it.
fn describe_owner(owner: &Path) -> String {
    // The holder writes its record just after it takes the lock, so a build
    // that arrives in between finds none yet.
    read_owner(owner).unwrap_or_else(|| "a build that has not yet recorded itself".to_string())
}

/// This machine's name, for the owner's record.
#[cfg(unix)]
fn host_name() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is writable for its whole length, which is what is
    // passed.
    if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } != 0 {
        panic!(
            "ffmpeg-bundle: cannot read this machine's name for the build lock: {}",
            std::io::Error::last_os_error()
        );
    }
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
    String::from_utf8_lossy(&buffer[..end]).into_owned()
}

/// This machine's name, for the owner's record.
#[cfg(windows)]
fn host_name() -> String {
    use windows_sys::Win32::System::SystemInformation::{
        ComputerNameDnsHostname, GetComputerNameExW,
    };
    let mut buffer = [0u16; 256];
    let mut length = buffer.len() as u32;
    // SAFETY: `length` is the buffer's capacity in UTF-16 units, as the call
    // requires; it is set to the length written.
    if unsafe { GetComputerNameExW(ComputerNameDnsHostname, buffer.as_mut_ptr(), &mut length) }
        == 0
    {
        panic!(
            "ffmpeg-bundle: cannot read this machine's name for the build lock: {}",
            std::io::Error::last_os_error()
        );
    }
    String::from_utf16_lossy(&buffer[..length as usize])
}

/// Put this process in a job that ends every process in it when this one
/// ends, so that the recipe it starts cannot outlive it and the lock.
///
/// Windows has no counterpart of a lock that a child inherits: a lock taken
/// with `LockFileEx` belongs to the process that took it, and is released when
/// that process ends, whatever it started. So the recipe is made to end then
/// too. The job's one handle is this process's, and is never closed: the
/// system closes it when the process ends, however it ends, and that is what
/// ends the job. Closing it any earlier would end this process with the rest.
#[cfg(windows)]
fn end_children_with_this_process() {
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    // SAFETY: each call is given a handle it returned or the current
    // process's pseudo-handle, and a structure of the size it is told.
    unsafe {
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if job.is_null() {
            panic!(
                "ffmpeg-bundle: cannot create the job the recipe runs in: {}",
                std::io::Error::last_os_error()
            );
        }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        ) == 0
        {
            panic!(
                "ffmpeg-bundle: cannot make the recipe's job end with this build: {}",
                std::io::Error::last_os_error()
            );
        }
        if AssignProcessToJobObject(job, GetCurrentProcess()) == 0 {
            panic!(
                "ffmpeg-bundle: cannot put this build in the recipe's job: {}",
                std::io::Error::last_os_error()
            );
        }
    }
}
